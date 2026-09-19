import AgentKernel
import Foundation
import FoundationModels

/// Inference-only failover around the EXISTING TurnSupervisor/TurnFinalizer.
/// Never reruns a TurnRuntime or a tool after an inference failure.
@available(iOS 26.0, *)
@MainActor
public final class RoutedTurnModels {
  public typealias Environment = @MainActor @Sendable () -> InferenceEnvironment
  public typealias Privacy = @MainActor @Sendable () -> InferencePrivacy
  private let sources: [InferenceSessionSource]
  private let policies: InferencePolicyStore
  private let environment: Environment
  private let privacy: Privacy

  public init(sources: [InferenceSessionSource], policies: InferencePolicyStore,
              environment: @escaping Environment, privacy: @escaping Privacy) {
    self.sources = sources; self.policies = policies
    self.environment = environment; self.privacy = privacy
  }

  public var supervising: TurnSupervising {
    { [self] request in
      await supervise(request)
    }
  }
  public var finalizing: TurnFinalizing {
    { [self] context, profile in
      await finalize(context, profile: profile)
    }
  }

  private func supervise(_ request: SupervisorRequest) async -> SupervisorStep {
    let purpose: InferencePurpose = request.profile.phase == .reviewing ? .reviewing : .planning
    let result = await invoke(context: request.context, profile: request.profile, purpose: purpose) {
      source, profile in
      switch await TurnSupervisor(source: source).decide(
        request.context, profile: profile, conversationID: request.conversationID,
        accountID: request.accountID) {
      case .success(let outcome): return .success(outcome.decision, outcome.trail)
      case .failure(let failure): return .failure(failure.reason, failure.trail)
      }
    }
    switch result {
    case .success(let value, let trail): return .decided(value, trail)
    case .failure(let reason, let trail):
      return .failed(disposition: .surfaceFailure, reason: reason, trail)
    }
  }

  private func finalize(_ context: CompiledConversationContext,
                        profile: DynamicTurnProfile) async -> FinalizationStep {
    let result = await invoke(context: context, profile: profile, purpose: .finalizing) {
      source, effective in
      let outcome = await TurnFinalizer(source: source).finalize(context, profile: effective)
      switch outcome.answer {
      case .written: return .success(outcome.answer, outcome.trail)
      case .unavailable(let reason): return .failure(reason, outcome.trail)
      }
    }
    switch result {
    case .success(let value, let trail): return FinalizationStep(answer: value, trail: trail)
    case .failure(let reason, let trail):
      return FinalizationStep(answer: .unavailable(reason: reason), trail: trail)
    }
  }

  private enum Outcome<Value: Sendable>: Sendable {
    case success(Value, ModelInvocationTrail)
    case failure(String, ModelInvocationTrail)
  }

