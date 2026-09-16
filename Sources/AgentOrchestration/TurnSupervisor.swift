import AgentKernel
import Foundation
import FoundationModels
import OSLog

/// 감독자에게 한 번 묻는 데 필요한 전부.
public struct SupervisorRequest: Sendable {
  public let context: CompiledConversationContext
  public let profile: DynamicTurnProfile
  public let conversationID: String?
  public let accountID: String
}

/// 감독자 한 번의 결과. **모델 가용성에 묶이지 않은 값**이다.
///
/// 이 이음매가 있는 이유는 시험이다. 시뮬레이터에는 PCC도 기기 모델도 없으므로
/// (§48), 감독 되돌이가 1차 결과를 보고 2차 단계를 만드는지를 실제 모델로는
/// 확인할 수 없다 — 확인할 수 없는 규칙은 지켜지지 않는 규칙이다(§41).
public enum SupervisorStep: Sendable {
  case decided(TurnDecision, ModelInvocationReceipt)
  case failed(
    disposition: ModelFailureDisposition, reason: String, ModelInvocationReceipt)
}

/// 감독자를 대신 세우는 문. 기본값은 실제 모델이다(`TurnRuntime.liveSupervising`).
public typealias TurnSupervising = @MainActor (SupervisorRequest) async -> SupervisorStep

/// 답 한 벌과 그것을 만든 모델의 영수증.
public struct FinalizationStep: Sendable {
  public let answer: FinalAnswer
  public let receipt: ModelInvocationReceipt
}

/// 답을 쓰는 자리를 대신 세우는 문.
public typealias TurnFinalizing = @MainActor (
  CompiledConversationContext, DynamicTurnProfile
) async -> FinalizationStep

/// 차례의 **감독자**.
///
/// 예전 구조는 계획 한 번이었다(`plan → execute → synthesize`). 그러면 첫 계획이
/// 무엇을 회수할지 모르는 상태에서 전부를 맞혀야 하고, 맞히지 못하면 차례가
/// 반쪽으로 끝난다. 새 구조는 되돌이다(§11):
///
/// ```
/// observe → decide → execute → observe → decide → … → finalize
/// ```
///
/// 매 되돌이에 감독자가 받는 것은 **지금까지 확인된 사실뿐**이다 — 압축된 근거와
/// 이미 끝난 능력의 목록. 모델의 앞 발언이나 사고 과정은 넘기지 않는다: 세션을
/// 물려주지 않으므로 넘길 이력 자체가 없다(`DynamicProfileAdapter.session`).
///
/// **실행 권한은 여기 없다.** 이 타입이 내는 것은 검증을 지난 `TurnDecision`
/// 하나이고, 그 결정이 실제로 도는지는 `ActionDispatcher`가 정한다.
@available(iOS 26.0, *)
public struct TurnSupervisor: Sendable {
  private static let log = Logger(
    subsystem: "dev.hyunminkim.justsend", category: "orchestrator")

  public let onDeviceModel: SystemLanguageModel

  public init(onDeviceModel: SystemLanguageModel = SystemLanguageModel.default) {
    self.onDeviceModel = onDeviceModel
  }

  /// 한 되돌이의 결과와 **그것을 만든 모델**.
  public struct Outcome: Sendable {
    public let decision: TurnDecision
    public let receipt: ModelInvocationReceipt
  }

  /// 답하지 못했다. 처분은 공통 분류기가 정한다(§37) — 계획·재계획·답 쓰기가
  /// 서로 다른 규칙을 들면 한 곳을 고칠 때 나머지가 갈라진다.
  public struct Failure: Error, Sendable {
    public let disposition: ModelFailureDisposition
    public let reason: String
    public let receipt: ModelInvocationReceipt
  }

