import Foundation

/// 배경 실행이 보낼 수 있는 **payload의 모양**(§12 PR 7).
///
/// 허가는 내용이 아니라 모양을 못 박는다. 내용까지 못 박으면 그 허가는 한 번만
/// 쓸 수 있고, 모양조차 못 박지 않으면 "무엇이든 보내도 된다"가 된다 — 그 둘
/// 사이의 자리다. 실제 내용의 동일성은 `AuthorizationProof`의 호출 지문이 본다.
///
/// 이름을 계산으로 만드는 이유: 등록 화면과 실행기가 **같은 규칙**으로 같은 이름을
/// 내야 한다. 이름을 사람이 적으면 한쪽이 오타를 냈을 때 그 허가는 조용히 모든
/// 실행을 막거나(막히면 그나마 낫다) 다른 모양을 덮는다.
public enum AutomationPayloadPolicy {
  /// 이 요청의 정책 이름. 능력과 **채워진 인자 이름들**이 모양을 정한다.
  ///
  /// 값은 넣지 않는다 — 받는 사람이 같고 본문 길이만 다른 두 전송은 같은 모양이고,
  /// 첨부가 붙은 전송은 **다른 모양**이다.
  public static func name(
    capability: CapabilityID, arguments: [String: ActionValue]
  ) -> String {
    let filled =
      arguments
      .filter { !Self.isEmpty($0.value) }
      .keys
      .sorted()
      .joined(separator: ",")
    return "\(capability.rawValue)#\(filled)"
  }

  public static func name(for request: ActionRequest) -> String {
    name(capability: request.capability, arguments: request.arguments)
  }

  private static func isEmpty(_ value: ActionValue) -> Bool {
    switch value {
    case .text(let text): text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .list(let values): values.isEmpty
    default: false
    }
  }
}
