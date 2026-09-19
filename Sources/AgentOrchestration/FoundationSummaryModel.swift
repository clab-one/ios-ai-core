import AgentKernel
import Foundation
import FoundationModels

/// 요약 파이프라인이 쓰는 **기기 모델의 구조화 산출**.
///
/// 정본(`~/justsend/ios-prod`의 `FoundationProfileModelExecutor`)과 같은 선택을
/// 그대로 옮긴다: guided generation을 쓴다. 스키마가 형식을 강제하니 모델이
/// 절제한다 — 정본 실측(M4 Max, 8K 창, 각 5회 중앙값): 구조화 1.89초·115 scalar,
/// Markdown 평문 2.16~2.36초·173~202 scalar. 생성 토큰이 곧 연산이고 발열이므로
/// 산출 억제가 그대로 이득이다. `includeSchemaInPrompt`는 기본값(true)을 쓴다 —
/// 끄면 모델이 형식을 몰라 더 길게 쓰고 오히려 느려졌다(2.48초·166 scalar).
///
/// Markdown 조립은 코어가 한다(`SummaryEngine.markdown`). 여기서 만드는 것은
/// 계약이 요구하는 JSON뿐이다.
@available(iOS 26.0, *)
public struct FoundationSummaryModel: SummaryModel {
  private let model: SystemLanguageModel

  public init(model: SystemLanguageModel = .default) {
    self.model = model
  }

  public var contextWindowTokens: Int { model.contextSize }

  public var isAvailable: Bool {
    if case .available = model.availability { return true }
    return false
  }

  public func answer(
    schema: SummarySchema, instructions: String, prompt: String, maximumResponseTokens: Int
  ) async throws -> Data {
    guard case .available = model.availability else {
      throw ActionError.unsupported(.textSummarize)
    }
    // 호출마다 새 세션이다 — 앞 조각의 산출이 다음 조각에 섞이지 않게 한다.
    let session = LanguageModelSession(model: model, instructions: instructions)
    let options = GenerationOptions(
      sampling: .greedy, maximumResponseTokens: maximumResponseTokens)

    switch schema {
    case .summaryChunk:
      let response = try await ModelAdmission.withAdmission(for: .toolSummarize) {
        try await session.respond(
          to: prompt, generating: GeneratedSummaryChunk.self, options: options)
      }
      return try JSONEncoder().encode(
        SummaryChunkPayload(
          headline: response.content.headline, points: response.content.points))
    case .summaryTitle:
      let response = try await ModelAdmission.withAdmission(for: .toolSummarize) {
        try await session.respond(
          to: prompt, generating: GeneratedSummaryTitle.self, options: options)
      }
      return try JSONEncoder().encode(SummaryTitlePayload(title: response.content.title))
    }
  }
}

/// 조각 하나의 산출. **요약문 한 덩이를 받지 않는다** — 헤드라인과 요점으로 나눠
/// 받아야 그 뒤의 단계가 사실을 세고 자를 수 있다(덩이는 자르면 뜻이 깨진다).
@available(iOS 26.0, *)
@Generable
struct GeneratedSummaryChunk {
  @Guide(description: "one short headline for this section, no trailing punctuation")
  let headline: String
  /// 정본과 같이 **셋**이다. 다섯으로 두었더니 산출이 토큰 상한(조각 크기의 26%)에
  /// 닿아 마지막 요점이 중간에서 끊겼고, 판정이 그것을 `incomplete`로 거부해 조각이
  /// 발췌로 내려섰다(실기 2026-09-17, iPhone: 열여섯 조각 전부).
  @Guide(description: "the facts of this section, one sentence each", .maximumCount(3))
  let points: [String]
}

@available(iOS 26.0, *)
@Generable
struct GeneratedSummaryTitle {
  @Guide(description: "a short noun-phrase title for the whole document")
  let title: String
}

/// 코어의 판정기가 읽는 모양(`SummaryJudgment.judge`): 키는 둘, 그 외에는 없다.
private struct SummaryChunkPayload: Encodable {
  let headline: String
  let points: [String]
}

private struct SummaryTitlePayload: Encodable {
  let title: String
}
