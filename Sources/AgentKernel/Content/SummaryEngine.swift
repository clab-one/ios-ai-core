import Foundation

// MARK: - 결과

/// 한 조각이 어떻게 만들어졌는가.
///
/// **정본은 JustSend의 `JustSendMemoryCore/SummaryEngine`이다**(`~/justsend/ios-prod`).
/// 이 값이 없던 동안, 요약에 실패한 조각은 결과에서 조용히 빠졌고 남은 하나로
/// "요약 완료"가 됐다 — 일곱 장 문서가 한 조각으로 보이고도 성공이라 보고했다.
public enum SummaryOrigin: String, Codable, Hashable, Sendable {
  /// 모델이 답했다.
  case model
  /// 모델이 쓸 만한 답을 내지 못해, 원문에서 문장을 골라 세웠다.
  case extracted
  /// 어느 방법으로도 요약하지 못했다. `points`는 비어 있다.
  case none
}

/// 요약 한 조각. 조각 = 글자 수로 끊은 텍스트 한 덩어리.
public struct SummaryPiece: Codable, Hashable, Sendable {
  public let index: Int
  public let headline: String
  public let points: [String]
  public let origin: SummaryOrigin
  /// 이 조각을 만들며 되돌려보낸 답들의 이유. 순서는 시도 순서다. 진단을 위해
  /// 남긴다 — 어느 결함이 실기에서 실제로 나는지 아는 유일한 방법이다.
  public let rejections: [String]

  public init(
    index: Int, headline: String, points: [String], origin: SummaryOrigin,
    rejections: [String] = []
  ) {
    self.index = index
    self.headline = headline
    self.points = points
    self.origin = origin
    self.rejections = rejections
  }

  /// 이 조각이 요약을 담고 있는가.
  public var hasSummary: Bool { origin != .none }
}

/// 요약 결과 전체.
public struct SummaryOutcome: Codable, Hashable, Sendable {
  /// 읽은 조각들. **모든 조각이 여기 있다** — 실패한 조각도 자리를 지킨다.
  public let pieces: [SummaryPiece]
  /// 조각들을 순서대로 쌓은 Markdown. **이 글이 곧 요약이다** — 답을 쓰는 단계가
  /// 이것을 다시 줄이지 않는다(사용자 지시 2026-09-17: "요약한 내용은 그대로 한
  /// 번 더 요약 없이 보여주면 좋겠다").
  public let markdown: String
  /// 이 글 전체를 말하는 한 줄. 조각이 하나면 그 헤드라인이 곧 제목이다.
  /// 만들지 못하면 nil — 소비자는 그때 자기가 아는 제목(파일명·첫 줄)을 지킨다.
  public let title: String?
  /// 원문이 나뉜 조각의 **총수**. 읽은 조각 수와 다르면 그 차례는 문서의 일부만
  /// 읽었다는 뜻이고, 그 사실은 수령증과 coverage에 남는다.
  public let chunkCount: Int

  public init(
    pieces: [SummaryPiece], markdown: String, title: String? = nil, chunkCount: Int
  ) {
    self.pieces = pieces
    self.markdown = markdown
    self.title = title
    self.chunkCount = chunkCount
  }

  /// 실제로 요약된 조각 수. 거짓 보고를 막는 숫자다.
  public var summarizedCount: Int { pieces.filter(\.hasSummary).count }
  /// 하나라도 요약했는가. 전부 실패했다면 이 실행이 한 일은 없다.
  public var hasAnySummary: Bool { summarizedCount > 0 }
  /// 문서 전체를 읽었는가.
  public var isComplete: Bool { pieces.count >= chunkCount && summarizedCount == pieces.count }
}

// MARK: - 모델 경계

/// 기기 모델이 채우는 구조화 산출의 종류. 정본과 같이 **둘뿐이다.**
public enum SummarySchema: String, Sendable, Codable {
  /// 조각 하나 → `{headline, points}`.
  case summaryChunk
  /// 헤드라인들 → `{title}`.
  case summaryTitle
}

/// 모델 한 번 호출. 구현은 호출마다 새 세션을 만들어 이전 출력이 다음 조각에 섞이지
/// 않게 한다.
///
/// **평문이 아니라 구조화 산출이다.** 정본의 실측: 평문 경로는 모델이 `{headline,
/// points}` 모양을 맞춰 주기를 바라는 것이 전부였고 "JSON 규격으로 잘 뱉지 않는다"가
/// 그 결과였다. 지금은 모든 요약이 guided generation 하나를 지난다.
public protocol SummaryModel: ModelContextWindow {
  func answer(
    schema: SummarySchema, instructions: String, prompt: String, maximumResponseTokens: Int
  ) async throws -> Data

