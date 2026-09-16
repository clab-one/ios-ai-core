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
  private static let log = Logger(
    subsystem: "dev.hyunminkim.justsend", category: "orchestrator")

  public let onDeviceModel: SystemLanguageModel

  public init(onDeviceModel: SystemLanguageModel = SystemLanguageModel.default) {
    self.onDeviceModel = onDeviceModel
  }

  public struct Outcome: Sendable {
    public let answer: FinalAnswer
    public let receipt: ModelInvocationReceipt
  }

  /// 답 한 벌. **PCC가 실패하면 기기 모델로 내려선다** — 감독과 같은 규칙이고,
  /// 같은 분류기를 쓴다. 근거가 있는데 답만 못 써서 차례가 빈손으로 끝나면
  /// 사용자는 읽은 것도 받지 못한다.
  public func finalize(
    _ context: CompiledConversationContext, profile: DynamicTurnProfile
  ) async -> Outcome {
    let started = Date()
    let requested = profile.modelTarget
    var resolved = DynamicProfileAdapter.resolvedTarget(for: profile)
    var fallbackReason: String?

    // 기다린 시간은 **실패에도 남는다**(독립 검토 지적) — 상자를 호출 밖에 둔다.
    let wait = AdmissionWait()
    let generated: GeneratedFinalAnswer
    do {
      generated = try await respond(
        context: context, profile: profile, target: resolved, wait: wait)
    } catch {
      let reason = ModelFailureClassifier.reason(for: error)
      let disposition = ModelFailureClassifier.disposition(for: error, backend: resolved)
      guard disposition == .retryOnDevice else {
        Self.log.error("finalizer failed reason=\(reason, privacy: .public)")
        return Outcome(
          answer: .unavailable(reason: reason),
          receipt: Self.receipt(
            profile: profile, requested: requested, resolved: resolved,
            completed: false, fallbackReason: reason, context: context,
            started: started, waited: wait.milliseconds))
      }
      do {
        generated = try await respond(
          context: context, profile: profile, target: .onDevice, wait: wait)
        fallbackReason = "pcc.\(reason)"
        resolved = .onDevice
      } catch {
        let retryReason = ModelFailureClassifier.reason(for: error)
        return Outcome(
          answer: .unavailable(reason: retryReason),
          receipt: Self.receipt(
            profile: profile, requested: requested, resolved: .onDevice,
            completed: false, fallbackReason: retryReason, context: context,
            started: started, waited: wait.milliseconds))
      }
    }

    let headline = generated.headline.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !headline.isEmpty else {
      return Outcome(
        answer: .unavailable(reason: "empty"),
        receipt: Self.receipt(
          profile: profile, requested: requested, resolved: resolved, completed: false,
          fallbackReason: "empty", context: context, started: started,
          waited: wait.milliseconds))
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
        relevant: generated.relevant.filter { $0 > 0 }, backend: resolved),
      receipt: Self.receipt(
        profile: profile, requested: requested, resolved: resolved, completed: true,
        fallbackReason: fallbackReason, context: context, started: started,
        waited: wait.milliseconds))
  }

  private func respond(
    context: CompiledConversationContext,
    profile: DynamicTurnProfile,
    target: ModelTarget,
    wait: AdmissionWait
  ) async throws -> GeneratedFinalAnswer {
    let resolvedProfile = profile.retargeted(to: target)
    let session = try DynamicProfileAdapter.session(
      for: resolvedProfile, instructions: context.instructions,
      onDeviceModel: onDeviceModel)
    let options = DynamicProfileAdapter.generationOptions(for: resolvedProfile)
    if target == .privateCloud {
      if #available(iOS 27.0, *) {
        return try await session.respond(
          to: context.prompt, generating: GeneratedFinalAnswer.self, options: options,
          contextOptions: DynamicProfileAdapter.contextOptions(for: resolvedProfile)
        ).content
      }
      return try await session.respond(
        to: context.prompt, generating: GeneratedFinalAnswer.self, options: options
      ).content
    }
    // 답 쓰기는 계획과 **같은 줄에 서고 이름은 다르다** — 같은 기기 모델을 쥐지만
    // 지표에서 갈라져야 어느 목적이 줄을 오래 쥐었는지 말할 수 있다.
    return try await ModelAdmission.withAdmission(
      for: .conversationAnswer, admitted: { wait.record($0) }
    ) {
      if #available(iOS 27.0, *) {
        return try await session.respond(
          to: context.prompt, generating: GeneratedFinalAnswer.self, options: options,
          contextOptions: DynamicProfileAdapter.contextOptions(for: resolvedProfile)
        ).content
      }
      return try await session.respond(
        to: context.prompt, generating: GeneratedFinalAnswer.self, options: options
      ).content
    }
  }

  private static func receipt(
    profile: DynamicTurnProfile,
    requested: ModelTarget,
    resolved: ModelTarget,
    completed: Bool,
    fallbackReason: String?,
    context: CompiledConversationContext,
    started: Date,
    waited: Int = 0
  ) -> ModelInvocationReceipt {
    ModelInvocationReceipt(
      phase: .finalizing,
      purpose: AdmissionJob.conversationAnswer.rawValue,
      requestedBackend: requested,
      resolvedBackend: resolved,
      pccAttempted: requested == .privateCloud,
      pccCompleted: completed && resolved == .privateCloud,
      onDeviceAttempted: resolved == .onDevice,
      onDeviceCompleted: completed && resolved == .onDevice,
      fallbackReason: fallbackReason,
      inputCharacters: context.estimatedCharacters,
      latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1_000),
      waitedMilliseconds: waited)
  }
}
