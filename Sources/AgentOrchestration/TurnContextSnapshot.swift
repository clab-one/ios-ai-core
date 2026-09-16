import AgentKernel
import Foundation

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
  public let historyCutoff: Int?
  private(set) var registeredCapabilities: Set<CapabilityID>
  private(set) var connectorReadiness: [ConnectorReadinessSnapshot]

  public init(
    requestID: UUID, accountID: String, conversationID: String?, input: String,
    recentMessages: [ConversationMessage], submittedAt: Date = Date(),
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
