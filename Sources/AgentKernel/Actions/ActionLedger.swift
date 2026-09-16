import Foundation

/// 바깥으로 나간 쓰기 하나의 **내구성 있는 기록**.
///
/// 프로세스 메모리의 수령증만으로는 부족하다. 앱이 죽고 다시 뜨면 그 기억은
/// 사라지고, 사용자가(또는 자동화가) 같은 요청을 다시 보내면 메일이 두 번 나간다.
/// 원장은 그 재시도가 **디스크를 지나** 판정되게 한다.
public struct ActionLedgerEntry: Sendable, Hashable {
  public enum State: String, Sendable, Codable {
    /// 보냈고 결과를 아직 모른다. **이 상태에서 다시 보내지 않는다.**
    case pending
    case completed
    case failed
  }

  public let idempotencyKey: String
  public let accountID: String
  public let capability: CapabilityID
  public let state: State
  /// 공급자가 준 식별자 — 보낸 메일의 id.
  public let externalID: String?
  public let summary: String
  public let createdAt: Date
  public let settledAt: Date?

  public init(
    idempotencyKey: String,
    accountID: String,
    capability: CapabilityID,
    state: State,
    externalID: String? = nil,
    summary: String = "",
    createdAt: Date = Date(),
    settledAt: Date? = nil
  ) {
    self.idempotencyKey = idempotencyKey
    self.accountID = accountID
    self.capability = capability
    self.state = state
    self.externalID = externalID
    self.summary = summary
    self.createdAt = createdAt
    self.settledAt = settledAt
  }
}

/// 선점의 결과. **세 가지 답만** 있다.
public enum ActionLedgerClaim: Sendable, Hashable {
  /// 이 실행은 처음이거나, 앞의 실행이 실패로 확정됐다. 실행해도 된다.
  case granted(idempotencyKey: String)
  /// 이미 끝났다. 다시 실행하지 않고 그때의 수령증을 돌려준다.
  case alreadyCompleted(ActionLedgerEntry)
  /// 앞 실행의 결과 또는 이번 대상과의 일치를 확인하지 못했다.
  /// metadata 없는 legacy 완료도 대상 비교 전에는 이 상태로 돌려준다.
  /// **자동으로 다시 보내지 않는다** — 한 번도 못 보낸 것이 두 번 보낸 것보다 낫다.
  case inFlight(ActionLedgerEntry)
}

/// 기존 효과의 조회 결과. 조회 자체는 실행 권한이나 선점을 만들지 않는다.
public enum ActionLedgerReplay: Sendable, Hashable {
  case alreadyCompleted(ActionLedgerEntry)
  /// 이전 완료라도 이번 대상과 일치하는지 증명하지 못하면 미확인으로 남긴다.
  case inFlight(ActionLedgerEntry)
}

public protocol ActionLedger: Sendable {
  /// canonical/legacy identity를 읽기 전용으로 판정한다. nil이면 새 승인·선점이 필요하다.
  func replay(_ request: ActionRequest) throws -> ActionLedgerReplay?
  /// 실행을 선점한다. 같은 열쇠가 이미 있으면 그 상태가 답이 된다.
  func claim(
    _ request: ActionRequest, at date: Date
  ) throws -> ActionLedgerClaim
  /// claim이 돌려준 canonical key에 결과를 못 박는다. 성공이면 공급자 식별자가 함께 남는다.
  func settle(
    idempotencyKey: String, state: ActionLedgerEntry.State, externalID: String?,
    summary: String, at date: Date
  ) throws
  func entry(idempotencyKey: String) throws -> ActionLedgerEntry?
  /// 이 계정의 원장을 **모두** 지운다. 계정 경계에서만 부른다(로그아웃 정리) —
  /// 로그아웃한 계정의 전송 기록을 기기에 남겨 둘 이유가 없다.
  func deleteAll(accountID: String) throws
}

extension ActionLedger {
  public func claim(_ request: ActionRequest) throws -> ActionLedgerClaim {
    try claim(request, at: Date())
  }
}

extension CapabilityID {
  /// 이 능력이 **기기 밖으로 쓰는가.**
  ///
  /// 기기 안의 쓰기(캘린더·미리 알림)는 그 자체로 멱등 검사를 한다
  /// (`AppleCalendarCapability.existingEvent`). 되돌릴 수 없는 것은 바깥으로 나간
  /// 쓰기다 — 보낸 메일은 회수할 수 없고, Slack 메시지는 이미 남이 읽었다.
  public var isRemoteWrite: Bool {
    switch domain {
    case "mail", "chat", "social": writesOutsideTheApp
    default: false
    }
  }
}
