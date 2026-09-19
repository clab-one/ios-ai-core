import AgentKernel
import Foundation

/// 한 차례의 **복구 가능한 최소 상태**.
///
/// raw PCC 세션, 비밀 키, OAuth token, 공급자 원문, 숨겨진 사고 과정은 담지
/// 않는다. 담는 것은 다시 세우기 위해 꼭 필요한 것뿐이다 — 어느 계정·대화의 어떤
/// 요청이 어디까지 갔고, 무엇이 이미 효과를 냈고, 무엇이 승인을 기다리는가.
///
/// 저장 규약은 호스트가 붙인다(`TurnRunStore`). 코어는 표도, 스키마도 모른다 —
/// `schemaVersion`은 **이 값의 모양**을 세는 번호이고 호스트 DB의 버전이 아니다.
public struct TurnRunRecord: Codable, Equatable, Identifiable, Sendable {
  /// 2 = 효과의 정체를 든다(`effects`). 1의 `receiptKeys`는 나간 효과를 셀 수
  /// 없었으므로 **이어 읽지 않는다** — 저장소가 그 줄을 버린다.
  public static let currentSchemaVersion = 2

  public enum Status: String, Codable, Sendable {
    case running
    case awaitingApproval
    case awaitingUser
    case reconciling
    case interrupted
    case completed
    case partial
    case failed
    case cancelled

    public var isTerminal: Bool {
      switch self {
      case .completed, .partial, .failed, .cancelled: return true
      case .running, .awaitingApproval, .awaitingUser, .reconciling, .interrupted: return false
      }
    }
  }

  /// 정본 사용자 차례와 **같은** requestID. 코어가 새 UUID를 만들지 않는다.
  public var requestID: String
  public var accountID: String
  public var conversationID: String?
  /// 실행을 소유한 기기. 다른 기기에 동기화된 기록이 실행 명령으로 소비되지
  /// 않도록 고정한다.
  public var originDeviceID: String
  public var schemaVersion: Int
  public var policyVersion: Int
  public var status: Status
  /// 단조 증가. 늦게 도착한 저장이 앞선 상태를 되돌리지 못한다.
  public var stateRevision: Int
  public var input: String
  /// 이 차례가 읽은 대화 기록의 경계.
  public var historyCutoff: Int?
  /// 아직 실행하지 않은 단계의 **정규화된 정체**(capability#지문). 인자 원문은
  /// 담지 않는다.
  public var pendingStepIdentities: [String]
  /// 이 차례가 **바깥에 내려 한 효과들.** 복구가 "다시 보내도 되는가"를 묻는 자리다.
  ///
  /// 여기 있던 `receiptKeys`는 이름과 값이 달랐다(원장 열쇠가 아니라
  /// `ActionReceipt.requestID`였다). 더 나쁜 것은 **판정**이었다: 비어 있으면
  /// "효과 없음"으로 읽었으므로, 전송이 나간 뒤 수령증을 적기 전에 앱이 죽은
  /// 차례는 "끝나지 않았어요, 다시 보내 주세요"가 됐다 — 그리고 사용자가 다시
  /// 보내면 새 차례의 새 열쇠로 **같은 메일이 두 번** 나갔다(코드 리뷰
  /// 2026-09-18 P1). 효과가 나갔는지는 원장만 알고, 이 값은 **어느 열쇠를
  /// 물어야 하는지**를 들고 있다.
  public var effects: [TurnEffectCheckpoint]
  /// 승인 대기 중인 요청의 지문. 재시작 뒤 같은 대상·본문인지 다시 본다.
  public var pendingApprovalFingerprint: String?
  public var toolExecutions: Int
  public var supervisorIterations: Int
  public var pccCalls: Int
  public var localExtractions: Int
  public var createdAt: Date
  public var updatedAt: Date

  public var id: String { requestID }