  private func invoke<Value: Sendable>(
    context: CompiledConversationContext, profile: DynamicTurnProfile,
    purpose: InferencePurpose,
    operation: @escaping @MainActor @Sendable (InferenceSessionSource, DynamicTurnProfile) async -> Outcome<Value>
  ) async -> Outcome<Value> {
    // Policy is pinned for the whole invocation, including its alternate provider.
    let policy = await policies.snapshot()
    guard let rule = policy.profiles[purpose.rawValue] else {
      return unavailable(profile, context, reason: "inference.invalidPolicy", receipts: [])
    }
    let dataBoundary = privacy()
    var excluded = Set<String>()
    var previous: [ModelInvocationReceipt] = []

    while excluded.count < min(2, rule.modelOrder.count) {
      if Task.isCancelled {
        return unavailable(profile, context, reason: "cancelled", receipts: previous)
      }
      var installed = Set<String>()
      for source in sources where source.model.location == .local {
        if await source.isInstalled() { installed.insert(source.model.id) }
      }
      let installedIDs = installed
      let selection: InferenceSelector.Selection
      do {
        selection = try InferenceSelector.select(
          purpose: purpose, privacy: dataBoundary, policy: policy,
          catalog: sources.map(\.model), installed: installedIDs,
          environment: environment(), excluded: excluded)
      } catch {
        return unavailable(profile, context, reason: Self.policyReason(error), receipts: previous)
      }
      guard let registered = sources.first(where: { $0.model == selection.model }) else {
        return unavailable(profile, context, reason: "inference.modelMissing", receipts: previous)
      }
      let observations = AttemptObservations()
      let source = registered.pinned(to: selection.policyVersion, observing: { observations.append($0) })
      excluded.insert(source.model.id)
      let effective = effectiveProfile(profile, rule: rule, source: source)
      let started = ContinuousClock.now
      let outcome: Outcome<Value>
      do {
        let job: @MainActor @Sendable () async throws -> Outcome<Value> = { [self] in
          try Task.checkCancellation()
          // After admission waiting, re-check resource AND privacy state. A user
          // changing to deviceOnly while queued cannot leak the old cloud context.
          let currentPrivacy = privacy() == .deviceOnly ? InferencePrivacy.deviceOnly : dataBoundary
          if let reason = InferenceSelector.ineligibleReason(
            model: source.model, privacy: currentPrivacy, installed: installedIDs,
            environment: environment(), allowLocalInLowPower: rule.allowLocalInLowPower) {
            throw RoutingBlocked(reason: reason)
          }
          let textCount = try await source.countTextTokens(context.instructions + "\n\n" + context.prompt)
          try Task.checkCancellation()
          let reasoningReserve: Int
          switch effective.reasoning {
          case .light: reasoningReserve = 1024
          case .moderate: reasoningReserve = 4096
          case .deep: reasoningReserve = 8192
          case nil: reasoningReserve = 0
          }
          try InferenceSelector.checkContext(
            model: source.model, measuredTextTokens: textCount,
            outputTokens: effective.maximumResponseTokens,
            framingTokens: rule.framingReserveTokens, reasoningReserve: reasoningReserve)
          // Tokenization can suspend too. Do not reuse a pre-tokenization check.
          let boundaryNow = privacy() == .deviceOnly ? InferencePrivacy.deviceOnly : dataBoundary
          if let reason = InferenceSelector.ineligibleReason(
            model: source.model, privacy: boundaryNow, installed: installedIDs,
            environment: environment(), allowLocalInLowPower: rule.allowLocalInLowPower) {
            throw RoutingBlocked(reason: reason)
          }
          let priorSink = ModelResponseStream.sink
          let observedSink: ModelResponseStream.Sink?
          if let priorSink {
            observedSink = { text in
              if !text.isEmpty { observations.markPublished() }
              priorSink(text)
            }
          } else { observedSink = nil }
          return await ModelResponseStream.$sink.withValue(observedSink) {
            await operation(source, effective)
          }
        }
        if source.model.location == .local {
          outcome = try await ModelAdmission.withImmediateAdmission(
            for: purpose == .finalizing ? .conversationAnswer : .conversationPlan,
            allowLowPower: rule.allowLocalInLowPower,
            conditions: { [self] in
              let state = await environment()
              if let reason = InferenceSelector.ineligibleReason(
                model: source.model, privacy: .deviceOnly, installed: installedIDs,
                environment: state, allowLocalInLowPower: rule.allowLocalInLowPower) {
                throw RoutingBlocked(reason: reason)
              }
            }, operation: job)
        } else {
          outcome = try await job()
        }
      } catch {
        let reason = Self.failureReason(error)
        let elapsed = Int((ContinuousClock.now - started) / .milliseconds(1))
        // Admission cancellation drains the underlying operation before returning.
        // Preserve its real receipt rather than claiming inference never began.
        let observed = observations.snapshot()
        let receipt = observed.last ?? source.receipt(phase: profile.phase, purpose: purpose.rawValue,
          attempted: false, completed: false, reason: reason,
          characters: context.estimatedCharacters, milliseconds: elapsed)
        outcome = .failure(reason, .init(outcome: receipt, discarded: Array(observed.dropLast())))
      }
      switch outcome {
      case .success(let value, let trail):
        return .success(value, .init(outcome: trail.outcome, discarded: previous + trail.discarded))
      case .failure(let reason, let trail):
        previous += trail.all
        // Only a nonempty snapshot delivered to the real UI sink freezes the
        // provider. An offline error before first output can still fail over.
        let published = observations.didPublish()
        guard InferenceSelector.canFailOver(failure: Self.failure(reason), profile: rule,
          publishedOutput: published, attemptedModels: excluded.count) else {
          return .failure(reason, .init(outcome: trail.outcome,
                                       discarded: Array(previous.dropLast())))
        }
      }
    }
    return unavailable(profile, context, reason: "inference.exhausted", receipts: previous)
  }

