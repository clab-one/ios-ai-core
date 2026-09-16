import AgentKernel
import FoundationModels
import XCTest

@testable import AgentOrchestration

/// **L1: 기기 모델만 정말 부른다.** PCC는 부르지 않는다.
///
/// 여기서 보는 것은 요약의 문장 품질이 아니라 **압축이 실제로 일어나는가**다:
/// 6,000자가 들어가서 사실 몇 줄이 나오고, 그 몇 줄에 원문이 남아 있지 않은가.
/// 그 둘이 깨지면 PCC 비용은 원문 크기에 비례하기 시작한다.
///
/// 기기 모델이 없는 환경에서는 **건너뛴다.** 시뮬레이터에는 Apple Intelligence가
/// 없고, 그 사실을 실패로 적으면 실패의 뜻이 사라진다.
@available(iOS 26.0, *)
final class OnDeviceReductionTests: XCTestCase {
  private static let marker = "DEEP-MARKER-IN-THE-MIDDLE"
  private static let article =
    String(repeating: "애플은 서버에서 도는 추론의 검증 가능성을 이야기한다. ", count: 100)
    + marker
    + String(repeating: " 그리고 그 검증은 공개된 이미지로만 성립한다.", count: 100)

  func testLongArticleIsReducedOnDevice() async throws {
    let model = SystemLanguageModel.default
    try XCTSkipUnless(model.isAvailable, "이 기기에 기기 모델이 없다: \(model.availability)")

    XCTAssertGreaterThan(Self.article.count, 6_000, "픽스처가 충분히 길지 않다")
    let receipt = ActionReceipt(
      requestID: UUID(), capability: .webRead, summary: "web.read.result",
      details: CapabilitySourceRow.detail([
        CapabilitySourceRow(
          title: "PCC", body: Self.article, identifier: "https://example.com/pcc")
      ]))

    let compiled = await EvidenceCompiler(query: "검증은 어떻게 되는가", onDeviceModel: model)
      .compile([receipt], budget: LocalExtractionBudget())

    XCTAssertGreaterThan(compiled.localExtractions, 0, "기기 모델을 부르지 않았다")
    let facts = compiled.evidence.flatMap(\.facts)
    XCTAssertFalse(facts.isEmpty, "근거가 한 줄도 나오지 않았다")
    XCTAssertLessThanOrEqual(facts.count, Evidence.factsPerEvidence * 2, "사실이 너무 많다")

    let reduced = facts.joined(separator: "\n")
    print("📐 on-device: \(Self.article.count)자 → \(reduced.count)자 (\(facts.count)줄)")
    XCTAssertLessThan(
      Double(reduced.count) / Double(Self.article.count), 0.2, "압축이 일어나지 않았다")
    XCTAssertFalse(reduced.contains(Self.marker), "원문의 가운데 글자가 근거로 그대로 올라왔다")
  }
}
