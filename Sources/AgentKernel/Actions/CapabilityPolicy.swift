import Foundation

/// 능력의 **정책이 선언되는 자리.** 손을 다는 쪽이 선언하고, 실행은 여기서만 읽는다.
///
/// 왜 값이 코어의 `switch` 밖으로 나왔는가: 이 코어를 다른 앱에 실으면 그 앱은
/// `payment.send`나 `home.unlock` 같은 능력을 들고 온다. 그 이름은 코어의 표에
/// 없으므로 `.unclassified`로 떨어졌고 — 승인은 요구하지만 원장을 타지 않고
/// 약속한 쓰기로 세어지지도 않았다. 즉 **사람의 허락만 받은 채 crash-safe하지
/// 않은 외부 전송**이 성립했다(코드 리뷰 2026-09-18 P1). 코어의 표를 고쳐야만
/// 안전해지는 구조는 공용 코어가 아니다.
///
/// 그래서 권한은 등록에서 선언한다. 선언되지 않은 이름은 "승인 요구"로
/// **넘어가지 않고** 등록되지 않는다(`ActionDispatcher.register`) — fail safe가
/// 아니라 fail closed다.
///
/// 표는 여전히 하나다. 코어가 아는 이름의 값은 코어가 들고 있고
/// (`CapabilityID.declaredAuthority`), 호스트의 선언이 그와 **어긋나면 싣지
/// 않는다** — 권한에 대한 두 개의 답은 그 자체가 사고다.
final class CapabilityPolicy: @unchecked Sendable {
  static let shared = CapabilityPolicy()

  private let lock = NSLock()
  private var authorities: [CapabilityID: CapabilityID.Authority] = [:]
  private var consistencies: [CapabilityID: CapabilityID.TargetConsistency] = [:]

  /// 계약이 실은 선언을 싣는다. 돌려주는 값은 **코어의 표와 어긋나 거절된 능력**이다.
  @discardableResult
  func declare(_ contracts: [CapabilityContract]) -> Set<CapabilityID> {
    var refused: Set<CapabilityID> = []
    lock.lock()
    for contract in contracts {
      let capability = contract.capability
      if let authority = contract.authority {
        if let core = capability.declaredAuthority, core != authority {
          refused.insert(capability)
          continue
        }
        authorities[capability] = authority
      }
      if let consistency = contract.targetConsistency {
        consistencies[capability] = consistency
      }
    }
    lock.unlock()
    return refused
  }

  func authority(for capability: CapabilityID) -> CapabilityID.Authority? {
    lock.lock()
    defer { lock.unlock() }
    return authorities[capability]
  }

  func targetConsistency(for capability: CapabilityID) -> CapabilityID.TargetConsistency? {
    lock.lock()
    defer { lock.unlock() }
    return consistencies[capability]
  }
}
