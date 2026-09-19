import Foundation

/// Model identity is independent of execution location. Replacing a model does not
/// add another case to ModelTarget and cannot change the tool permission boundary.
public struct InferenceModel: Codable, Hashable, Sendable {
  public enum Location: String, Codable, Sendable { case local, privateCloud }
  public enum Feature: String, Codable, Sendable { case text, structured, reasoning }

  public let id: String
  public let revision: String
  public let location: Location
  public let contextTokens: Int
  public let tokenizerID: String
  public let features: Set<Feature>
  public let purposes: Set<InferencePurpose>

  public init(id: String, revision: String, location: Location, contextTokens: Int,
              tokenizerID: String, features: Set<Feature>, purposes: Set<InferencePurpose>) {
    self.id = id; self.revision = revision; self.location = location
    self.contextTokens = contextTokens; self.tokenizerID = tokenizerID
    self.features = features; self.purposes = purposes
  }

  /// A cache key includes revision. A replacement never aliases the previous weights.
  public var identity: String { "\(id)@\(revision)" }
}

public enum InferencePurpose: String, Codable, CaseIterable, Sendable {
  case planning, reviewing, finalizing, summarization, translation, extraction, utility
}

public enum InferencePrivacy: String, Codable, Sendable {
  case deviceOnly, privateCloudAllowed
}

public struct InferenceEnvironment: Sendable, Equatable {
  public enum Thermal: Int, Codable, Sendable { case nominal, fair, serious, critical }
  public enum Network: String, Codable, Sendable { case unknown, online, offline }
  public var thermal: Thermal
  public var lowPower: Bool
  public var memoryPressure: Bool
  public var foreground: Bool
  public var network: Network
  public var privateCloudUsable: Bool
  public var privateCloudQuotaReached: Bool

  public init(thermal: Thermal = .nominal, lowPower: Bool = false,
              memoryPressure: Bool = false, foreground: Bool = true,
              network: Network = .unknown, privateCloudUsable: Bool = false,
              privateCloudQuotaReached: Bool = false) {
    self.thermal = thermal; self.lowPower = lowPower
    self.memoryPressure = memoryPressure; self.foreground = foreground
    self.network = network; self.privateCloudUsable = privateCloudUsable
    self.privateCloudQuotaReached = privateCloudQuotaReached
  }
}

public struct InferencePolicy: Codable, Equatable, Sendable {
  public struct Profile: Codable, Equatable, Sendable {
    public let modelOrder: [String]
    public let maximumOutputTokens: Int
    public let reasoning: Reasoning?
    /// A configured allowance for serialized schema / chat-template overhead.
    /// Calibrate this against the pinned adapter. Providers count text separately.
    public let framingReserveTokens: Int
    public let allowLocalInLowPower: Bool
    public let allowInfrastructureFallback: Bool

    public init(modelOrder: [String], maximumOutputTokens: Int = 1200,
                reasoning: Reasoning? = nil, framingReserveTokens: Int = 2048,
                allowLocalInLowPower: Bool = false,
                allowInfrastructureFallback: Bool = true) {
      self.modelOrder = modelOrder; self.maximumOutputTokens = maximumOutputTokens
      self.reasoning = reasoning; self.framingReserveTokens = framingReserveTokens
      self.allowLocalInLowPower = allowLocalInLowPower
      self.allowInfrastructureFallback = allowInfrastructureFallback
    }
  }
  public enum Reasoning: String, Codable, Sendable { case light, moderate, deep }
  public let schemaVersion: Int
  public let version: String
  /// Keys are InferencePurpose.rawValue to keep the JSON object human-editable.
  public let profiles: [String: Profile]

  public init(schemaVersion: Int = 1, version: String, profiles: [String: Profile]) {
    self.schemaVersion = schemaVersion; self.version = version; self.profiles = profiles
  }

