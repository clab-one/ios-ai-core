import Foundation

/// 앞 단계가 읽은 글을 **기기 모델이 옮긴다.**
///
/// 이 툴이 코어에 있는 이유는 경계다. 번역 본문은 화면이 그대로 그리는 산출물이고
/// (`ResultEnvelope.deviceArtifact`), PCC에 원문을 올리면 대화 스크린샷·메일
/// 본문이 기기를 떠난다. 기기 모델은 바로 이 일을 한다 — 글 하나를 다른 말로.
///
/// **원문은 인자로 오지 않는다.** PCC는 페이지·대화 내용을 모르고, 알 필요도 없다.
/// `sourceText`는 앞 단계의 수령증에서 런타임이 채우는 자리다
/// (`ResolvableArgument.sourceText`).
///
/// 긴 원문은 `TextChunker`로 조각을 내고 순서대로 옮긴다. 조각 일부가 실패하면
/// **성공한 앞부분만** 돌려주고 범위를 `CoverageRecord`에 적는다 — 조용히 자르면
/// 화면은 전체가 옮겨진 것처럼 선다.
public struct TranslateTool: CapabilityHandler {
  /// 이 차례에 조각을 모델에 넣을 최대 횟수. 요약과 같은 실행 창을 나눈다.
  public static let maximumChunkCalls = 16
  /// 조각을 도는 데 쓸 시간의 상한. 넘으면 거기까지 옮긴 것으로 닫는다.
  public static let translationWindow: Duration = .seconds(60)
  /// 조각 하나 산출 상한. 원문보다 길어질 여지를 조금 둔다.
  public static let maximumTokensPerChunk = 1_024

  private let model: any OnDeviceTextModel
  private let chunkBudget: Int

  public init(model: any OnDeviceTextModel, chunkBudget: Int = TextChunker.defaultBudget) {
    self.model = model
    self.chunkBudget = chunkBudget
  }

  public var capabilities: Set<CapabilityID> { [.textTranslate] }

  public var contracts: [CapabilityContract] {
    [
      CapabilityContract(
        .textTranslate,
        required: [CapabilityContract.Argument("sourceText")],
        // 도착 언어. 비우면 기기 설정 언어를 쓰고, 그 사실을 수령증에 남긴다.
        optional: [CapabilityContract.Argument("targetLanguage")],
        result: .deviceArtifact)
    ]
  }

  public func perform(_ request: ActionRequest) async throws -> ActionReceipt {
    guard let source = request.arguments["sourceText"]?.textValue,
      !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw ActionError.invalidArguments(reason: "sourceText")
    }
    guard model.isAvailable else {
      // 기기 모델이 없으면 **옮기지 않았다고 말한다.** 원문을 번역인 척 실으면
      // 사용자가 시킨 일과 다른 일을 한 것이다.
      throw ActionError.unsupported(request.capability)
    }

    let requested = request.arguments["targetLanguage"]?.textValue?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let usedDeviceLocale: Bool
    let target: String
    if requested.isEmpty {
      // 도착 언어를 지어내지 않는다. 말하지 않았으면 **이 앱이 사람에게 말하는
      // 언어**로 옮긴다 — `Locale.current`는 번들이 아는 언어와 기기 설정이
      // 협상한 값이다. `Locale.preferredLanguages`는 아니다: 시스템 언어가
      // 영어인 한국어 사용자 기기에서 그 값이 `en-KR`이었다(실기 2026-09-19).
      target = Locale.current.identifier
      usedDeviceLocale = true
    } else {
      target = requested
      usedDeviceLocale = false
    }

    let slices = TextChunker.slices(source, budget: chunkBudget)
    guard !slices.isEmpty else {
      throw ActionError.invalidArguments(reason: "sourceText")
    }
    ToolProgress.report(request.capability, done: 0, total: slices.count)

    let deadline = ContinuousClock.now.advanced(by: Self.translationWindow)
    var translated: [String] = []
    var failed = false
    for slice in slices.prefix(Self.maximumChunkCalls) {
      if ContinuousClock.now >= deadline {
        failed = true
        break
      }
      ToolProgress.report(
        request.capability, done: translated.count, total: slices.count)
      do {
        let piece = try await model.respond(
          instructions: Self.instructions(targetLanguage: target),
          prompt: slice.body,
          purpose: .toolTranslate,
          maximumTokens: Self.maximumTokensPerChunk)
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          failed = true
          break
        }
        // 원문의 줄 구조를 조각 안에서 유지한다. 앞뒤만 다듬고 내부 줄바꿈은 둔다.
        translated.append(Self.preservingInternalNewlines(piece))
      } catch {
        failed = true
        break
      }
    }
    if slices.count > Self.maximumChunkCalls { failed = true }

    guard !translated.isEmpty else {
      throw ActionError.failed(reason: "empty")
    }

    let body = translated.joined()
    let covered = !failed && translated.count == slices.count
    let read = translated.count

    return ActionReceipt(
      requestID: request.id,
      capability: request.capability,
      summary: covered ? "번역 · \(read)조각" : "번역 · \(slices.count)조각 중 \(read)조각",
      details: [
        SummarizeTool.textDetailKey: .text(body),
        "targetLanguage": .text(target),
        "usedDeviceLocale": .flag(usedDeviceLocale),
        "truncated": .flag(!covered),
        "chunks": .number(Double(slices.count)),
        "chunksRead": .number(Double(read)),
      ],
      coverage: [
        CoverageRecord(
          binding: .accountLocal(accountID: request.accountID, domain: "text"),
          capability: request.capability,
          queryFingerprint: ActionFingerprint.arguments([
            "targetLanguage": .text(target), "length": .number(Double(source.count)),
          ]),
          state: covered ? .complete : .partial,
          discoveredCount: slices.count, readCount: read,
          paginationExhausted: covered, truncated: !covered,
          reason: covered ? nil : .truncation)
      ])
  }

  /// 도착 언어만 지시한다. 줄바꿈을 없애면 대화 스크린샷에서 누가 말했는지 사라진다.
  private static func instructions(targetLanguage: String) -> String {
    """
    Translate the user's text into \(targetLanguage). \
    Keep every line break and speaker turn exactly as given. \
    Do not add titles, notes, or quotation marks. Output only the translation.
    """
  }

  /// 모델이 붙인 앞뒤 공백만 걷고, 본문 안의 줄바꿈은 그대로 둔다.
  private static func preservingInternalNewlines(_ value: String) -> String {
    var text = value
    while text.hasPrefix("\n") { text.removeFirst() }
    while text.hasSuffix("\n") { text.removeLast() }
    return text
  }
}

extension AdmissionJob {
  /// 번역 툴이 기기 모델을 쥔 시간. 요약과 이름을 나눈다 — 지표에서 갈라져야
  /// 어느 능력이 줄을 오래 쥐었는지 말할 수 있다.
  public static let toolTranslate = AdmissionJob("toolTranslate")
}
