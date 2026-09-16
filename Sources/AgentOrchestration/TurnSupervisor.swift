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

  public init(
    context: CompiledConversationContext, profile: DynamicTurnProfile,
    conversationID: String?, accountID: String
  ) {
    self.context = context
    self.profile = profile
    self.conversationID = conversationID
    self.accountID = accountID
  }
}

/// 감독자 한 번의 결과. **모델 가용성에 묶이지 않은 값**이다.
///
/// 이 이음매가 있는 이유는 시험이다. 시뮬레이터에는 PCC도 기기 모델도 없으므로
/// (§48), 감독 되돌이가 1차 결과를 보고 2차 단계를 만드는지를 실제 모델로는
/// 확인할 수 없다 — 확인할 수 없는 규칙은 지켜지지 않는 규칙이다(§41).
public enum SupervisorStep: Sendable {
  case decided(TurnDecision, ModelInvocationTrail)
  case failed(
    disposition: ModelFailureDisposition, reason: String, ModelInvocationTrail)
}

/// 감독자를 대신 세우는 문. 기본값은 실제 모델이다(`TurnRuntime.liveSupervising`).
public typealias TurnSupervising = @MainActor (SupervisorRequest) async -> SupervisorStep

/// 답 한 벌과 그것을 만든 **호출들**의 영수증.
public struct FinalizationStep: Sendable {
  public let answer: FinalAnswer
  public let trail: ModelInvocationTrail

  public init(answer: FinalAnswer, trail: ModelInvocationTrail) {
    self.answer = answer
    self.trail = trail
  }
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
  private static let log = AgentHost.logger("orchestrator")

  public init() {}

  /// 한 되돌이의 결과와 그것을 만든 **호출들**의 영수증.
  public struct Outcome: Sendable {
    public let decision: TurnDecision
    public let trail: ModelInvocationTrail
  }

  /// 답하지 못했다. 처분은 공통 분류기가 정한다(§37) — 계획·재계획·답 쓰기가
  /// 서로 다른 규칙을 들면 한 곳을 고칠 때 나머지가 갈라진다.
  public struct Failure: Error, Sendable {
    public let disposition: ModelFailureDisposition
    public let reason: String
    public let trail: ModelInvocationTrail
  }

