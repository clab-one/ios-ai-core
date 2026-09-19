import AgentKernel
import XCTest

@testable import AgentOrchestration

/// L0 — **기기 산출물은 모델 입력에 실리지 않는다**(`ResultEnvelope.staysOnDevice`,
/// `docs/AGENT_RUNTIME_DESIGN.ko.md` §ResultEnvelope).
///
/// 이 규칙은 예전에도 사실이었지만 그 근거가 `EvidenceCompiler.tellable`의
/// 부수 효과(계약에 없는 열쇠는 버린다)뿐이었다 — 어떤 툴이 산출물 자리를
/// 계약 인자로 선언하는 순간 조용히 뚫린다. 계약(`CapabilityContract.result`)으로
/// 올린 뒤 이 시험이 그 경계를 지킨다.
final class ResultEnvelopeTests: XCTestCase {
  private static let artifact = CapabilityID("test.device.artifact")
  private static let material = CapabilityID("test.device.material")

  override func setUp() {
    super.setUp()
    // 두 능력의 차이는 **결과 정책 하나**다. 인자·줄 모양은 같게 두어야 시험이
    // 그 하나를 재는 것이 된다.
    CapabilityContract.register([
      CapabilityContract(
        Self.artifact, authority: .observes, required: [],
        optional: [CapabilityContract.Argument("text")],
        result: .deviceArtifact),
      CapabilityContract(
        Self.material, authority: .observes, required: [],
        optional: [CapabilityContract.Argument("text")]),
    ])
  }

  private func receipt(_ capability: CapabilityID, body: String) -> ActionReceipt {
    ActionReceipt(
      requestID: UUID(), capability: capability, summary: "\(capability.rawValue).result",
      details: CapabilitySourceRow.detail([
        CapabilitySourceRow(title: "산출물", body: body, identifier: "artifact-1")
      ]).merging(["text": .text(body)], uniquingKeysWith: { current, _ in current }))
  }

  /// 기기가 만든 글은 근거로 오르지 않는다. 남는 것은 "무엇을 했는가" 한 줄이다.
  func testDeviceArtifactNeverBecomesModelEvidence() async {
    let body = "번역한 전문이다. 이 문장은 화면의 것이고 모델의 것이 아니다."
    let compiled = await EvidenceCompiler(query: "번역해줘")
      .compile([receipt(Self.artifact, body: body)], budget: LocalExtractionBudget(limit: 0))

    XCTAssertFalse(
      compiled.evidence.contains { $0.facts.contains { $0.contains(body) } },
      "기기 산출물 본문이 모델 근거로 올라갔다")
    XCTAssertTrue(
      compiled.evidence.contains { $0.facts.contains { $0.contains("\(Self.artifact.rawValue).result") } },
      "무엇을 했는가 한 줄까지 사라졌다 — 차례가 침묵한다")
  }

  /// 대조군. 같은 본문이라도 재료로 선언된 능력은 근거로 실린다 — 정책이
  /// 막는 것이지 본문 길이나 우연이 막는 것이 아니다.
  func testMaterialResultStillBecomesEvidence() async {
    let body = "읽은 원문이다. 이 문장은 답의 재료다."
    let compiled = await EvidenceCompiler(query: "요약해줘")
      .compile([receipt(Self.material, body: body)], budget: LocalExtractionBudget(limit: 0))

    XCTAssertTrue(
      compiled.evidence.contains { $0.facts.contains { $0.contains(body) } },
      "재료로 선언된 결과가 근거에서 빠졌다")
  }

  /// 계약을 선언하지 않은 능력은 **재료로 본다.** 모르는 것을 조용히 감추면
  /// 그 차례는 근거 없이 답한다.
  func testUndeclaredCapabilityIsTreatedAsMaterial() {
    XCTAssertFalse(EvidenceCompiler.staysOnDevice(CapabilityID("test.unknown.capability")))
  }
}
