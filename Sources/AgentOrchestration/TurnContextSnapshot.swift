import AgentKernel
import Foundation

/// 이 대화가 **손에 들고 있는 기록**. 앞차례에 건넨 첨부·링크·녹음이 여기 선다.
///
/// 이 값이 없던 동안 대화는 한 차례에서 끝났다: 사진을 붙여 물은 다음 차례에
/// `"요약해줘"`라고 하면 가리킬 대상이 없어 `"값이 하나 더 필요해요"`가 났고,
/// 사용자는 **같은 파일을 다시 올리고 같은 말을 다시** 해야 했다(실기
/// 2026-09-17, iPhone).
///
/// 실려 가는 것은 **식별자와 제목뿐**이다. 본문은 기기의 정본에 남아 있고,
/// 계획이 그 기록을 고르면 `memory.read`가 기기에서 읽는다 — 앞차례의 원문이
/// 다음 차례의 문맥으로 다시 올라가는 길은 만들지 않는다(§16·§24).
public struct HeldRecord: Sendable, Equatable {
  /// 기억 색인의 식별자. 계획이 `memory.read`의 인자로 쓴다.
  public let itemID: String
  /// 사람이 붙인 이름. 모델이 "그 파일"을 이 이름으로 고른다.
  public let title: String

  public init(itemID: String, title: String) {
    self.itemID = itemID
    self.title = title
  }
}

/// Captured at canonical ingress, never reconstructed from the selected screen.
public struct TurnContextSnapshot: Sendable {
  public let requestID: UUID
  public let accountID: String
  public let conversationID: String?
  public let accountEpoch: UInt64
  public let input: String
  public let submittedAt: Date
  public let referenceTime: Date
  public let timeZoneIdentifier: String
  public let localeIdentifier: String
  public let calendar: Calendar
  public let recentMessages: [ConversationMessage]
  /// 이 대화가 손에 들고 있는 기록. 호스트가 정본에서 읽어 넣는다.
  public let heldRecords: [HeldRecord]
  /// 사용자가 앞서 **스스로 말한 사실들**. 호스트가 정본에서 골라 넣는다.
  ///
  /// 관측이 아니다. 조수가 사람을 기억하는 자리이고(이름·가족·기기·취향),
  /// 확인된 기록은 도구가 회수한다 — 두 값을 섞지 않는 것이 이 자리의 전부다.
  public let knownFacts: [String]
  /// 창을 넘어간 앞 차례들의 **요약 한 덩이**. 호스트가 만들어 넣는다.
  ///
  /// `DialogueHistoryWindow`는 최근 12줄·2,400자만 싣고 나머지를
  /// `olderMessagesOmitted` 한 줄로 지운다 — 스무 차례짜리 대화의 첫 차례에서
  /// 정한 것을 마지막 차례가 알지 못한다. 이 값은 그 버린 자리를 **한 덩이의 글**로
  /// 잇는다. 관측이 아니고 사용자가 말한 사실도 아니다: 이 대화가 어디까지 왔는가다.
  public let earlierSummary: String?
  public let historyCutoff: Int?
  private(set) var registeredCapabilities: Set<CapabilityID>
  private(set) var connectorReadiness: [ConnectorReadinessSnapshot]

  public init(
    requestID: UUID, accountID: String, conversationID: String?, input: String,
    recentMessages: [ConversationMessage], heldRecords: [HeldRecord] = [],
    knownFacts: [String] = [],
    earlierSummary: String? = nil,
    submittedAt: Date = Date(),
    accountEpoch: UInt64 = AssistantAccountEpoch.current,
    timeZone: TimeZone = .current, locale: Locale = .current, calendar: Calendar = .current,
    historyCutoff: Int? = nil,
    registeredCapabilities: Set<CapabilityID> = [],
    connectorReadiness: [ConnectorReadinessSnapshot] = []
  ) {
    self.requestID = requestID
    self.accountID = accountID
    self.conversationID = conversationID
    self.accountEpoch = accountEpoch
    self.input = input
    self.submittedAt = submittedAt
    self.referenceTime = submittedAt
    self.timeZoneIdentifier = timeZone.identifier
    self.localeIdentifier = locale.identifier
    var capturedCalendar = calendar
    capturedCalendar.timeZone = timeZone
    capturedCalendar.locale = locale
    self.calendar = capturedCalendar
    self.recentMessages = recentMessages.filter { message in
      message.accountID == accountID && message.conversationID == conversationID
        && (historyCutoff.map { message.sequence < $0 } ?? true)
    }
    self.heldRecords = heldRecords
    self.knownFacts = knownFacts
    self.earlierSummary = earlierSummary
    self.historyCutoff = historyCutoff
    self.registeredCapabilities = registeredCapabilities
    self.connectorReadiness = connectorReadiness
  }
  public func prepared(registered: Set<CapabilityID>, connectors: [ConnectorReadinessSnapshot]) -> Self {
    var snapshot = self
    snapshot.registeredCapabilities = registered
    snapshot.connectorReadiness = connectors
    return snapshot
  }
}

public enum TurnStatus: String, Sendable, Codable {
  case running, awaitingApproval, awaitingUser, interrupted, reconciling
  case completed, partial, cancelled, failed
}

public enum TurnAnswerAvailability: String, Sendable, Codable {
  case available, unavailable, notRequired
}

public enum TurnEffectCompletion: String, Sendable, Codable {
  case none, completed, partial, unknown
}

public struct TurnEventEnvelope: Sendable {
  public let requestID: UUID
  public let accountID: String
  public let conversationID: String?
  public let accountEpoch: UInt64
  public let sequence: UInt64
  public let event: TurnEvent
}
