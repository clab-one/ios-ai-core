import AgentKernel
import Foundation
import FoundationModels
import OSLog

/// 모델이 채우는 **답 한 벌**.
///
/// 문장을 자유롭게 쓰게 하지 않는다. 결론 한 줄과 항목 세 줄까지다 — 기존
/// 결론 렌더러(`ConclusionPresentation`)가 그 모양을 이미 가지고 있고, 모양을
/// 맞추면 답이 화면의 다른 모든 결과와 같은 자리에 선다.
@available(iOS 26.0, *)
@Generable
public struct GeneratedFinalAnswer {
  @Guide(
    description: """
      the direct conversational answer, with paragraphs when useful, written \
      from the permitted context. Address the request itself, not the title \
      or description of a source
      """)
  public let headline: String
  @Guide(
    description: """
      supporting facts, one sentence each, or the lines of one Markdown table \
      when the request asks for a table; omitted when nothing to add
      """,
    .maximumCount(9))
  public let points: [Point]
  @Guide(
    description: """
      numbers of the evidence entries that actually match what the user asked \
      for, empty when none of them do
      """,
    .maximumCount(12))
  public let relevant: [Int]

  /// 답의 한 줄과 **그 줄이 온 자리.**
  ///
  /// 번호를 줄마다 받는 이유는 `relevant` 하나로는 어느 줄이 어느 근거에서
  /// 왔는지 말할 수 없기 때문이다. 화면에 출처 칩이 서 있어도 사용자는 여섯 개
  /// 중 어느 것이 이 문장의 근거인지 알 수 없었다(비교 기준: ChatGPT 웹의 문장별
  /// 각주).
  @Generable
  public struct Point {
    @Guide(
      description:
        "one supporting sentence, or one line of the Markdown table")
    public let text: String
    @Guide(
      description:
        "number of the evidence entry this line came from; 0 when it came from "
        + "the conversation instead of an evidence entry")
    public let evidence: Int
  }
}

/// 답의 한 줄. `evidence`는 **그 줄이 온 근거의 번호**(1부터)이고, 대화에서 온
/// 줄은 `nil`이다.
///
/// 값을 코드가 채우지 않는다. 호스트가 하는 일은 **버리는 일**이다: 문맥에 실린
/// 근거의 수를 넘는 번호와, 모델 자신이 "맞다"고 고르지 않은 근거를 가리키는
/// 번호는 아무것도 가리키지 않는다(`TurnFinalizer.cited`).
public struct AnswerPoint: Sendable, Equatable, Codable {
  public let text: String
  public let evidence: Int?

  public init(text: String, evidence: Int? = nil) {
    self.text = text
    self.evidence = evidence
  }
}

/// 답을 쓴 결과. 모델이 답하지 못한 것을 코드가 지어내지 않는다.
public enum FinalAnswer: Sendable, Equatable {
  /// `relevant`는 **모델이 의도와 맞다고 판정한 근거의 번호**다(1부터).
  ///
  /// 이 값이 없던 동안 회수한 것은 전부 화면에 섰다. 색인이 고른 후보는 추측이고
  /// (임베딩·FTS 점수), 추측을 답의 자리에 세우면 `"신의존재 연락처 알려줘"`가
  /// 무관한 기록의 연락처를 답으로 내놓는다(사용자 지적 2026-09-15). 무엇이
  /// 의도에 맞는지는 모델이 정하고, 화면은 그 판정을 통과한 것만 그린다.
  case written(
    headline: String, points: [AnswerPoint], relevant: [Int], backend: ModelTarget)
  /// 모델을 쓸 수 없었다. 화면은 지역 판정으로 내려선다.
  case unavailable(reason: String)
}

/// 차례를 **닫는 자리**.
///
/// PCC가 참여한 차례는 가능한 한 답도 PCC가 쓴다(§19) — 감독한 모델이 답까지
/// 쓰면 근거와 답 사이에 옮겨 쓰는 손이 하나 줄고, 사용자 요청 전체를 닫는
/// 문장이 나온다(§43).
///
/// **이 단계는 부작용을 만들 수 없다.** 도구가 닫혀 있고(`toolCalling
/// == .disallowed`), 범위가 비어 있고(`CapabilityScope.empty`), 그래서 문맥에
/// `<<<tools>>>` 구획이 아예 서지 않는다. 세 겹 모두 값이다 — 주석이 아니다.
@available(iOS 26.0, *)
public struct TurnFinalizer: Sendable {
  private static let log = AgentHost.logger("orchestrator")

