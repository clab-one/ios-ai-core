import Foundation

/// An ephemeral, cumulative text snapshot. It is not a conversation commit,
/// a tool receipt, an approval, or a delta to append to the previous snapshot.
public struct TurnResponseSnapshot: Sendable, Equatable {
  public let requestID: UUID
  public let accountID: String
  public let conversationID: String?
  public let sequence: UInt64
  public let text: String

  public init(
    requestID: UUID, accountID: String, conversationID: String?,
    sequence: UInt64, text: String
  ) {
    self.requestID = requestID
    self.accountID = accountID
    self.conversationID = conversationID
    self.sequence = sequence
    self.text = text
  }
}

/// Task-local delivery preserves the existing TurnSupervising/TurnFinalizing seams.
/// It does not retain LanguageModelSession, transcript, or private model reasoning.
/// With no sink, the SDK adapter uses respond(), including background execution.
enum ModelResponseStream {
  typealias Sink = @MainActor @Sendable (String) -> Void
  @TaskLocal static var sink: Sink?

  static var isEnabled: Bool { sink != nil }

  static func publish(_ text: String) async {
    guard let sink else { return }
    await sink(text)
  }

  struct Throttle {
    private var lastInstant: ContinuousClock.Instant?
    private var lastText = ""

    mutating func shouldPublish(_ text: String) -> Bool {
      guard text != lastText else { return false }
      let now = ContinuousClock.now
      if let lastInstant, !text.isEmpty,
        lastInstant.duration(to: now) < .milliseconds(50)
      { return false }
      lastInstant = now
      lastText = text
      return true
    }
  }
}