  /// 다음에 무엇을 부를지 정한다.
  ///
  /// **PCC가 실패하면 기기 모델로 내려선다** — 단, 처분이 그것을 허락할 때만.
  /// 가드레일과 거절은 인프라 실패가 아니므로 우회하지 않는다.
  public func decide(
    _ context: CompiledConversationContext,
    profile: DynamicTurnProfile,
    conversationID: String?,
    accountID: String
  ) async -> Result<Outcome, Failure> {
    let started = Date()
    let requested = profile.modelTarget
    var resolved = DynamicProfileAdapter.resolvedTarget(for: profile)
    var fallbackReason: String?

    // 기다린 시간은 **실패에도 남는다.** 상자를 호출 밖에 두는 이유다 — 안에서
    // 만들면 던진 호출의 대기 시간이 사라지고, 지표는 "기다리지 않고 실패했다"는
    // 거짓을 말한다(독립 검토 지적).
    let wait = AdmissionWait()
    let generated: GeneratedTurnDecision
    do {
      generated = try await respond(
        context: context, profile: profile, target: resolved, wait: wait)
    } catch {
      let reason = ModelFailureClassifier.reason(for: error)
      let disposition = ModelFailureClassifier.disposition(
        for: error, backend: resolved)
      guard disposition == .retryOnDevice else {
        Self.log.error(
          "supervisor failed phase=\(profile.phase.rawValue, privacy: .public) reason=\(reason, privacy: .public)"
        )
        return .failure(
          Failure(
            disposition: disposition, reason: reason,
            receipt: Self.receipt(
              profile: profile, requested: requested, resolved: resolved,
              completed: false, fallbackReason: reason, context: context,
              started: started, waited: wait.milliseconds)))
      }
      // 일시적 실패. 기기 모델로 같은 일을 한 번 더.
      Self.log.error("supervisor cloud failed; retrying on device")
      do {
        generated = try await respond(
          context: context, profile: profile, target: .onDevice, wait: wait)
        fallbackReason = "pcc.\(reason)"
        resolved = .onDevice
      } catch {
        let retryReason = ModelFailureClassifier.reason(for: error)
        return .failure(
          Failure(
            disposition: ModelFailureClassifier.disposition(
              for: error, backend: .onDevice),
            reason: retryReason,
            receipt: Self.receipt(
              profile: profile, requested: requested, resolved: .onDevice,
              completed: false, fallbackReason: retryReason, context: context,
              started: started, waited: wait.milliseconds)))
      }
    }

    let decision = ActionPlanValidator.validate(
      generated, allowed: profile.scope.sorted, conversationID: conversationID,
      accountID: accountID, calendar: context.calendar)
    Self.log.info(
      """
      supervisor phase=\(profile.phase.rawValue, privacy: .public) \
      backend=\(resolved.rawValue, privacy: .public) \
      status=\(decision.status.rawValue, privacy: .public) \
      steps=\(decision.plan.steps.count, privacy: .public)
      """)
    return .success(
      Outcome(
        decision: decision,
        receipt: Self.receipt(
          profile: profile, requested: requested, resolved: resolved, completed: true,
          fallbackReason: fallbackReason, context: context, started: started,
          waited: wait.milliseconds)))
  }

  // MARK: 호출

  private func respond(
    context: CompiledConversationContext,
    profile: DynamicTurnProfile,
    target: ModelTarget,
    wait: AdmissionWait
  ) async throws -> GeneratedTurnDecision {
    let resolvedProfile = profile.retargeted(to: target)
    let session = try DynamicProfileAdapter.session(
      for: resolvedProfile, instructions: context.instructions,
      onDeviceModel: onDeviceModel)
    let options = DynamicProfileAdapter.generationOptions(for: resolvedProfile)
    if target == .privateCloud {
      // 클라우드 호출은 기기 대기열을 지나지 않는다 — 기기 모델을 붙잡지 않으므로
      // 입장 제어의 대상이 아니다. 기다린 시간이 0인 것은 사실이다.
      if #available(iOS 27.0, *) {
        return try await session.respond(
          to: context.prompt, generating: GeneratedTurnDecision.self, options: options,
          contextOptions: DynamicProfileAdapter.contextOptions(for: resolvedProfile)
        ).content
      }
      return try await session.respond(
        to: context.prompt, generating: GeneratedTurnDecision.self, options: options
      ).content
    }
    // 기기 모델 실행은 기존 입장 대기열을 지난다 — 발열·저전력에서 요약과
    // 계획이 동시에 돌면 둘 다 느려진다. **기다린 시간을 받아 적는다**(§12 PR 6).
    return try await ModelAdmission.withAdmission(
      for: .conversationPlan, admitted: { wait.record($0) }
    ) {
      if #available(iOS 27.0, *) {
        return try await session.respond(
          to: context.prompt, generating: GeneratedTurnDecision.self, options: options,
          contextOptions: DynamicProfileAdapter.contextOptions(for: resolvedProfile)
        ).content
      }
      return try await session.respond(
        to: context.prompt, generating: GeneratedTurnDecision.self, options: options
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
      phase: profile.phase,
      purpose: AdmissionJob.conversationPlan.rawValue,
      requestedBackend: requested,
      resolvedBackend: resolved,
      // **부르려 했는가**가 처리 위치 고지의 근거다(§36). 고른 순간 참이 된다.
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