  public init(
    requestID: String,
    accountID: String,
    conversationID: String? = nil,
    originDeviceID: String,
    schemaVersion: Int = TurnRunRecord.currentSchemaVersion,
    policyVersion: Int = 1,
    status: Status,
    stateRevision: Int,
    input: String,
    historyCutoff: Int? = nil,
    pendingStepIdentities: [String] = [],
    effects: [TurnEffectCheckpoint] = [],
    pendingApprovalFingerprint: String? = nil,
    toolExecutions: Int = 0,
    supervisorIterations: Int = 0,
    pccCalls: Int = 0,
    localExtractions: Int = 0,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.requestID = requestID
    self.accountID = accountID
    self.conversationID = conversationID
    self.originDeviceID = originDeviceID
    self.schemaVersion = schemaVersion
    self.policyVersion = policyVersion
    self.status = status
    self.stateRevision = stateRevision
    self.input = input
    self.historyCutoff = historyCutoff
    self.pendingStepIdentities = pendingStepIdentities
    self.effects = effects
    self.pendingApprovalFingerprint = pendingApprovalFingerprint
    self.toolExecutions = toolExecutions
    self.supervisorIterations = supervisorIterations
    self.pccCalls = pccCalls
    self.localExtractions = localExtractions
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

/// 차례 복구 상태가 놓이는 자리.
///
/// **쓰기 실패를 삼키지 않는다.** 원격 쓰기 직전의 저장이 실패하면 차례는 실행을
/// 멈춘다(fail closed) — 저장되지 않은 실행은 앱이 죽은 뒤 같은 메일을 두 번
/// 보낼 수 있고, 그것이 복구가 막아야 하는 단 하나의 사고다.
///
/// 저장하지 않는 호스트는 `NoTurnRunStore`를 쓴다. 그 선택은 **복구를 포기한다는
/// 뜻**이고, 조용히 성공하는 저장소로 감추지 않는다.
public protocol TurnRunStore: Sendable {
  func save(_ record: TurnRunRecord) throws

  /// 끝나지 않은 차례들. **재시작 뒤에 이 문이 없으면 복구는 로그일 뿐이다.**
  ///
  /// 앞판은 저장만 했다: 체크포인트는 디스크에 남았고, 앱을 다시 켜면 새 런타임이
  /// 서고 그 기록을 아무도 읽지 않았다(코드 리뷰 2026-09-18 P1). 읽는 문이 여기
  /// 있어야 코어가 "무엇이 중단됐는가"를 말할 수 있다.
  func loadUnfinished(limit: Int) throws -> [TurnRunRecord]

  /// 그 차례를 **잊는다.** 사람에게 알린 뒤, 또는 이어서 끝낸 뒤에 부른다 —
  /// 지우지 않으면 같은 중단이 재시작마다 다시 선다.
  func forget(requestID: String) throws
}

/// 복구 상태를 보관하지 않는 호스트의 자리.
///
/// 차례는 돌지만 앱이 죽으면 그 차례는 사라진다. 원격 쓰기가 있는 차례에서 이
/// 선택은 중복 전송의 위험을 남긴다 — 읽기만 하는 호스트에서만 안전하다.
public struct NoTurnRunStore: TurnRunStore {
  public init() {}
  public func save(_ record: TurnRunRecord) throws {}
  public func loadUnfinished(limit: Int) throws -> [TurnRunRecord] { [] }
  public func forget(requestID: String) throws {}
}

/// 한 차례가 **바깥에 내려 한 효과 하나**.
///
/// 담는 것은 열쇠와 이름뿐이다. 받는 사람도, 본문도 담지 않는다 — 이 값은
/// "무엇을 물어야 하는가"이고, 답은 원장에 있다.
public struct TurnEffectCheckpoint: Codable, Equatable, Sendable {
  public enum State: String, Codable, Sendable {
    /// 원장 선점 **전에** 적었다. 나갔는지는 이 값이 모른다 — 원장이 안다.
    case prepared
    case completed
    /// 결과를 아는 실패. 다시 보내도 된다.
    case failed
  }

  /// 효과의 정체(`ActionRequest.effectIdentity`). 원장의 열쇠와 같은 값이다.
  public var key: String
  public var capability: CapabilityID
  public var state: State

  public init(key: String, capability: CapabilityID, state: State) {
    self.key = key
    self.capability = capability
    self.state = state
  }
}

/// 재시작 뒤에 남아 있던 **중단된 차례 하나**.
///
/// 판정은 코어가 한다. 무엇을 자동으로 이어도 되는지는 능력의 권한에서 나오고
/// (`CapabilityID.authority`), 그 판정을 호스트마다 다시 쓰게 하면 어떤 앱은
/// 보낸 메일을 한 번 더 보낸다.
public struct InterruptedTurn: Sendable, Equatable, Identifiable {
  /// 이 중단을 **어떻게 닫을 수 있는가.**
  ///
  /// 앞판에는 이 값이 없었고 "수령증이 비었는가"로 갈랐다. 전송이 나간 뒤
  /// 수령증을 적기 전에 죽은 차례는 그래서 "다시 보내 주세요"가 됐다 — 그리고
  /// 다시 보내면 두 번 나갔다(코드 리뷰 2026-09-18 P1).
  public enum Recovery: String, Sendable {
    /// 아무것도 나가지 않았다. 사람이 다시 보내도 된다.
    case safeToRetry
    /// 허락을 기다리다 멈췄다. 나간 것은 없다.
    case awaitingApproval
    /// **보냈는지 모른다.** 화면은 "다시 보내 주세요"라고 말해선 안 된다 —
    /// 사람이 받은 곳을 확인해야 하고, 그 뒤에 열쇠를 놓아 준다.
    case outcomeUnknown
    /// 이미 나갔다. 다시 보내지 않는다.
    case committed
  }

  /// 효과 하나와 **원장이 아는 그 상태**. `nil`은 원장에 없다 = 나가지 않았다.
  public struct Effect: Sendable, Equatable {
    public let key: String
    public let capability: CapabilityID
    public let state: ActionLedgerEntry.State?

    public init(key: String, capability: CapabilityID, state: ActionLedgerEntry.State?) {
      self.key = key
      self.capability = capability
      self.state = state
    }
  }

  public let requestID: String
  public let input: String
  public let status: TurnRunRecord.Status
  /// 사람의 허락을 기다리다 멈췄는가. 화면은 그 사실을 말해야 한다.
  public let wasAwaitingApproval: Bool
  public let effects: [Effect]
  public let recovery: Recovery

  public var id: String { requestID }

  /// 같은 차례를 **코드가** 다시 시작해도 되는가.
  ///
  /// 읽기만 남은 차례뿐이다. 승인을 기다렸거나 효과를 낸 차례, 그리고 결과를
  /// 모르는 차례는 사람이 다시 시작해야 한다(§9.4).
  public var isSafeToRestart: Bool { recovery == .safeToRetry }

  /// 결과를 모르는 효과의 열쇠. 사람이 "확인했다"고 말한 뒤 이 열쇠를 놓아 준다
  /// (`AgentRuntime.allowResend`) — 놓아 주지 않으면 같은 문장을 다시는 보낼 수 없다.
  public var unknownEffectKeys: [String] {
    effects.filter { $0.state == .pending }.map(\.key)
  }

  init(_ record: TurnRunRecord, effects: [Effect]) {
    requestID = record.requestID
    input = record.input
    status = record.status
    let awaiting =
      record.status == .awaitingApproval || record.pendingApprovalFingerprint != nil
    wasAwaitingApproval = awaiting
    self.effects = effects
    // **모르는 것이 가장 먼저다.** 그 다음이 나간 것, 그 다음이 허락 대기다.
    if effects.contains(where: { $0.state == .pending }) {
      recovery = .outcomeUnknown
    } else if effects.contains(where: { $0.state == .completed }) {
      recovery = .committed
    } else if awaiting {
      recovery = .awaitingApproval
    } else {
      recovery = .safeToRetry
    }
  }
}