  /// 이 기기에서 기기 모델을 쓸 수 있는가. 쓸 수 없으면 요약 툴은 **줄이지 않았다고
  /// 말한다** — 원문을 그대로 실어 보내지 않는다.
  var isAvailable: Bool { get }
}

/// 진행 알림. 스피너는 "돌고 있다"만 말하고 무엇이 끝났는지는 말하지 못한다.
public enum SummaryProgress: Sendable, Equatable {
  case chunked(total: Int)
  /// 조각 하나를 모델에 넣고 있다. `index`는 1부터 센다.
  case mapping(index: Int, total: Int)
  case finished
}

// MARK: - 엔진

/// 텍스트 하나를 요약한다. 흐름은 다섯 걸음이고 그 이상은 없다:
///
/// 1. **글자 수로 끊는다**(`TextChunker` — 문단 > 줄바꿈 > 문장 > 낱말 순).
/// 2. 조각마다 **독립 호출 한 번**. 프롬프트는 규칙 몇 줄과 원문뿐이다.
/// 3. **세 가지만 본다**: 규격인가, 원문 복사인가, 반복인가(`SummaryJudgment`).
/// 4. 어긋나면 원문에서 뽑아낸다(`ExtractiveSummary`).
/// 5. 순서대로 **Markdown에 쌓는다.**
///
/// 정본과 다른 자리는 하나다: 정본은 백그라운드 정리기이므로 체크포인트로 조각
/// **전부**를 돈다. 이 코어의 요약은 **대화 한 차례 안에서** 끝나야 하고 그 차례에는
/// 실행 창이 있다(`TurnLimits.executionWindow` 180초). 그래서 호출 수와 시간에
/// 상한을 두고, 상한을 넘는 문서는 **고르게 골라** 문서 전체에 걸치게 한다. 읽은
/// 조각 수와 전체 조각 수는 결과에 그대로 남는다 — 덜 읽은 것을 다 읽었다고 말하지
/// 않는다.
public enum SummaryEngine {

  /// - Parameters:
  ///   - focus: 무엇에 초점을 둘지. 사용자 문장에서 온다("가격만 정리해줘").
  ///   - chunkBudget: 조각 하나의 스칼라 예산. 창을 아는 호출자는
  ///     `TextChunker.budget(forContextTokens:)`로 계산해 넘긴다.
  ///   - callLimit: 이 차례에 조각을 모델에 넣을 최대 횟수.
  ///   - deadline: 조각을 도는 데 쓸 시간의 끝. 넘으면 거기까지 읽은 것으로 닫는다.
  public static func summarize(
    text: String,
    locale: String,
    model: SummaryModel,
    focus: String? = nil,
    chunkBudget: Int = TextChunker.defaultBudget,
    callLimit: Int = Int.max,
    deadline: ContinuousClock.Instant? = nil,
    onProgress: (@Sendable (SummaryProgress) -> Void)? = nil
  ) async throws -> SummaryOutcome {
    let chunks = mergingTail(
      TextChunker.chunk(text, budget: chunkBudget), budget: chunkBudget)
    guard !chunks.isEmpty else {
      return SummaryOutcome(pieces: [], markdown: "", chunkCount: 0)
    }
    onProgress?(.chunked(total: chunks.count))

    // 상한을 넘는 문서는 **앞에서부터 상한만큼** 읽지 않는다 — 그것은 곧 앞부분만
    // 읽는 것이고, 문서 요약이라는 이름의 첫 페이지 요약이 그 실패였다(실기
    // 2026-09-17, iPhone: 388,754자 문서).
    let selected = spread(chunks, limit: callLimit)
    var pieces: [SummaryPiece] = []
    pieces.reserveCapacity(selected.count)

    for (offset, chunk) in selected.enumerated() {
      try Task.checkCancellation()
      // 시간이 다 되면 거기까지 읽은 것으로 닫는다. 마감을 넘기면 차례 전체가 답
      // 없이 끝나고, 그때 사용자는 아무것도 받지 못한다.
      if offset > 0, let deadline, ContinuousClock.now >= deadline { break }
      onProgress?(.mapping(index: offset + 1, total: selected.count))
      pieces.append(
        await summarizeChunk(
          chunk.text, index: chunk.index, locale: locale, focus: focus, model: model))
    }
    pieces.sort { $0.index < $1.index }

    let title = await makeTitle(for: pieces, locale: locale, model: model)
    onProgress?(.finished)
    return SummaryOutcome(
      pieces: pieces,
      markdown: markdown(for: pieces, hidingHeadline: pieces.count == 1),
      title: title,
      chunkCount: chunks.count)
  }

