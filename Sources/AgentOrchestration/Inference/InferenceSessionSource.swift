import AgentKernel
import Foundation
import FoundationModels

/// Injected execution adapter. It owns no tools, approvals, or action ledger.
/// Sessions are fresh per invocation. Only immutable model weights may be shared.
@available(iOS 26.0, *)
public struct InferenceSessionSource: Sendable {
  public let model: InferenceModel
  public let policyVersion: String
  public let allowsSameProviderRetry: Bool
  public let makeSession: @Sendable (String) async throws -> LanguageModelSession
  /// Count this model's text tokenizer, before adding a separate framing reserve.
  public let countTextTokens: @Sendable (String) async throws -> Int
  public let isInstalled: @Sendable () async -> Bool
  private let observeReceipt: @Sendable (ModelInvocationReceipt) -> Void

  public init(model: InferenceModel, policyVersion: String = "legacy-pcc",
              allowsSameProviderRetry: Bool = true,
              makeSession: @escaping @Sendable (String) async throws -> LanguageModelSession,
              countTextTokens: @escaping @Sendable (String) async throws -> Int,
              isInstalled: @escaping @Sendable () async -> Bool = { true },
              observeReceipt: @escaping @Sendable (ModelInvocationReceipt) -> Void = { _ in }) {
    self.model = model; self.policyVersion = policyVersion
    self.allowsSameProviderRetry = allowsSameProviderRetry
    self.makeSession = makeSession; self.countTextTokens = countTextTokens
    self.isInstalled = isInstalled; self.observeReceipt = observeReceipt
  }

  public var target: ModelTarget { model.location == .local ? .onDevice : .privateCloud }

  public func pinned(to version: String,
                     observing: @escaping @Sendable (ModelInvocationReceipt) -> Void = { _ in }) -> Self {
    Self(model: model, policyVersion: version, allowsSameProviderRetry: false, makeSession: makeSession,
         countTextTokens: countTextTokens, isInstalled: isInstalled, observeReceipt: observing)
  }

  public func session(instructions: String) async throws -> LanguageModelSession {
    try Task.checkCancellation()
    return try await makeSession(instructions)
  }

  /// Preserves existing call sites; the host supplies this same source through
  /// the policy engine for production. No invisible fallback to Apple's local LLM.
  ///
  /// The declared window is the conservative floor. `PrivateCloudComputeLanguageModel`
  /// only reports its real `contextSize` asynchronously, so the host resolves it
  /// once at boot through `privateCloudResolved()`; a preflight that guessed high
  /// here would send a request the service refuses.
  public static var privateCloud: Self { privateCloud(contextTokens: 32768) }

  /// Measured once per process by the host. A failed query keeps the floor.
  public static func privateCloudResolved() async -> Self {
    guard #available(iOS 27.0, *) else { return privateCloud }
    guard let measured = try? await PrivateCloudComputeLanguageModel().contextSize,
          measured > 0 else { return privateCloud }
    return privateCloud(contextTokens: measured)
  }

  private static func privateCloud(contextTokens capacity: Int) -> Self {
    return Self(
      model: InferenceModel(
        id: "apple.pcc", revision: "os-managed", location: .privateCloud,
        contextTokens: capacity, tokenizerID: "apple.pcc.os-managed",
        features: [.text, .structured, .reasoning], purposes: Set(InferencePurpose.allCases)),
      makeSession: { instructions in
        guard #available(iOS 27.0, *), PrivateCloudComputeAccess.isUsable() else {
          throw AgentModelUnavailable.privateCloudUnsupported
        }
        return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: instructions)
      },
      countTextTokens: { text in
        // The PCC API's token-count availability has to match the app SDK.
        // Until a provider-specific tokenizer is available, this is an explicit
        // conservative UTF-8 byte bound, not a measured tokenizer count. This
        // path never sends input merely to count it. Response.usage is authoritative.
        text.utf8.count
      })
  }

  func receipt(phase: TurnPhase, purpose: String, attempted: Bool, completed: Bool,
               reason: String?, characters: Int, milliseconds: Int,
               waited: Int = 0, usage: ModelTokenUsage? = nil) -> ModelInvocationReceipt {
    let receipt = ModelInvocationReceipt(
      phase: phase, purpose: purpose, requestedBackend: target, resolvedBackend: target,
      pccAttempted: attempted && model.location == .privateCloud,
      pccCompleted: completed && model.location == .privateCloud,
      onDeviceAttempted: attempted && model.location == .local,
      onDeviceCompleted: completed && model.location == .local,
      fallbackReason: reason, inputCharacters: characters,
      latencyMilliseconds: milliseconds, waitedMilliseconds: waited, usage: usage,
      modelID: model.id, modelRevision: model.revision, policyVersion: policyVersion)
    observeReceipt(receipt)
    return receipt
  }
}
