import AgentKernel
import Foundation

/// P2 전환의 **선행 기반**(`docs/REMAINING_WORK.ko.md` "세션 실행과 영속 transcript 정본
/// 구현"). 지금의 `TurnRunRecord`/`TurnRunStore`는 중단 진단용 체크포인트다 — 도구
/// 인자·출력과 전체 세션 transcript를 복원하는 실행 journal은 아니다(코드 리뷰
/// 2026-09-18). 이 파일이 그 journal의 정본 타입을 정의한다.
///
/// **이 파일은 additive다.** 기존 `TurnRunRecord`/`TurnRunStore`/`ActionLedger`
/// 스키마와 정본 메시지는 건드리지 않는다. 이 journal이 실제 실행 경로에 연결되는
/// 것은 후속 PR(`AgentRunEngine`)이며, 그 전까지는 독립적으로 저장·복원이 맞는지만
/// 증명한다(`Tests`) — 이름을 만든 것을 구현 완료로 부르지 않는다
/// (`docs/openworker-port-map.md`).
///
/// hidden reasoning은 저장하지 않는다. journal에 남는 것은 prompt, response,
/// tool call, tool output, receipt 식별자뿐이다(§13 AGENT_RUNTIME_DESIGN.ko.md).

/// 세션(=섹션 ID) 하나. **대화 전체의 모델 작업 문맥을 소유하는 정체**다.
///
/// 제품의 섹션 ID·호스트의 `conversationID`와 같은 값이다 — 독립적인 두 번째
/// 대화 정본을 만들지 않는다.
public struct AgentSessionRecord: Codable, Equatable, Identifiable, Sendable {
  public let sessionID: String
  public let accountID: String
  public let createdAt: Date
  public var updatedAt: Date

  public var id: String { sessionID }

  public init(sessionID: String, accountID: String, createdAt: Date = Date(), updatedAt: Date? = nil) {
    self.sessionID = sessionID
    self.accountID = accountID
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
  }
}

/// run(=`requestID`의 실행 수명) 하나. **grant·원장·취소·예산·승인 대기·도구
/// journal을 소유**한다. 권한은 run마다 초기화되고, 작업 문맥은 session에 남는다.
public struct AgentRunRecord: Codable, Equatable, Identifiable, Sendable {
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

  public let runID: String
  public let sessionID: String
  public let accountID: String
  /// 계정 전환·재인증을 넘는 run 재사용을 막는 값. run grant 폐기 판정의 근거다.
  public let accountEpoch: UInt64
  public var status: Status
  /// 단조 증가. 늦게 도착한 저장이 앞선 상태를 되돌리지 못한다(기존
  /// `TurnRunRecord.stateRevision`과 같은 계약).
  public var transcriptRevision: Int
  public let createdAt: Date
  public var updatedAt: Date

  public var id: String { runID }

  public init(
    runID: String, sessionID: String, accountID: String, accountEpoch: UInt64,
    status: Status, transcriptRevision: Int = 0, createdAt: Date = Date(), updatedAt: Date? = nil
  ) {
    self.runID = runID
    self.sessionID = sessionID
    self.accountID = accountID
    self.accountEpoch = accountEpoch
    self.status = status
    self.transcriptRevision = transcriptRevision
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
  }
}

/// transcript 한 줄. **hidden reasoning은 여기 없다** — prompt/response/tool
/// call/tool output/notice만 담는다.
public struct AgentTranscriptEntry: Codable, Equatable, Identifiable, Sendable {
  public enum Role: String, Codable, Sendable {
    case user
    case assistant
    case tool
    /// 사람이 읽는 답이 아닌 실행 알림(압축 시작 등). UI 투영 전용.
    case notice
  }

  public let entryID: String
  public let runID: String
  /// 같은 run 안에서 **단조 증가**하는 순서. 복원이 이 순서로 재생한다.
  public let sequence: Int
  public let role: Role
  public let text: String
  /// `.tool` role일 때만 채운다 — 어느 도구 호출에 딸린 줄인지.
  public let toolCallID: String?
  public let createdAt: Date

  public var id: String { entryID }

  public init(
    entryID: String = UUID().uuidString, runID: String, sequence: Int, role: Role, text: String,
    toolCallID: String? = nil, createdAt: Date = Date()
  ) {
    self.entryID = entryID
    self.runID = runID
    self.sequence = sequence
    self.role = role
    self.text = text
    self.toolCallID = toolCallID
    self.createdAt = createdAt
  }
}

