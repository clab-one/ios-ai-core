import AgentKernel
import XCTest

@testable import AgentOrchestration

/// L0 — **JEV 정책 검증기가 실제로 안전하게 정규화하는가.**
///
/// 아직 어떤 실행 경로도 이 정책을 호출하지 않는다(`docs/AGENT_RUNTIME_DESIGN.ko.md`
/// "실제 정책 모델 선택" — 실측 전에는 지연·누락률을 주장하지 않는다). 이 시험은
/// `ActionPlanValidator.validate`와 같은 계약만 독립적으로 증명한다: 범위 밖
/// capability는 버려지는가, 알 수 없는 추천값은 안전하게 실패로 떨어지는가,
/// confidence는 실측 없이는 항상 nil인가.
@available(iOS 26.0, *)
final class JEVPolicyTests: XCTestCase {
  private func generated(
    ranked: [String] = ["memory.search"], retrieval: Bool = true, generation: Bool = false,
    clarification: Bool = false, continuation: Bool = false,
    recommendation: String = "agentLocal"
  ) -> GeneratedJEVPolicy {
    GeneratedJEVPolicy(
      rankedCapabilities: ranked, needsRetrieval: retrieval, needsGeneration: generation,
      needsClarification: clarification, needsContinuation: continuation,
      recommendation: recommendation)
  }

  func testOutOfScopeCapabilitiesAreDroppedNotExecuted() {
    let outcome = JEVPolicyValidator.validate(
      generated(ranked: ["memory.search", "mail.send", "shell.exec"]),
      allowed: [.memorySearch, .mailSend], source: "foundation-models-on-device")
    guard case .decided(let decision) = outcome else {
      return XCTFail("정상 추천값인데 unavailable로 떨어졌다")
    }
    XCTAssertEqual(decision.rankedCapabilities, [.memorySearch, .mailSend])
    XCTAssertFalse(
      decision.rankedCapabilities.contains(CapabilityID("shell.exec")),
      "등록되지 않은 능력이 순위에 남았다")
  }

  func testUnrecognizedRecommendationFailsSafelyNotSilently() {
    let outcome = JEVPolicyValidator.validate(
      generated(recommendation: "deleteEverything"),
      allowed: [.memorySearch], source: "foundation-models-on-device")
    guard case .unavailable(let reason) = outcome else {
      return XCTFail("모르는 추천값을 조용히 받아들였다")
    }
    XCTAssertTrue(reason.contains("deleteEverything"), "실패 이유에 원인 값이 없다: \(reason)")
  }

  /// **정책 실패는 권한 실패가 아니다.** `unavailable`은 이유를 남기고, 임의의
  /// 높은 확률이나 빈 성공으로 위장하지 않는다.
  func testUnavailableCarriesReasonNotAFakeDecision() {
    let outcome = JEVPolicyValidator.validate(
      generated(recommendation: ""), allowed: [.memorySearch], source: "x")
    guard case .unavailable = outcome else {
      return XCTFail("빈 추천값이 결정으로 둔갑했다")
    }
  }

  /// confidence는 실측 없이는 항상 nil이다 — 생성 모델이 숫자를 냈다고 해도
  /// 보정된 성공 확률로 쓰지 않는다. `GeneratedJEVPolicy`에는애초에 confidence
  /// 필드가 없다: 모델이 낼 수 있는 자리 자체가 없다.
  func testDecidedConfidenceIsAlwaysNilWithoutMeasurement() {
    let outcome = JEVPolicyValidator.validate(
      generated(), allowed: [.memorySearch], source: "foundation-models-on-device")
    guard case .decided(let decision) = outcome else { return XCTFail("정상 케이스가 실패했다") }
    XCTAssertNil(decision.confidence, "실측 없이 confidence가 채워졌다")
  }

  func testSourceIsPreservedForAudit() {
    let outcome = JEVPolicyValidator.validate(
      generated(), allowed: [.memorySearch], source: "foundation-models-on-device@iOS26")
    guard case .decided(let decision) = outcome else { return XCTFail("정상 케이스가 실패했다") }
    XCTAssertEqual(decision.source, "foundation-models-on-device@iOS26")
  }

  func testAllFourRecommendationsRoundTrip() {
    for raw in ["directTool", "agentLocal", "agentPCC", "clarification"] {
      let outcome = JEVPolicyValidator.validate(
        generated(recommendation: raw), allowed: [.memorySearch], source: "x")
      guard case .decided(let decision) = outcome else {
        return XCTFail("\(raw)이 결정으로 정규화되지 않았다")
      }
      XCTAssertEqual(decision.recommendation.rawValue, raw)
    }
  }
}
