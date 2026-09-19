import Foundation

/// 앞 단계가 읽은 글을 **기기 모델이 줄인다.**
///
/// 이 툴이 코어에 있는 이유는 비용과 경계다. `"이 페이지 요약해서 보내줘"`는 세
/// 단계다: 읽고, 줄이고, 보낸다. 줄이는 일을 PCC에 맡기면 페이지 전문이 문맥에
/// 실려 올라가고(비용), 그 글이 기기를 떠난다(프라이버시). 기기 모델은 바로 이
/// 일을 잘한다 — 긴 글 하나를 짧은 글 하나로.
///
/// **원문은 인자로 오지 않는다.** PCC는 페이지 내용을 모르고, 알 필요도 없다.
/// `sourceText`는 앞 단계의 수령증에서 런타임이 채우는 자리다
/// (`ResolvableArgument.sourceText`).
///
/// 줄이는 방법은 **JustSend의 정본 파이프라인**이다(`~/justsend/ios-prod`의
/// `JustSendMemoryCore`): `TextChunker`로 조각을 내고, 조각마다 구조화 산출
/// (`{headline, points}`)을 한 번 받고, `SummaryJudgment`로 규격·복사·반복을
/// 판정하고, 어긋나면 `ExtractiveSummary`로 원문에서 뽑아내고, 순서대로 Markdown에
/// 쌓는다(`SummaryEngine`). 예전에는 이 자리가 `String(source.prefix(6_000))`
/// 한 줄이었고, 388,754자 문서의 "요약"이 첫 6,000자의 요약이었다(실기 2026-09-17,
/// iPhone: 사용자 지적 "장문 요약이 제대로 안 된다").
public struct SummarizeTool: CapabilityHandler {
  /// 이 차례에 조각을 모델에 넣을 최대 횟수.
  ///
  /// 정본은 백그라운드 정리기여서 체크포인트로 조각 전부를 돈다. 이 코어의 요약은
  /// **대화 한 차례 안에서** 끝나야 하고 그 차례에는 실행 창이 있다
  /// (`TurnLimits.executionWindow` 180초). 상한을 넘는 문서는 고르게 골라 문서
  /// 전체에 걸치게 하고, 읽은 조각 수와 전체 조각 수를 수령증에 남긴다.
  public static let maximumChunkCalls = 16
  /// 조각을 도는 데 쓸 시간의 상한. 넘으면 거기까지 읽은 것으로 닫는다 — 차례
  /// 전체가 마감에 걸려 아무 답도 못 쓰는 것보다 낫다.
  public static let reductionWindow: Duration = .seconds(60)

  /// 요약이 놓이는 수령증 자리. `ResolvableArgument.body`가 이 값을 읽는다.
  public static let textDetailKey = "text"

  /// 요약을 **읽을 사람의 언어.**
  ///
  /// `Locale.current`다. 이 값은 "기기 설정"이 아니라 **번들이 아는 언어와 기기
  /// 설정이 협상한 결과**이고, 그것이 곧 이 앱이 사람에게 말하는 언어다. 두 번의
  /// 실기가 이 선택을 정했다(2026-09-19, iPhone 15 Pro):
  ///
  /// - 번들에 `ko.lproj`가 없던 동안 `Locale.current`가 `en_US`였고 요약이 영어로
  ///   나왔다. 고칠 자리는 이 함수가 아니라 번들의 선언이었다.
  /// - 그 사이 `Locale.preferredLanguages`로 갈아탔더니 이 기기가 `en-KR`을
  ///   돌려줬다 — 시스템 언어가 영어인 기기였고, 앱 화면은 한국어인데 요약만
  ///   영어로 남았다. 시스템 설정은 이 앱이 말하는 언어가 아니다.
  static var readerLocale: String {
    Locale.current.identifier
  }

  private let model: any SummaryModel
  private let chunkBudget: Int

  public init(model: any SummaryModel, chunkBudget: Int = TextChunker.defaultBudget) {
    self.model = model
    self.chunkBudget = chunkBudget
  }

  public var capabilities: Set<CapabilityID> { [.textSummarize] }

  public var contracts: [CapabilityContract] {
    [
      CapabilityContract(
        .textSummarize,
        required: [CapabilityContract.Argument("sourceText")],
        // 무엇에 초점을 둘지는 사용자 문장에서 온다("가격만 정리해줘").
        optional: [CapabilityContract.Argument("focus")])
      // **이 줄은 `.deviceArtifact`가 아니다.** 실측(2026-09-19, 코어 시험
      // `WebSearchTests.testSearchReadSummarizeChainKeepsRawTextOnDevice`와
      // `GoldenScenarioTests.testG05MemoryVersusWeb`)으로 확인했다 — 기기 요약은
      // 원문을 대신해 **PCC 답의 근거로 올라가는 압축물**이고, 그것을 막으면
      // 최종 답이 근거 없이 선다. 요약이 "이미 답"이 되는 경우는 사용자가 요약
      // 자체를 요청한 차례뿐이고, 그 판정은 능력이 아니라 차례가 한다.
    ]
  }

  public func perform(_ request: ActionRequest) async throws -> ActionReceipt {
    guard let source = request.arguments["sourceText"]?.textValue,
      !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw ActionError.invalidArguments(reason: "sourceText")
    }
    guard model.isAvailable else {
      // 기기 모델이 없으면 **줄이지 않았다고 말한다.** 원문을 그대로 본문에 실어
      // 보내면 사용자가 시킨 일("요약해서")과 다른 일을 한 것이다.
      throw ActionError.unsupported(request.capability)
    }