  private func effectiveProfile(_ original: DynamicTurnProfile, rule: InferencePolicy.Profile,
                                source: InferenceSessionSource) -> DynamicTurnProfile {
    var selectedReasoning: DynamicTurnProfile.Reasoning?
    if source.model.features.contains(.reasoning) {
      switch rule.reasoning {
      case .light: selectedReasoning = .light
      case .moderate: selectedReasoning = .moderate
      case .deep: selectedReasoning = .deep
      case nil: selectedReasoning = nil
      }
    }
    return DynamicTurnProfile(
      phase: original.phase, modelTarget: source.target, reasoning: selectedReasoning,
      scope: original.scope, contextPolicy: original.contextPolicy,
      // TurnSupervisor emits a typed PROPOSAL; it does not need SDK-owned tool calls.
      toolCalling: .disallowed,
      maximumResponseTokens: min(original.maximumResponseTokens, rule.maximumOutputTokens),
      asking: original.asking)
  }

  private func unavailable<Value: Sendable>(_ profile: DynamicTurnProfile, _ context: CompiledConversationContext,
                                  reason: String, receipts: [ModelInvocationReceipt]) -> Outcome<Value> {
    let receipt = ModelInvocationReceipt.notAttempted(
      phase: profile.phase, purpose: "routing", reason: reason,
      inputCharacters: context.estimatedCharacters, latencyMilliseconds: 0)
    return .failure(reason, .init(outcome: receipt, discarded: receipts))
  }
  private struct RoutingBlocked: Error { let reason: String }
  private static func policyReason(_ error: any Error) -> String {
    if case InferencePolicyError.noEligibleModel(let reasons) = error {
      return "inference.unavailable[" + reasons.joined(separator: ",") + "]"
    }
    return "inference.invalidPolicy"
  }
  private static func failureReason(_ error: any Error) -> String {
    if error is CancellationError { return "cancelled" }
    if error is InferencePolicyError { return "context" }
    if let blocked = error as? RoutingBlocked { return blocked.reason }
    if error is ModelAdmissionError { return "thermalPressure" }
    return ModelFailureClassifier.reason(for: error)
  }
  private static func failure(_ reason: String) -> InferenceFailure {
    switch reason {
    case "cancelled": return .cancelled
    case "guardrail", "refusal": return .safetyJudgment
    case "quota", "rateLimited": return .quota
    case "offline": return .offline
    case "timeout": return .timeout
    case "assets", "model.unavailable", "pcc.unsupported", "pccUnavailable", "modelNotInstalled":
      return .modelUnavailable
    case "thermalPressure", "lowPower", "background": return .thermalPressure
    case "memoryPressure": return .memoryPressure
    case "context": return .contextOverflow
    case "decoding": return .malformedOutput
    default: return .unknown
    }
  }
}

/// Ephemeral observation only, never an action ledger or persistent journal.
private final class AttemptObservations: @unchecked Sendable {
  private let lock = NSLock()
  private var receipts: [ModelInvocationReceipt] = []
  private var published = false
  func markPublished() { lock.lock(); defer { lock.unlock() }; published = true }
  func didPublish() -> Bool { lock.lock(); defer { lock.unlock() }; return published }
  func append(_ receipt: ModelInvocationReceipt) {
    lock.lock(); defer { lock.unlock() }; receipts.append(receipt)
  }
  func snapshot() -> [ModelInvocationReceipt] {
    lock.lock(); defer { lock.unlock() }; return receipts
  }
}
