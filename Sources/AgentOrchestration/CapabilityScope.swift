import AgentKernel
import Foundation


/// 이 차례에 모델에게 **보이는 도구 집합**.
///
/// 규칙은 하나다: **등록된 툴 전부를 보여 준다.**
///
/// 예전에는 문장을 규칙으로 읽어(`IntentSketch`) 영역을 고르고, 삭제 동사가
/// 없으면 삭제 툴을, 저장 동사가 없으면 저장 툴을 숨겼다. 그 구조에는 두 가지
/// 문제가 있었다:
///
/// 1. **모델이 볼 수 없는 툴은 고를 수 없다.** 규칙이 영역을 잘못 읽은 순간
///    사용자가 말한 일을 모델이 할 방법이 사라진다 — 그리고 그 실패는 "모델이
///    못 했다"로 보인다.
/// 2. **규칙과 모델이 같은 판단을 두 벌로 갖는다.** 낱말 표를 고칠 때마다
///    모델이 아는 것과 규칙이 아는 것이 갈라진다.
///
/// 위험한 툴을 막는 것은 **가시성이 아니라 승인**이다(`ApprovalPolicy`). 되돌릴
/// 수 없는 실행은 자격(`AuthorizationProof`) 없이는 승인 문을 지나야 하고,
/// 중복은 호출의 정체(멱등 열쇠)가 막는다. 보이지 않게 숨기는 것은 그 둘을
/// 대신하지 못한다 — 숨겨도 모델은 다른 툴로 같은 일을 시도한다.
public struct CapabilityScope: Sendable, Equatable {
  public let capabilities: Set<CapabilityID>

  public static let empty = CapabilityScope(capabilities: [])

  public init(capabilities: Set<CapabilityID>) {
    self.capabilities = capabilities
  }

  public var isEmpty: Bool { capabilities.isEmpty }

  /// 모델에게 세울 도구 목록. 순서를 고정한다 — 같은 요청이 같은 프롬프트를 만든다.
  public var sorted: [CapabilityID] {
    capabilities.sorted { $0.rawValue < $1.rawValue }
  }

  public func contains(_ capability: CapabilityID) -> Bool {
    capabilities.contains(capability)
  }

  /// 등록된 툴로 범위를 만든다.
  ///
  /// `registered`는 지금 실제로 손이 달린 능력이다(`ActionDispatcher.register`).
  /// 손이 없는 능력을 도구 목록에 세우면 모델이 그것을 고르고, 그 계획은 실행
  /// 직전에 죽는다.
  public static func compile(registered: Set<CapabilityID>) -> CapabilityScope {
    CapabilityScope(capabilities: registered)
  }

  /// 이 범위가 **무엇을 뺀 것인가**를 기록해 둔 자리는 없다.
  ///
  /// 끝난 쓰기를 범위에서 숨기던 손잡이가 여기 있었다. 숨기면
  /// `"두 사람에게 각각 보내줘"`가 반만 일어난다 — 첫 전송이 끝나자 그 능력이
  /// 사라져 두 번째를 계획할 수 없었다. 중복은 호출의 정체가 막는다
  /// (`TurnRuntime.callIdentity`): 같은 인자는 같은 멱등 열쇠로 막히고, 다른
  /// 인자는 다른 일이다. 감독자는 끝난 일을 `<<<completed>>>`로 본다.
}