  public func validated(catalog: [InferenceModel]) throws -> InferencePolicy {
    guard schemaVersion == 1, !version.isEmpty, version.utf8.count <= 128 else {
      throw InferencePolicyError.invalidPolicy("schemaVersion/version")
    }
    var seen = Set<String>()
    for model in catalog {
      guard !model.id.isEmpty, !model.revision.isEmpty, !model.tokenizerID.isEmpty,
            model.contextTokens > 0, model.contextTokens <= 1_048_576,
            !model.purposes.isEmpty, model.features.contains(.text),
            seen.insert(model.id).inserted else {
        throw InferencePolicyError.invalidPolicy("modelCatalog")
      }
    }
    let models = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
    /// A policy governs only the purposes it declares; turn purposes are required
    /// because the turn machine invokes those three purposes directly.
    let validKeys = Set(InferencePurpose.allCases.map(\.rawValue))
    guard profiles.keys.allSatisfy({ validKeys.contains($0) }) else {
      throw InferencePolicyError.invalidPolicy("unknownPurpose")
    }
    let requiredTurnPurposes: Set<String> = [
      InferencePurpose.planning.rawValue,
      InferencePurpose.reviewing.rawValue,
      InferencePurpose.finalizing.rawValue
    ]
    guard requiredTurnPurposes.isSubset(of: profiles.keys) else {
      throw InferencePolicyError.invalidPolicy("missingTurnPurpose")
    }
    for (key, profile) in profiles {
      guard !profile.modelOrder.isEmpty, profile.modelOrder.count <= 2,
            Set(profile.modelOrder).count == profile.modelOrder.count,
            profile.maximumOutputTokens > 0, profile.maximumOutputTokens <= 8192,
            profile.framingReserveTokens >= 0, profile.framingReserveTokens <= 8192 else {
        throw InferencePolicyError.invalidPolicy("profile:\(key)")
      }
      for id in profile.modelOrder {
        guard let model = models[id], let purpose = InferencePurpose(rawValue: key),
              model.purposes.contains(purpose),
              model.features.contains(.structured),
              profile.maximumOutputTokens + profile.framingReserveTokens < model.contextTokens else {
          throw InferencePolicyError.invalidPolicy("modelForProfile:\(key):\(id)")
        }
      }
      // A reasoning request must have at least one qualified provider. A local
      // fallback may omit optional reasoning, but never silently emulate it.
      if profile.reasoning != nil {
        guard profile.modelOrder.contains(where: { models[$0]?.features.contains(.reasoning) == true }) else {
          throw InferencePolicyError.invalidPolicy("reasoningProvider:\(key)")
        }
      }
    }
    return self
  }
}

public enum InferencePolicyError: Error, Equatable, Sendable {
  case invalidPolicy(String)
  case noEligibleModel([String])
  case contextTooLarge(model: String, total: Int, limit: Int)
  case invalidMeasurement
}

public enum InferenceFailure: String, Error, Codable, CaseIterable, Sendable {
  case cancelled, safetyJudgment, permissionDenied, contextOverflow, malformedOutput
  case quota, offline, timeout, modelUnavailable, thermalPressure, memoryPressure
  case unknown

  public var canFailOver: Bool {
    switch self {
    case .quota, .offline, .timeout, .modelUnavailable, .thermalPressure, .memoryPressure:
      return true
    default:
      return false
    }
  }
}

/// Pure policy evaluation. There is no model call, mutable global, or tool access.
public enum InferenceSelector {
  public struct Selection: Sendable, Equatable {
    public let model: InferenceModel
    public let policyVersion: String
    public let purpose: InferencePurpose
    public let reason: String
  }

