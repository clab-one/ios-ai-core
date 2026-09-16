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
  public static let currentSchemaVersion = 1

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
  /// 이미 효과를 낸 실행의 원장 열쇠. 복구가 같은 전송을 다시 하지 않는 근거다.
  public var receiptKeys: [String]
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
    receiptKeys: [String] = [],
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
    self.receiptKeys = receiptKeys
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
}

/// 복구 상태를 보관하지 않는 호스트의 자리.
///
/// 차례는 돌지만 앱이 죽으면 그 차례는 사라진다. 원격 쓰기가 있는 차례에서 이
/// 선택은 중복 전송의 위험을 남긴다 — 읽기만 하는 호스트에서만 안전하다.
public struct NoTurnRunStore: TurnRunStore {
  public init() {}
  public func save(_ record: TurnRunRecord) throws {}
}