    let focus = request.arguments["focus"]?.textValue
    let capability = request.capability
    let outcome = try await SummaryEngine.summarize(
      text: source,
      // 사람의 언어는 `readerLocale`이 고른다(그 자리에 근거가 있다).
      locale: Self.readerLocale,
      model: model,
      focus: focus,
      chunkBudget: chunkBudget,
      callLimit: Self.maximumChunkCalls,
      deadline: ContinuousClock.now.advanced(by: Self.reductionWindow),
      onProgress: { progress in
        // 조각 단위 진행을 화면으로 흘린다. 낱말은 호스트가 고른다.
        switch progress {
        case .chunked(let total):
          ToolProgress.report(capability, done: 0, total: total)
        case .mapping(let index, let total):
          ToolProgress.report(capability, done: index, total: total)
        case .finished:
          break
        }
      })

    // 하나도 요약하지 못했다면 이 실행이 한 일은 없다. 빈 요약을 성공으로 돌려주면
    // 다음 단계(메일 본문·메모 저장)가 빈 글을 싣는다.
    guard outcome.hasAnySummary, !outcome.markdown.isEmpty else {
      throw ActionError.failed(reason: "empty")
    }

    let read = outcome.pieces.count
    let covered = outcome.isComplete

    // **무엇이 요약을 막았는지 센다.** 기기 모델의 답이 판정에서 거부되면 화면에
    // 보이는 것은 발췌뿐이고, 그 이유는 어디에도 나타나지 않았다(실기 2026-09-17:
    // 열여섯 조각 전부가 발췌였고 사유를 알 수 없었다).
    let byModel = outcome.pieces.filter { $0.origin == .model }.count
    let byExtraction = outcome.pieces.filter { $0.origin == .extracted }.count
    var reasons: [String: Int] = [:]
    for piece in outcome.pieces {
      for reason in piece.rejections { reasons[reason, default: 0] += 1 }
    }
    let verdict = reasons.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
      .map { "\($0.key)×\($0.value)" }
      .joined(separator: " ")

    // **PCC에는 요약문이 아니라 "무엇을 했는가"가 간다.**
    //
    // 요약문을 재료로 넘기던 동안 답은 앞차례의 답을 베끼거나 원문 발췌를 요약처럼
    // 세웠다(실기 2026-09-17, 세 번 재현). 그리고 그 한 줄을 **우리가 한국어로
    // 쓰지도 않는다** — 코드가 문장을 쓰면 그 문장은 사용자의 말투와 언어를 모른다
    // (사용자 지시 2026-09-17). 우리가 내는 것은 사실이고, 문장은 PCC가 쓴다.
    //
    // 요약 본문은 `text` 자리에 남아 **기기를 떠나지 않는다** — 화면이 그것을
    // 그대로 렌더한다.
    let facts: [String] = [
      "\"document\": \"\(Self.escaped(outcome.title ?? ""))\"",
      "\"chunks\": \(outcome.chunkCount)",
      "\"chunksRead\": \(read)",
      "\"chunksSummarized\": \(outcome.summarizedCount)",
      "\"byModel\": \(byModel)",
      "\"byExtraction\": \(byExtraction)",
      "\"complete\": \(covered)",
      "\"characters\": \(source.count)",
    ]
    let rows = [
      CapabilitySourceRow(
        title: outcome.title ?? "",
        subtitle: "",
        body: "{\(facts.joined(separator: ", "))}",
        identifier: "summary")
    ]

    return ActionReceipt(
      requestID: request.id,
      capability: request.capability,
      // 이 줄은 답이 아니라 **진행 기록**이다(단계 목록·자세히 보기).
      summary: [
        covered ? "요약함" : "\(outcome.chunkCount)조각 중 \(read)조각",
        "모델 \(byModel) 발췌 \(byExtraction)",
        verdict,
      ].filter { !$0.isEmpty }.joined(separator: " · "),
      details: [
        Self.textDetailKey: .text(outcome.markdown),
        // 잘렸다는 사실은 남는다. 이제 그 값은 "앞을 잘랐다"가 아니라 "문서 전체를
        // 다 읽지는 못했다"는 뜻이다.
        "truncated": .flag(!covered),
        "chunks": .number(Double(outcome.chunkCount)),
        "chunksRead": .number(Double(read)),
        "chunksSummarized": .number(Double(outcome.summarizedCount)),
        "chunksByModel": .number(Double(byModel)),
        "chunksByExtraction": .number(Double(byExtraction)),
        "rejections": .text(verdict),
        "title": .text(outcome.title ?? ""),
      ] + CapabilitySourceRow.detail(rows),
      coverage: [
        CoverageRecord(
          binding: .accountLocal(accountID: request.accountID, domain: "text"),
          capability: request.capability,
          queryFingerprint: ActionFingerprint.arguments([
            "focus": .text(focus ?? ""), "length": .number(Double(source.count)),
          ]),
          state: covered ? .complete : .partial,
          discoveredCount: outcome.chunkCount, readCount: outcome.summarizedCount,
          paginationExhausted: covered, truncated: !covered)
      ])
  }

  /// 사실 한 칸의 값. 제목은 사용자가 붙인 이름이므로 따옴표와 역슬래시를 막는다.
  private static func escaped(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: " ")
  }
}

extension AdmissionJob {
  /// 툴이 기기 모델을 쥔 시간. 계획·답과 **이름을 나눈다** — 지표에서 갈라져야
  /// "툴이 줄을 오래 쥐었다"와 "모델이 느렸다"를 구별한다.
  public static let toolSummarize = AdmissionJob("toolSummarize")
}

private func + (
  lhs: [String: ActionValue], rhs: [String: ActionValue]
) -> [String: ActionValue] {
  lhs.merging(rhs) { current, _ in current }
}
