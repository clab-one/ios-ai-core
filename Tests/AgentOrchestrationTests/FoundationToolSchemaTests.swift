import AgentKernel
import FoundationModels
import XCTest

@testable import AgentOrchestration

/// L0 — 계약 하나가 **SDK가 읽는 도구 스키마**가 된다
/// (`docs/AGENT_RUNTIME_DESIGN.ko.md` §Native tool bridge).
///
/// 이 시험이 지키는 것은 "변환이 돈다"가 아니라 **계약이 유일한 정본**이라는
/// 것이다: 능력마다 손으로 쓴 스키마를 두면 계약과 스키마가 갈라진다.
@available(iOS 26.0, *)
final class FoundationToolSchemaTests: XCTestCase {
  func testRequiredAndOptionalArgumentsSurviveTheConversion() throws {
    let contract = CapabilityContract(
      CapabilityID("test.schema.mail"),
      authority: .observes,
      required: [.init("to"), .init("body")],
      optional: [.init("count", .number), .init("flagged", .flag), .init("when", .timestamp)])

    let schema = try FoundationToolSchema.schema(for: contract)
    // SDK는 스키마 내부를 열어 주지 않는다. 계약의 자리 이름이 그대로 실렸는지는
    // 인코딩된 표현에서 본다 — 이름이 바뀌면 모델이 채운 값이 실행 직전
    // `normalize`에서 전부 버려진다.
    let encoded = String(data: try JSONEncoder().encode(schema), encoding: .utf8) ?? ""
    for key in ["to", "body", "count", "flagged", "when"] {
      XCTAssertTrue(encoded.contains(key), "계약의 자리 \(key)가 스키마에서 사라졌다")
    }
  }

  /// 인자가 없는 능력도 도구다 — 기기가 인자를 채우는 조회가 그렇다.
  func testCapabilityWithoutArgumentsStillProducesASchema() throws {
    let contract = CapabilityContract(CapabilityID("test.schema.empty"), authority: .observes)
    XCTAssertNoThrow(try FoundationToolSchema.schema(for: contract))
  }

  /// 도구 이름은 **능력 이름 그대로**다. 다른 이름을 붙이면 모델이 부른 도구와
  /// 원장에 남는 능력이 갈라진다.
  func testDefinitionKeepsTheCapabilityName() throws {
    let contract = CapabilityContract(CapabilityID("test.schema.named"), authority: .observes)
    let definition = try FoundationToolSchema.definition(for: contract, description: "시험용")
    XCTAssertEqual(definition.name, "test.schema.named")
  }
}