  /// 이 글 전체를 말하는 한 줄.
  ///
  /// 조각이 하나면 **그 헤드라인이 곧 제목이다** — 모델을 또 부르지 않는다. 조각이
  /// 여럿이면 헤드라인들을 모아 한 줄을 새로 받고, 그 줄이 어느 섹션 헤드라인과
  /// 같으면 버린다 — 제목은 전체를, 섹션은 조각을 말해야 한다.
  static func makeTitle(
    for pieces: [SummaryPiece], locale: String, model: SummaryModel
  ) async -> String? {
    let headlines = pieces.filter(\.hasSummary).map(\.headline).filter { !$0.isEmpty }
    guard !headlines.isEmpty else { return nil }
    guard headlines.count > 1 else { return headlines[0] }

    let fallback = headlines[0]
    let prompt = SummaryPrompt.makeTitlePrompt(headlines: headlines, locale: locale)
    let existing = Set(headlines.map(SummaryJudgment.compact))
    let data: Data
    do {
      data = try await model.answer(
        schema: .summaryTitle,
        instructions: SummaryPrompt.titleInstructions(locale: locale),
        prompt: prompt,
        maximumResponseTokens: titleResponseTokens)
    } catch {
      return fallback
    }
    guard case .accept(let rawTitle) = SummaryJudgment.judgeTitle(data, source: prompt),
      let rawTitle,
      titleScalarRange.contains(rawTitle.unicodeScalars.count),
      !existing.contains(SummaryJudgment.compact(rawTitle))
    else { return fallback }
    return rawTitle
  }

  /// 제목 길이 범위. 아래는 표의 셀 조각, 위는 목록에서 접히는 문단이다.
  static let titleScalarRange = 6...60
  /// 전용 title schema에는 한 필드만 있으므로 짧은 상한이면 충분하다.
  static let titleResponseTokens = 64

  /// 예산에 한참 못 미치는 **마지막 조각을 앞 조각에 붙인다.**
  ///
  /// 청커는 남은 텍스트를 그대로 마지막 조각으로 내놓는다. 그래서 31자짜리 꼬리가
  /// 독립 조각이 되어 모델 호출 하나를 통째로 먹고, 문장이 하나뿐이라 발췌도 거부되어
  /// 문서에 빈 섹션을 남겼다. 요약의 관점에서 그 꼬리는 앞 문단의 끝이다.
  static func mergingTail(_ chunks: [String], budget: Int) -> [String] {
    guard chunks.count >= 2, let last = chunks.last else { return chunks }
    let floor = budget * 2 / 5
    guard last.unicodeScalars.count < floor else { return chunks }
    var merged = Array(chunks.dropLast())
    let joined = merged[merged.count - 1] + " " + last
    // 붙여서 예산을 크게 넘기면 그대로 둔다 — 컨텍스트를 넘기는 것이 더 나쁘다.
    guard joined.unicodeScalars.count <= budget * 13 / 10 else { return chunks }
    merged[merged.count - 1] = joined
    return merged
  }

  /// 조각이 상한보다 많으면 **문서 전체에 걸치도록 고른다.** 처음과 마지막을 반드시
  /// 들고 사이를 고르게 뽑는다. 원문의 자리(`index`)는 따라간다 — Markdown의 섹션
  /// 번호가 문서의 어디였는지를 말한다.
  static func spread(
    _ chunks: [String], limit: Int
  ) -> [(index: Int, text: String)] {
    let all = chunks.enumerated().map { (index: $0.offset, text: $0.element) }
    guard limit > 0 else { return [] }
    guard all.count > limit else { return all }
    guard limit > 1 else { return [all[0]] }
    let last = all.count - 1
    var picked: [(index: Int, text: String)] = []
    picked.reserveCapacity(limit)
    var previous = -1
    for step in 0..<limit {
      let index = (step * last) / (limit - 1)
      guard index != previous else { continue }
      previous = index
      picked.append(all[index])
    }
    return picked
  }

