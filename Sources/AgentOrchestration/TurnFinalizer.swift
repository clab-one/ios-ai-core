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
      the direct answer to the request: one full sentence stating the fact that \
      was asked for, written only from the provided data sections. Never a title \
      or a description of the source
      """)
  public let headline: String
  @Guide(
    description: "supporting facts, one sentence each, omitted when nothing to add",
    .maximumCount(3))
  public let points: [String]
  @Guide(
    description: """
      numbers of the evidence entries that actually match what the user asked \
      for, empty when none of them do
      """,
    .maximumCount(12))
  public let relevant: [Int]
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
    headline: String, points: [String], relevant: [Int], backend: ModelTarget)
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

  public init() {}

  public struct Outcome: Sendable {
    public let answer: FinalAnswer
    public let receipt: ModelInvocationReceipt
  }

  /// 답 한 벌. **PCC가 쓴다.**
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
      let reason = ModelFailureClassifier.unsupportedReason
      Self.log.error("finalizer unsupported reason=\(reason, privacy: .public)")
      return Outcome(
        answer: .unavailable(reason: reason),
        receipt: Self.receipt(
          profile: profile, completed: false, fallbackReason: reason, context: context,
          started: started))
    }
    var retried = false
    while true {
      let generated: GeneratedFinalAnswer
      do {
        generated = try await respond(context: context, profile: profile)
      } catch {
        let reason = ModelFailureClassifier.reason(for: error)
        if ModelFailureClassifier.disposition(for: error) == .retry, !retried {
          retried = true
          Self.log.error("finalizer retrying reason=\(reason, privacy: .public)")
          continue
        }
        Self.log.error("finalizer failed reason=\(reason, privacy: .public)")
        return Outcome(
          answer: .unavailable(reason: reason),
          receipt: Self.receipt(
            profile: profile, completed: false, fallbackReason: reason,
            context: context, started: started))
      }

      let headline = generated.headline.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !headline.isEmpty else {
        return Outcome(
          answer: .unavailable(reason: "empty"),
          receipt: Self.receipt(
            profile: profile, completed: false, fallbackReason: "empty",
            context: context, started: started))
      }
      let points = generated.points
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      return Outcome(
        answer: .written(
          headline: headline, points: points,
          // 번호는 1부터다(문맥이 그렇게 세운다). 범위를 벗어난 번호는 버린다 —
          // 모델이 센 것과 문맥에 실린 것이 어긋나면 그 번호는 아무것도 가리키지
          // 않는다.
          relevant: generated.relevant.filter { $0 > 0 }, backend: .privateCloud),
        receipt: Self.receipt(
          profile: profile, completed: true, fallbackReason: retried ? "retried" : nil,
          context: context, started: started))
    }
  }

  @available(iOS 27.0, *)
  private func respond(
    context: CompiledConversationContext,
    profile: DynamicTurnProfile
  ) async throws -> GeneratedFinalAnswer {
    let session = try DynamicProfileAdapter.privateCloudSession(
      instructions: context.instructions)
    let options = DynamicProfileAdapter.generationOptions(for: profile)
    return try await session.respond(
      to: context.prompt, generating: GeneratedFinalAnswer.self, options: options,
      contextOptions: DynamicProfileAdapter.contextOptions(for: profile)
    ).content
  }

  private static func receipt(
    profile: DynamicTurnProfile,
    completed: Bool,
    fallbackReason: String?,
    context: CompiledConversationContext,
    started: Date
  ) -> ModelInvocationReceipt {
    ModelInvocationReceipt(
      phase: .finalizing,
      purpose: AdmissionJob.conversationAnswer.rawValue,
      requestedBackend: .privateCloud,
      resolvedBackend: .privateCloud,
      pccAttempted: true,
      pccCompleted: completed,
      onDeviceAttempted: false,
      onDeviceCompleted: false,
      fallbackReason: fallbackReason,
      inputCharacters: context.estimatedCharacters,
      latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1_000),
      waitedMilliseconds: 0)
  }
}