/// 도구 호출 하나의 수명주기. **원격 쓰기가 다시 나가도 되는지**를 복구가 이
/// 상태로 묻는다.
public struct ToolInvocationRecord: Codable, Equatable, Identifiable, Sendable {
  public enum State: String, Codable, Sendable {
    /// 모델이 제안했다. 아직 승인·실행 전이다.
    case proposed
    /// 승인을 받았다(또는 승인이 필요 없다). 실행 대기.
    case authorized
    case running
    case completed
    case failed
    /// 효과가 나갔는지 결과를 알 수 없다(네트워크 타임아웃 등). 복구가 이
    /// 상태를 재실행 금지 신호로 읽는다 — 완료로도 실패로도 낙관하지 않는다.
    case outcomeUnknown
  }

  public let callID: String
  public let runID: String
  public let capability: CapabilityID
  /// `ActionFingerprint`와 같은 정규화 지문. 재계획된 같은 호출을 같은 열쇠로 묶는다.
  public let fingerprint: String
  public var state: State
  /// 완료된 뒤 이 호출이 낸 `ActionReceipt`를 다시 찾는 손잡이.
  public var receiptID: String?
  /// 정규화된 인자 JSON. 재실행 판정의 근거이고, 비밀은 여기 두지 않는다.
  public let arguments: String
  /// 완료 후 `ActionReceipt` JSON. 실패·미완료면 nil — 없는 결과를 지어내지 않는다.
  public var receipt: String?
  /// 원격 쓰기의 `ActionRequest.effectIdentity`. 읽기면 nil.
  public let effectKey: String?
  public let createdAt: Date
  public var updatedAt: Date

  public var id: String { callID }

  public init(
    callID: String, runID: String, capability: CapabilityID, fingerprint: String,
    state: State, receiptID: String? = nil, arguments: String = "", receipt: String? = nil,
    effectKey: String? = nil, createdAt: Date = Date(), updatedAt: Date? = nil
  ) {
    self.callID = callID
    self.runID = runID
    self.capability = capability
    self.fingerprint = fingerprint
    self.state = state
    self.receiptID = receiptID
    self.arguments = arguments
    self.receipt = receipt
    self.effectKey = effectKey
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
  }
}

/// journal의 정본 저장소. 호스트가 자기 DB로 구현한다(`TurnRunStore`와 같은
/// 경계 — 코어는 SQL도, GRDB도 모른다).
///
/// **쓰기 실패를 삼키지 않는다.** 저장하지 않는 호스트는 `NoAgentRunJournal`을
/// 쓴다 — 그 선택은 이 journal 기반 복구를 포기한다는 뜻이고, 조용히 성공하는
/// 저장소로 감추지 않는다.
public protocol AgentRunJournal: Sendable {
  func saveSession(_ record: AgentSessionRecord) throws
  func session(id sessionID: String) throws -> AgentSessionRecord?

  /// 단조 증가 조건은 구현이 지킨다(`transcriptRevision`이 뒤로 가는 저장은 버림).
  func saveRun(_ record: AgentRunRecord) throws
  func run(id runID: String) throws -> AgentRunRecord?
  /// 재시작 뒤 끝나지 않은 run들. `AgentRunStore.loadUnfinished`와 같은 계약이다.
  func loadUnfinishedRuns(accountID: String, limit: Int) throws -> [AgentRunRecord]

  func appendTranscript(_ entry: AgentTranscriptEntry) throws
  /// `sequence` 순서로 정렬되어 돌아온다.
  func transcript(forRun runID: String) throws -> [AgentTranscriptEntry]

  func saveToolInvocation(_ record: ToolInvocationRecord) throws
  func toolInvocations(forRun runID: String) throws -> [ToolInvocationRecord]

  /// run이 끝난 뒤 그 run의 journal 전체를 잊는다. `TurnRunStore.forget`과
  /// 같은 자리 — 지우지 않으면 같은 중단이 재시작마다 다시 선다.
  func forgetRun(runID: String) throws
}

/// journal을 보관하지 않는 호스트의 자리. run은 돌지만 앱이 죽으면 그 run의
/// journal 기반 복구는 없다 — `NoTurnRunStore`와 같은 위험 고지다.
public struct NoAgentRunJournal: AgentRunJournal {
  public init() {}
  public func saveSession(_ record: AgentSessionRecord) throws {}
  public func session(id sessionID: String) throws -> AgentSessionRecord? { nil }
  public func saveRun(_ record: AgentRunRecord) throws {}
  public func run(id runID: String) throws -> AgentRunRecord? { nil }
  public func loadUnfinishedRuns(accountID: String, limit: Int) throws -> [AgentRunRecord] { [] }
  public func appendTranscript(_ entry: AgentTranscriptEntry) throws {}
  public func transcript(forRun runID: String) throws -> [AgentTranscriptEntry] { [] }
  public func saveToolInvocation(_ record: ToolInvocationRecord) throws {}
  public func toolInvocations(forRun runID: String) throws -> [ToolInvocationRecord] { [] }
  public func forgetRun(runID: String) throws {}
}
