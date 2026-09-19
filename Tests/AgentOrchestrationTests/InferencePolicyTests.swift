import Foundation
import XCTest
@testable import AgentOrchestration

final class InferencePolicyTests: XCTestCase {
  let pcc = InferenceModel(id: "apple.pcc", revision: "os-managed", location: .privateCloud,
                          contextTokens: 32768, tokenizerID: "apple.pcc",
                          features: [.text, .structured, .reasoning],
                          purposes: Set(InferencePurpose.allCases))
  let gemma = InferenceModel(id: "gemma.local", revision: "immutable-revision", location: .local,
                            contextTokens: 32768, tokenizerID: "gemma3",
                            features: [.text, .structured], purposes: Set(InferencePurpose.allCases))
  var catalog: [InferenceModel] { [pcc, gemma] }
  func policy(order: [String] = ["apple.pcc", "gemma.local"],
              fallback: Bool = true, lowPower: Bool = false) -> InferencePolicy {
    InferencePolicy(version: "v1", profiles: Dictionary(uniqueKeysWithValues:
      [InferencePurpose.planning, .reviewing, .finalizing].map {
        ($0.rawValue, .init(modelOrder: order, allowLocalInLowPower: lowPower,
                           allowInfrastructureFallback: fallback))
      }))
  }
  func selected(_ environment: InferenceEnvironment = .init(privateCloudUsable: true),
                privacy: InferencePrivacy = .privateCloudAllowed,
                installed: Set<String> = ["gemma.local"],
                policy custom: InferencePolicy? = nil,
                excluded: Set<String> = []) throws -> InferenceSelector.Selection {
    try InferenceSelector.select(purpose: .planning, privacy: privacy,
      policy: custom ?? policy(), catalog: catalog, installed: installed,
      environment: environment, excluded: excluded)
  }
  func testOnlinePrefersPCC() throws { XCTAssertEqual(try selected().model, pcc) }
  func testOfflineUsesGemma() throws {
    XCTAssertEqual(try selected(.init(network: .offline, privateCloudUsable: true)).model, gemma)
  }
  func testDeviceOnlyNeverSelectsCloud() throws {
    XCTAssertEqual(try selected(privacy: .deviceOnly).model, gemma)
  }
  func testDeviceOnlyWithoutLocalFailsClosed() {
    XCTAssertThrowsError(try selected(privacy: .deviceOnly, installed: []))
  }
  func testSeriousAndOfflineNeverForcesLocal() {
    XCTAssertThrowsError(try selected(.init(thermal: .serious, network: .offline)))
  }
  func testCriticalAndDeviceOnlyWaitsRatherThanLeaks() {
    XCTAssertThrowsError(try selected(.init(thermal: .critical, privateCloudUsable: true),
                                     privacy: .deviceOnly))
  }
  func testThermalCloudAllowedUsesPCC() throws {
    XCTAssertEqual(try selected(.init(thermal: .serious, privateCloudUsable: true)).model, pcc)
  }
  func testQuotaFallsBackToLocal() throws {
    XCTAssertEqual(try selected(.init(privateCloudUsable: true, privateCloudQuotaReached: true)).model,
                   gemma)
  }
  func testQuotaAndPressureFails() {
    XCTAssertThrowsError(try selected(.init(memoryPressure: true, privateCloudUsable: true,
                                           privateCloudQuotaReached: true)))
  }
  func testMissingLocalStillUsesPCC() throws {
    XCTAssertEqual(try selected(installed: []).model, pcc)
  }
  func testLowPowerDoesNotWaitThirtySeconds() {
    XCTAssertThrowsError(try selected(.init(lowPower: true, network: .offline)))
  }
  func testLowPowerExplicitOverride() throws {
    XCTAssertEqual(try selected(.init(lowPower: true, network: .offline),
                                policy: policy(lowPower: true)).model, gemma)
  }
  func testBackgroundNeverStartsLocal() {
    XCTAssertThrowsError(try selected(.init(foreground: false, network: .offline)))
  }
  func testUnknownNetworkCanTryPCC() throws {
    XCTAssertEqual(try selected(.init(network: .unknown, privateCloudUsable: true)).model, pcc)
  }
  func testPolicyCanPreferLocal() throws {
    XCTAssertEqual(try selected(policy: policy(order: ["gemma.local", "apple.pcc"])).model, gemma)
  }
  func testExcludedAttemptCannotBeRetried() throws {
    XCTAssertEqual(try selected(excluded: ["apple.pcc"]).model, gemma)
    XCTAssertThrowsError(try selected(excluded: ["apple.pcc", "gemma.local"]))
  }
  func testSafetyNeverFailsOver() {
    XCTAssertFalse(InferenceSelector.canFailOver(failure: .safetyJudgment,
      profile: policy().profiles["planning"]!, publishedOutput: false, attemptedModels: 1))
  }
  func testCancellationNeverFailsOver() {
    XCTAssertFalse(InferenceSelector.canFailOver(failure: .cancelled,
      profile: policy().profiles["planning"]!, publishedOutput: false, attemptedModels: 1))
  }
  func testUnknownFailureNeverFailsOver() { XCTAssertFalse(InferenceFailure.unknown.canFailOver) }
  func testMalformedOutputNeverFailsOver() { XCTAssertFalse(InferenceFailure.malformedOutput.canFailOver) }
  func testContextOverflowNeverFailsOverUnchanged() { XCTAssertFalse(InferenceFailure.contextOverflow.canFailOver) }
  func testInfrastructureCanFailOver() {
    for failure in [InferenceFailure.quota, .offline, .timeout, .modelUnavailable,
                    .thermalPressure, .memoryPressure] {
      XCTAssertTrue(InferenceSelector.canFailOver(failure: failure,
        profile: policy().profiles["planning"]!, publishedOutput: false, attemptedModels: 1))
    }
  }
  func testPublishedOutputNeverReplacedByAnotherModel() {
    XCTAssertFalse(InferenceSelector.canFailOver(failure: .timeout,
      profile: policy().profiles["planning"]!, publishedOutput: true, attemptedModels: 1))
  }
  func testTwoProviderAttemptCeiling() {
    XCTAssertFalse(InferenceSelector.canFailOver(failure: .timeout,
      profile: policy().profiles["planning"]!, publishedOutput: false, attemptedModels: 2))
  }
  func testFallbackCanBeDisabled() {
    XCTAssertFalse(InferenceSelector.canFailOver(failure: .timeout,
      profile: policy(fallback: false).profiles["planning"]!, publishedOutput: false, attemptedModels: 1))
  }
  func test32KIncludesOutput() throws {
    try InferenceSelector.checkContext(model: gemma, measuredTextTokens: 30000,
                                        outputTokens: 1200, framingTokens: 1568)
    XCTAssertThrowsError(try InferenceSelector.checkContext(model: gemma,
      measuredTextTokens: 32768, outputTokens: 1, framingTokens: 0))
  }
  func testReasoningConsumesContext() {
    XCTAssertThrowsError(try InferenceSelector.checkContext(model: pcc,
      measuredTextTokens: 30000, outputTokens: 1200, framingTokens: 1024, reasoningReserve: 1024))
  }
  func testOverflowArithmeticFailsClosed() {
    XCTAssertThrowsError(try InferenceSelector.checkContext(model: gemma,
      measuredTextTokens: Int.max, outputTokens: 1, framingTokens: 1))
  }
  func testNegativeMeasurementRejected() {
    XCTAssertThrowsError(try InferenceSelector.checkContext(model: gemma,
      measuredTextTokens: -1, outputTokens: 1, framingTokens: 1))
  }
  func testUnknownModelRejected() {
    XCTAssertThrowsError(try policy(order: ["invented"]).validated(catalog: catalog))
  }
  func testDuplicateModelRejected() {
    XCTAssertThrowsError(try policy().validated(catalog: [pcc, pcc]))
    XCTAssertThrowsError(try policy(order: ["apple.pcc", "apple.pcc"]).validated(catalog: catalog))
  }
  func testThreeTurnPurposesMayOmitOptionalPurposes() throws {
    XCTAssertNoThrow(try policy().validated(catalog: catalog))
  }
  func testMissingPlanningPurposeRejected() {
    let profiles = [InferencePurpose.reviewing, .finalizing].reduce(into: [String: InferencePolicy.Profile]()) {
      $0[$1.rawValue] = .init(modelOrder: [pcc.id])
    }
    XCTAssertThrowsError(try InferencePolicy(version: "v1", profiles: profiles).validated(catalog: catalog))
  }
  func testUnknownPurposeRejected() {
    var profiles = policy().profiles
    profiles["not-a-purpose"] = .init(modelOrder: [pcc.id])
    XCTAssertThrowsError(try InferencePolicy(version: "v1", profiles: profiles).validated(catalog: catalog))
  }
  func testEmptyPolicyRejected() {
    XCTAssertThrowsError(try InferencePolicy(version: "v1", profiles: [:]).validated(catalog: catalog))
  }
  func testDifferentRevisionHasDifferentCacheIdentity() {
    let other = InferenceModel(id: gemma.id, revision: "replacement", location: .local,
      contextTokens: gemma.contextTokens, tokenizerID: gemma.tokenizerID,
      features: gemma.features, purposes: gemma.purposes)
    XCTAssertNotEqual(other.identity, gemma.identity)
  }
  func testPolicySnapshotIsImmutableAcrossReplacement() async throws {
    let initial = policy()
    let store = try InferencePolicyStore(initial: initial, catalog: catalog)
    let pinned = await store.snapshot()
    let changed = InferencePolicy(version: "v2", profiles: policy(order: ["gemma.local"]).profiles)
    try await store.replace(with: JSONEncoder().encode(changed))
    let current = await store.snapshot()
    XCTAssertEqual(pinned.version, "v1")
    XCTAssertEqual(current.version, "v2")
    XCTAssertEqual(pinned.profiles["planning"]?.modelOrder.first, pcc.id)
  }
  func testInvalidReplacementKeepsLastGoodPolicy() async throws {
    let initial = policy()
    let store = try InferencePolicyStore(initial: initial, catalog: catalog)
    do { try await store.replace(with: Data("{}".utf8)); XCTFail("expected rejection") } catch {}
    let current = await store.snapshot()
    XCTAssertEqual(current, initial)
  }
}
