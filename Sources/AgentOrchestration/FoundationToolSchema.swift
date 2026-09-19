import AgentKernel
import Foundation
import FoundationModels

/// 능력의 계약을 **Foundation Models가 읽는 도구 스키마**로 옮긴다
/// (`docs/AGENT_RUNTIME_DESIGN.ko.md` §Native tool bridge).
///
/// 설계의 요구는 한 문장이다: "고정된 command catalog를 다른 Swift switch로
/// 복제하지 않는다." 도구 목록의 정본은 이미 `CapabilityContract`이고, SDK가
/// 요구하는 모양은 `GenerationSchema`다. 그 사이를 **표 하나로** 잇는다 —
/// 능력마다 손으로 쓴 스키마를 두면 계약과 스키마가 갈라지고, 갈라진 순간
/// 모델은 우리가 검사하지 않는 칸을 채운다.
///
/// ## 이 변환이 하지 않는 것
///
/// - **실행하지 않는다.** 스키마를 만드는 일과 도구를 부르는 일은 다른 자리다.
///   승인·원장·계정 경계는 `ActionDispatcher`의 것이고, 이 파일은 그 앞의 모양만
///   맡는다.
/// - **없는 정보를 지어내지 않는다.** 계약에는 인자 설명문도, enum 후보도 없다.
///   그래서 스키마의 `description`은 비운다 — 있지도 않은 설명을 만들어 넣으면
///   모델은 우리가 검증하지 않은 문장을 근거로 값을 고른다.
@available(iOS 26.0, *)
public enum FoundationToolSchema {
  /// 계약 하나의 인자 스키마. 인자가 없으면 빈 구조가 나온다 — 그것도 유효한
  /// 도구다(`calendar.search`처럼 기기가 인자를 채우는 능력).
  public static func schema(for contract: CapabilityContract) throws -> GenerationSchema {
    let properties =
      contract.required.map { property($0, isOptional: false) }
      + contract.optional.map { property($0, isOptional: true) }
    let root = DynamicGenerationSchema(
      name: identifier(for: contract.capability), properties: properties)
    return try GenerationSchema(root: root, dependencies: [])
  }

  /// SDK의 도구 정의 한 줄. `name`은 능력 이름 그대로다 — 다른 이름을 붙이면
  /// 모델이 부른 도구와 원장에 남는 능력이 갈라진다.
  public static func definition(
    for contract: CapabilityContract, description: String
  ) throws -> Transcript.ToolDefinition {
    Transcript.ToolDefinition(
      name: contract.capability.rawValue, description: description,
      parameters: try schema(for: contract))
  }

  private static func property(
    _ argument: CapabilityContract.Argument, isOptional: Bool
  ) -> DynamicGenerationSchema.Property {
    DynamicGenerationSchema.Property(
      name: argument.key, schema: schema(for: argument.kind), isOptional: isOptional)
  }

  /// 계약의 값 종류를 SDK의 원시 타입으로.
  ///
  /// `timestamp`가 문자열인 이유: SDK에 날짜 원시 타입이 없다. 모델이 채운 글은
  /// 실행 전에 `CapabilityContract.normalize`가 다시 본다 — 검증은 이 자리가
  /// 아니라 거기 한 곳에만 있어야 한다.
  ///
  /// `list`가 문자열 배열인 이유: 계약이 원소 종류를 말하지 않는다(그 필드의
  /// 주석). 모르는 것을 구조로 단정하지 않는다.
  private static func schema(for kind: CapabilityContract.ValueKind) -> DynamicGenerationSchema {
    switch kind {
    case .text, .timestamp:
      return DynamicGenerationSchema(type: String.self)
    case .number:
      return DynamicGenerationSchema(type: Double.self)
    case .flag:
      return DynamicGenerationSchema(type: Bool.self)
    case .list:
      return DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self))
    }
  }

  /// 스키마 이름. SDK는 식별자 모양을 요구하므로 `.`을 `_`로 바꾼다 — 능력 이름
  /// 자체(`mail.send`)는 `definition(for:description:)`의 `name`이 그대로 든다.
  private static func identifier(for capability: CapabilityID) -> String {
    capability.rawValue.replacingOccurrences(of: ".", with: "_")
  }
}