  /// 조각 하나. **항상 무언가를 돌려준다** — 취소만 예외다.
  ///
  /// 거부당하면 **무엇이 틀렸는지 실어 한 번 더 묻는다.** 실기 2026-09-17(iPhone):
  /// 86조각 논문의 열여섯 조각이 **전부** 거부되어 답이 발췌(저자 목록·러닝 헤더)로
  /// 내려섰다. 한 번의 호출로 판정을 통과하지 못하면 발췌뿐이라는 구조에서는 그
  /// 실패가 곧 사용자가 보는 글이 된다 — 계단을 하나 둔다(정본의 교정 재요청).
  static func summarizeChunk(
    _ chunk: String, index: Int, locale: String, focus: String?, model: SummaryModel
  ) async -> SummaryPiece {
    let prompt = SummaryPrompt.make(chunk: chunk, locale: locale, focus: focus)
    let responseTokens = SummaryPrompt.responseTokens(
      forChunkScalarCount: chunk.unicodeScalars.count)
    var rejections: [String] = []

    var modelDraft: (headline: String, points: [String])?
    for attempt in 0..<2 {
      // 두 번째 호출은 **첫 답이 왜 거부됐는지**를 들고 간다.
      let instructions = SummaryPrompt.instructions(
        locale: locale,
        correcting: attempt == 0 ? nil : rejections.last)
      do {
        let data = try await model.answer(
          schema: .summaryChunk,
          instructions: instructions,
          prompt: prompt,
          maximumResponseTokens: responseTokens)
        switch SummaryJudgment.judge(data, source: chunk) {
        case .accept(let headline, let points):
          modelDraft = (headline, points)
        case .reject(let reason):
          rejections.append(reason.rawValue)
        }
      } catch {
        rejections.append(SummaryJudgment.Reason.modelFailed.rawValue)
      }
      if modelDraft != nil { break }
    }

    if let modelDraft {
      return SummaryPiece(
        index: index, headline: modelDraft.headline, points: modelDraft.points,
        origin: .model, rejections: rejections)
    }

    // 모델이 쓸 만한 답을 내지 못했다. **원문에서 뽑아낸다** — 그 페이지를 결과에서
    // 지우지 않는다. 뽑아낸 것은 요약이 아니므로 화면이 그 사실을 말한다
    // (`SummaryPiece.origin`).
    if let extracted = ExtractiveSummary.summarize(text: chunk) {
      return SummaryPiece(
        index: index, headline: extracted.headline, points: extracted.points,
        origin: .extracted, rejections: rejections)
    }

    return SummaryPiece(
      index: index, headline: "", points: [], origin: .none, rejections: rejections)
  }

  // MARK: - 쌓기

  /// 조각을 순서대로 쌓는다.
  ///
  /// **번호는 1부터 빈틈없이 간다.** 조각 번호를 그대로 쓰던 동안 화면에는
  /// `1. … 3. … 5. …`가 섰다 — 읽는 사람에게 2와 4는 "무엇이 빠졌지?"라는 질문만
  /// 남긴다(사용자 지시 2026-09-19: "1,2,3 순차로, 조각 이야기는 숨기는 게 좋다").
  /// 조각은 우리 구현의 단위이지 사람이 알 일이 아니다.
  ///
  /// **요약하지 못한 조각은 본문에서 뺀다.** 예전에는 `"No summary…"` 섹션을
  /// 그대로 세웠다. 그 정직함은 사라지지 않는다 — 몇 조각 중 몇 조각을 읽었는지는
  /// 수령증의 범위(`CoverageRecord`)와 계측에 그대로 남고, 화면의 본문만 읽을 수
  /// 있는 것으로 채운다.
  ///
  /// **발췌는 인용으로 쌓는다**(`> `). 발췌는 원문에서 고른 문장이므로 요약처럼
  /// 읽히면 안 된다 — 실기 2026-09-17(iPhone)에서 저자 목록과 러닝 헤더가 요약으로
  /// 섰다. 낱말로 적지 않고 Markdown의 인용으로 두는 이유는 낱말이 호스트의 것이기
  /// 때문이다: 렌더러가 그 구조를 인용으로 세운다.
  static func markdown(for pieces: [SummaryPiece], hidingHeadline: Bool = false) -> String {
    pieces
      .filter(\.hasSummary)
      .enumerated()
      .map { ordinal, piece in
        let marker = piece.origin == .extracted ? "> " : "- "
        let points = piece.points.map { "\(marker)\($0)" }.joined(separator: "\n")
        // 조각 하나짜리 글은 요점만 세운다 — 번호도 헤딩도 셀 것이 없다.
        guard !hidingHeadline else { return points }
        return "## \(ordinal + 1). \(piece.headline)\n\n\(points)"
      }
      .joined(separator: "\n\n")
  }

  /// 요약하지 못한 자리에 남기는 한 줄. 소비자가 자기 화면 언어로 바꿔 보여 줄
  /// 근거는 `SummaryPiece.origin`이 이미 준다.
  public static let unsummarizedNotice = "No summary was produced for this part."
}