  private let source: InferenceSessionSource

  public init(source: InferenceSessionSource = .privateCloud) {
    self.source = source
  }

  public struct Outcome: Sendable {
    public let answer: FinalAnswer
    public let trail: ModelInvocationTrail
  }

  /// 답 한 벌. 주입된 source가 쓰며 부작용은 만들지 않는다.
  ///
  /// 일시적 실패는 한 번 더 낸다. 그래도 못 쓰면 답이 아니라 `unavailable`을
  /// 돌려주고, 화면은 그 사유로 상태 한 줄을 세운다 — 회수한 것의 제목을 답으로
  /// 올리지 않는다. 기기 모델이 대신 쓰지도 않는다: 근거를 PCC 문맥으로 세운
  /// 차례를 다른 모델이 닫으면 답과 근거가 어긋난다(§19).
  public func finalize(
    _ context: CompiledConversationContext, profile: DynamicTurnProfile
  ) async -> Outcome {
    let started = Date()
    guard #available(iOS 27.0, *) else {
      return self.notAttempted(
        profile: profile, context: context, started: started,
        reason: ModelFailureClassifier.unsupportedReason)
    }
    // **물리 호출마다 영수증 한 장.** 다시 낸 호출도 같은 문맥을 태운다.
    var discarded: [ModelInvocationReceipt] = []
    while true {
      // **세션을 세우는 일과 요청을 내는 일을 나눈다.** PCC 가용성은 계획과 답
      // 사이에 바뀔 수 있고, 그때 답 자리에서 막힌 것은 **부른 적이 없는 것**이다
      // (§36). 이 경계가 없던 동안 나가지 않은 요청이 `pccCalls`에 섞였다.
      let session: LanguageModelSession
      do {
        session = try await source.session(
          instructions: context.instructions)
      } catch {
        return self.notAttempted(
          profile: profile, context: context, started: started,
          reason: ModelFailureClassifier.reason(for: error), discarded: discarded)
      }

      // 여기부터 요청이 나간다 — 이 아래의 실패는 모두 **시도**다.
      let attemptStarted = Date()
      let generated: GeneratedFinalAnswer
      let usage: ModelTokenUsage
      do {
        (generated, usage) = try await respond(
          session: session, context: context, profile: profile)
      } catch {
        let reason = ModelFailureClassifier.reason(for: error)
        let receipt = self.receipt(
          profile: profile, completed: false, fallbackReason: reason,
          context: context, started: attemptStarted)
        if source.allowsSameProviderRetry, ModelFailureClassifier.disposition(for: error) == .retry, discarded.isEmpty {
          discarded.append(receipt)
          Self.log.error("finalizer retrying reason=\(reason, privacy: .public)")
          continue
        }
        Self.log.error("finalizer failed reason=\(reason, privacy: .public)")
        return Outcome(
          answer: .unavailable(reason: reason),
          trail: ModelInvocationTrail(outcome: receipt, discarded: discarded))
      }

      let headline = generated.headline.trimmingCharacters(in: .whitespacesAndNewlines)
      let trail = ModelInvocationTrail(
        outcome: self.receipt(
          profile: profile, completed: !headline.isEmpty,
          fallbackReason: headline.isEmpty ? "empty" : nil, context: context,
          started: attemptStarted, usage: usage),
        discarded: discarded)
      guard !headline.isEmpty else {
        return Outcome(answer: .unavailable(reason: "empty"), trail: trail)
      }
      // 번호는 1부터다(문맥이 그렇게 세운다). 범위를 벗어난 번호는 버린다 —
      // 모델이 센 것과 문맥에 실린 것이 어긋나면 그 번호는 아무것도 가리키지
      // 않는다.
      let relevant = generated.relevant.filter { $0 > 0 && $0 <= context.evidenceCount }
      let points = Self.points(
        generated.points, relevant: relevant, evidenceCount: context.evidenceCount)
      Self.log.info(
        """
        finalizer calls=\(discarded.count + 1, privacy: .public) \
        tokens=\(usage.inputTokens, privacy: .public) \
        cached=\(usage.cachedInputTokens, privacy: .public) \
        cited=\(points.filter { $0.evidence != nil }.count, privacy: .public)/\
        \(points.count, privacy: .public)
        """)
      return Outcome(
        answer: .written(
          headline: headline, points: points, relevant: relevant,
          backend: source.target),
        trail: trail)
    }
  }

  /// 답의 줄들을 **버릴 것만 버리고** 옮긴다. 글은 모델의 것이고, 번호는 가리킬
  /// 것이 있을 때만 남는다.
  static func points(
    _ generated: [GeneratedFinalAnswer.Point], relevant: [Int], evidenceCount: Int
  ) -> [AnswerPoint] {
    generated.compactMap { point in
      let text = point.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      return AnswerPoint(
        text: text,
        evidence: Self.cited(point.evidence, relevant: relevant, evidenceCount: evidenceCount))
    }
  }

  /// 이 번호가 **무엇을 가리키는가.** 가리키는 것이 없으면 번호를 두지 않는다.
  ///
  /// 두 가지를 버린다. ① 문맥에 실린 근거의 수를 넘는 번호 — 모델이 센 것과 우리가
  /// 실은 것이 어긋난 경우다. ② 모델 자신이 `relevant`에서 맞다고 고르지 않은
  /// 근거를 가리키는 번호 — 같은 답 안의 자기모순이고, 그 번호를 화면에 세우면
  /// 사용자는 답과 무관한 출처를 근거로 읽는다.
  static func cited(_ number: Int, relevant: [Int], evidenceCount: Int) -> Int? {
    guard number > 0, number <= evidenceCount else { return nil }
    guard relevant.isEmpty || relevant.contains(number) else { return nil }
    return number
  }

  @available(iOS 27.0, *)
  private func respond(
    session: LanguageModelSession,
    context: CompiledConversationContext,
    profile: DynamicTurnProfile
  ) async throws -> (GeneratedFinalAnswer, ModelTokenUsage) {
    let options = DynamicProfileAdapter.generationOptions(for: profile)
    if !ModelResponseStream.isEnabled {
      let response = try await session.respond(
        to: context.prompt, generating: GeneratedFinalAnswer.self, options: options,
        contextOptions: DynamicProfileAdapter.contextOptions(for: profile))
      return (response.content, DynamicProfileAdapter.tokenUsage(response.usage))
    }
    let stream = session.streamResponse(
      to: context.prompt, generating: GeneratedFinalAnswer.self, options: options,
      contextOptions: DynamicProfileAdapter.contextOptions(for: profile))
    var throttle = ModelResponseStream.Throttle()
    do {
      for try await snapshot in stream {
        try Task.checkCancellation()
        let text = snapshot.content.headline ?? ""
        if throttle.shouldPublish(text) { await ModelResponseStream.publish(text) }
      }
      let response = try await stream.collect()
      await ModelResponseStream.publish(response.content.headline)
      return (response.content, DynamicProfileAdapter.tokenUsage(response.usage))
    } catch {
      await ModelResponseStream.publish("")
      throw error
    }
  }

  /// 요청이 **나가지 못했다.** 답 자리도 계획 자리와 같은 규칙을 쓴다(§36·§37).
  private func notAttempted(
    profile: DynamicTurnProfile, context: CompiledConversationContext, started: Date,
    reason: String, discarded: [ModelInvocationReceipt] = []
  ) -> Outcome {
    Self.log.error("finalizer not attempted reason=\(reason, privacy: .public)")
    return Outcome(
      answer: .unavailable(reason: reason),
      trail: ModelInvocationTrail(
        outcome: source.receipt(
          phase: .finalizing, purpose: AdmissionJob.conversationAnswer.rawValue,
          attempted: false, completed: false, reason: reason,
          characters: context.estimatedCharacters,
          milliseconds: Int(Date().timeIntervalSince(started) * 1_000)),
        discarded: discarded))
  }

  private func receipt(
    profile: DynamicTurnProfile,
    completed: Bool,
    fallbackReason: String?,
    context: CompiledConversationContext,
    started: Date,
    usage: ModelTokenUsage? = nil
  ) -> ModelInvocationReceipt {
    source.receipt(
      phase: .finalizing, purpose: AdmissionJob.conversationAnswer.rawValue,
      attempted: true, completed: completed, reason: fallbackReason,
      characters: context.estimatedCharacters,
      milliseconds: Int(Date().timeIntervalSince(started) * 1_000), usage: usage)
  }
}