  public static func select(
    purpose: InferencePurpose, privacy: InferencePrivacy,
    policy: InferencePolicy, catalog: [InferenceModel], installed: Set<String>,
    environment: InferenceEnvironment, excluded: Set<String> = []
  ) throws -> Selection {
    _ = try policy.validated(catalog: catalog)
    guard let profile = policy.profiles[purpose.rawValue] else {
      throw InferencePolicyError.invalidPolicy("missingPurpose")
    }
    var reasons: [String] = []
    for id in profile.modelOrder {
      guard !excluded.contains(id), let model = catalog.first(where: { $0.id == id }) else { continue }
      if let reason = ineligibleReason(model: model, privacy: privacy,
                                       installed: installed, environment: environment,
                                       allowLocalInLowPower: profile.allowLocalInLowPower) {
        reasons.append("\(id):\(reason)")
        continue
      }
      return Selection(model: model, policyVersion: policy.version, purpose: purpose,
                       reason: excluded.isEmpty ? "policyOrder" : "infrastructureFallback")
    }
    throw InferencePolicyError.noEligibleModel(reasons)
  }

  /// Re-evaluate after every suspension / admission wait and immediately before
  /// creating an executor. A device-only request never touches the PCC provider.
  public static func ineligibleReason(
    model: InferenceModel, privacy: InferencePrivacy, installed: Set<String>,
    environment: InferenceEnvironment, allowLocalInLowPower: Bool
  ) -> String? {
    switch model.location {
    case .local:
      if environment.thermal.rawValue >= InferenceEnvironment.Thermal.serious.rawValue {
        return "thermalPressure"
      }
      if environment.memoryPressure { return "memoryPressure" }
      if !environment.foreground { return "background" }
      if environment.lowPower && !allowLocalInLowPower { return "lowPower" }
      if !installed.contains(model.id) { return "modelNotInstalled" }
    case .privateCloud:
      if privacy == .deviceOnly { return "deviceOnly" }
      if environment.network == .offline { return "offline" }
      if !environment.privateCloudUsable { return "pccUnavailable" }
      if environment.privateCloudQuotaReached { return "quota" }
    }
    return nil
  }

  /// Total context, not "32K input plus an arbitrary output". Counts belong to
  /// this exact tokenizer/model; counts cannot be reused across models.
  public static func checkContext(
    model: InferenceModel, measuredTextTokens: Int, outputTokens: Int,
    framingTokens: Int, reasoningReserve: Int = 0
  ) throws {
    guard measuredTextTokens >= 0, outputTokens > 0, framingTokens >= 0,
          reasoningReserve >= 0 else { throw InferencePolicyError.invalidMeasurement }
    var total = measuredTextTokens
    for value in [outputTokens, framingTokens, reasoningReserve] {
      let sum = total.addingReportingOverflow(value)
      guard !sum.overflow else { throw InferencePolicyError.invalidMeasurement }
      total = sum.partialValue
    }
    guard total <= model.contextTokens else {
      throw InferencePolicyError.contextTooLarge(model: model.identity, total: total,
                                                 limit: model.contextTokens)
    }
  }

  public static func canFailOver(failure: InferenceFailure, profile: InferencePolicy.Profile,
                                publishedOutput: Bool, attemptedModels: Int) -> Bool {
    profile.allowInfrastructureFallback && failure.canFailOver
      && !publishedOutput && attemptedModels < min(2, profile.modelOrder.count)
  }
}

/// Replace a policy as one validated value. Callers retain an immutable snapshot
/// for their complete invocation, including failover. A malformed edit does not
/// discard the last known-good configuration.
public actor InferencePolicyStore {
  private let catalog: [InferenceModel]
  private var current: InferencePolicy

  public init(initial: InferencePolicy, catalog: [InferenceModel]) throws {
    self.current = try initial.validated(catalog: catalog); self.catalog = catalog
  }
  public func snapshot() -> InferencePolicy { current }
  public func replace(with data: Data) throws {
    guard data.count <= 64 * 1024 else {
      throw InferencePolicyError.invalidPolicy("policyTooLarge")
    }
    let decoded = try JSONDecoder().decode(InferencePolicy.self, from: data)
    current = try decoded.validated(catalog: catalog)
  }
}