  /// 다음에 무엇을 부를지 정한다. **PCC가 정한다.**
  ///
  /// 일시적 실패(rate limit·timeout)는 같은 요청을 **한 번 더** 낸다. 가드레일과
  /// 거절은 인프라 실패가 아니라 판단이므로 다시 내지 않는다 — 같은 요청을 다른
  /// 모델이나 다른 경로로 우회하는 구조는 안전 장치를 무력화하는 구조다.
  public func decide(
    _ context: CompiledConversationContext,
    profile: DynamicTurnProfile,
    conversationID: String?,
    accountID: String
  ) async -> Result<Outcome, Failure> {
    let started = Date()
    guard #available(iOS 27.0, *) else {
      return .failure(
        Self.notAttempted(
          profile: profile, context: context, started: started,
          reason: ModelFailureClassifier.unsupportedReason))
    }
    // **물리 호출마다 영수증 한 장.** 버리는 것은 결과뿐이고, 나간 호출은 문맥을
    // 태웠다 — 한 장만 남기면 계측이 실제 요청 수보다 작게 나온다.
    var discarded: [ModelInvocationReceipt] = []
    while true {
      // **세션을 세우는 일과 요청을 내는 일을 나눈다.** 부르기 전에 막힌 것은
      // 시도가 아니고(§36), 그 구별을 사유 문자열 비교로 하면 분류기가 바뀌는 날
      // `pccAttempted`가 조용히 거짓이 된다. 경계를 **코드 구조로** 세운다.
      let session: LanguageModelSession
      do {
        session = try DynamicProfileAdapter.privateCloudSession(
          instructions: context.instructions)
      } catch {
        return .failure(
          Self.notAttempted(
            profile: profile, context: context, started: started,
            reason: ModelFailureClassifier.reason(for: error), discarded: discarded))
      }

      // 여기부터 요청이 나간다 — 이 아래의 실패는 모두 **시도**다.
      let attemptStarted = Date()
      do {
        let (generated, usage) = try await respond(
          session: session, context: context, profile: profile)
        let decision = ActionPlanValidator.validate(
          generated, allowed: profile.scope.sorted, conversationID: conversationID,
          accountID: accountID, calendar: context.calendar)
        Self.log.info(
          """
          supervisor phase=\(profile.phase.rawValue, privacy: .public) \
          status=\(decision.status.rawValue, privacy: .public) \
          steps=\(decision.plan.steps.count, privacy: .public) \
          calls=\(discarded.count + 1, privacy: .public) \
          tokens=\(usage.inputTokens, privacy: .public)
          """)
        return .success(
          Outcome(
            decision: decision,
            trail: ModelInvocationTrail(
              outcome: Self.receipt(
                profile: profile, completed: true, fallbackReason: nil,
                context: context, started: attemptStarted, usage: usage),
              discarded: discarded)))
      } catch {
        let reason = ModelFailureClassifier.reason(for: error)
        let disposition = ModelFailureClassifier.disposition(for: error)
        let receipt = Self.receipt(
          profile: profile, completed: false, fallbackReason: reason,
          context: context, started: attemptStarted)
        if disposition == .retry, discarded.isEmpty {
          discarded.append(receipt)
          Self.log.error(
            "supervisor retrying phase=\(profile.phase.rawValue, privacy: .public) reason=\(reason, privacy: .public)"
          )
          continue
        }
        Self.log.error(
          "supervisor failed phase=\(profile.phase.rawValue, privacy: .public) reason=\(reason, privacy: .public)"
        )
        return .failure(
          Failure(
            disposition: disposition, reason: reason,
            trail: ModelInvocationTrail(outcome: receipt, discarded: discarded)))
      }
    }
  }

  // MARK: 호출

  @available(iOS 27.0, *)
  private func respond(
    session: LanguageModelSession,
    context: CompiledConversationContext,
    profile: DynamicTurnProfile
  ) async throws -> (GeneratedTurnDecision, ModelTokenUsage) {
    let options = DynamicProfileAdapter.generationOptions(for: profile)
    // PCC 호출은 기기 대기열을 지나지 않는다 — 기기 모델을 붙잡지 않으므로
    // 입장 제어의 대상이 아니다. 기다린 시간이 0인 것은 사실이다.
    let response = try await session.respond(
      to: context.prompt, generating: GeneratedTurnDecision.self, options: options,
      contextOptions: DynamicProfileAdapter.contextOptions(for: profile))
    // **문맥 비용은 여기서만 사실이 된다.** 스키마와 `@Guide` 문구가 프롬프트에
    // 실리는 값은 우리가 센 글자 수 어디에도 없다(TN3193).
    return (response.content, DynamicProfileAdapter.tokenUsage(response.usage))
  }

  /// 요청이 **나가지 못했다.** 이 기기·계정으로 PCC를 열 수 없거나 iOS가 그
  /// API를 들고 있지 않다.
  ///
  /// 기기 모델이 계획을 대신 쓰지 않는다. 그리고 영수증에 `pccAttempted`를 적지
  /// 않는다 — 부르기 전에 막은 것은 시도가 아니다(§36).
  private static func notAttempted(
    profile: DynamicTurnProfile, context: CompiledConversationContext, started: Date,
    reason: String, discarded: [ModelInvocationReceipt] = []
  ) -> Failure {
    log.error("supervisor not attempted reason=\(reason, privacy: .public)")
    return Failure(
      disposition: .surfaceFailure,
      reason: reason,
      trail: ModelInvocationTrail(
        outcome: .notAttempted(
          phase: profile.phase,
          purpose: AdmissionJob.conversationPlan.rawValue,
          reason: reason,
          inputCharacters: context.estimatedCharacters,
          latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1_000)),
        discarded: discarded))
  }

  private static func receipt(
    profile: DynamicTurnProfile,
    completed: Bool,
    fallbackReason: String?,
    context: CompiledConversationContext,
    started: Date,
    usage: ModelTokenUsage? = nil
  ) -> ModelInvocationReceipt {
    ModelInvocationReceipt(
      phase: profile.phase,
      purpose: AdmissionJob.conversationPlan.rawValue,
      requestedBackend: .privateCloud,
      resolvedBackend: .privateCloud,
      // **부르려 했는가**가 처리 위치 고지의 근거다(§36). 고른 순간 참이 된다.
      pccAttempted: true,
      pccCompleted: completed,
      onDeviceAttempted: false,
      onDeviceCompleted: false,
      fallbackReason: fallbackReason,
      inputCharacters: context.estimatedCharacters,
      latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1_000),
      waitedMilliseconds: 0,
      usage: usage)
  }
}
