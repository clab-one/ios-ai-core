import Foundation

public enum SourceBinding: Sendable, Hashable, Codable {
  case connector(ConnectorBindingID)
  case accountLocal(accountID: String, domain: String)
  case publicWeb
}

public struct SourceReference: Sendable, Hashable, Codable {
  public enum Kind: String, Sendable, Codable {
    case mailMessage, chatMessage, calendarEvent, reminder, contact, document, memory, webPage
  }

  public let accountID: String
  public let binding: SourceBinding
  public let kind: Kind
  public let id: String
  public let containerID: String?
  public let revision: String?
  public let timestamp: Date?
  public let deepLink: URL?

  /// revision과 분리된 entity identity. 다른 계정/workspace의 같은 ID는 다르다.
  public var identity: String {
    var values: [String: ActionValue] = [
      "account": .text(accountID), "kind": .text(kind.rawValue), "id": .text(id),
      "container": .text(containerID ?? "")]
    switch binding {
    case .connector(let connector):
      values["provider"] = .text(connector.provider.rawValue)
      values["principal"] = .text(connector.principalID)
      values["workspace"] = .text(connector.workspaceID ?? "")
    case .accountLocal(let account, let domain):
      values["localAccount"] = .text(account)
      values["domain"] = .text(domain)
    case .publicWeb:
      values["publicWeb"] = .flag(true)
    }
    return ActionFingerprint.arguments(values)
  }

  public init(
    accountID: String, binding: SourceBinding, kind: Kind, id: String,
    containerID: String? = nil, revision: String? = nil, timestamp: Date? = nil,
    deepLink: URL? = nil
  ) {
    self.accountID = accountID
    self.binding = binding
    self.kind = kind
    self.id = id
    self.containerID = containerID
    self.revision = revision
    self.timestamp = timestamp
    self.deepLink = deepLink
  }
}

public struct CoverageRecord: Sendable, Hashable, Codable {
  public enum State: String, Sendable, Codable {
    case requested, running, complete, partial, unavailable, cancelled
  }
  public enum Reason: String, Sendable, Codable {
    case pagination, truncation, metadataUnavailable, bodyUnavailable, permission, providerFailure
  }

  public let binding: SourceBinding
  public let capability: CapabilityID
  public let queryFingerprint: String
  public let interval: DateInterval?
  public let state: State
  public let discoveredCount: Int
  public let readCount: Int
  public let paginationExhausted: Bool
  public let truncated: Bool
  public let reason: Reason?

  public init(
    binding: SourceBinding, capability: CapabilityID, queryFingerprint: String,
    interval: DateInterval? = nil, state: State, discoveredCount: Int, readCount: Int,
    paginationExhausted: Bool, truncated: Bool = false, reason: Reason? = nil
  ) {
    self.binding = binding
    self.capability = capability
    self.queryFingerprint = queryFingerprint
    self.interval = interval
    self.state = state
    self.discoveredCount = discoveredCount
    self.readCount = readCount
    self.paginationExhausted = paginationExhausted
    self.truncated = truncated
    self.reason = reason
  }
}
