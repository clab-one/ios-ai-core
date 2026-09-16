import Foundation


/// One instance per turn; failed starts consume the same quota as successful ones.
public actor LocalExtractionBudget {
  public struct Usage: Sendable, Codable, Equatable {
    public var started = 0
    public var completed = 0
    public var failed = 0
    public var cancelled = 0
    public var unavailable = false
  }

  public enum Cached: Sendable {
    case absent
    case finished(Evidence?)
  }

  private let limit: Int
  private var usage = Usage()
  private var results: [String: Cached] = [:]

  public init(limit: Int = 4) { self.limit = max(0, limit) }

  public func cached(_ key: String) -> Cached { results[key] ?? .absent }
  public func snapshot() -> Usage { usage }
  public func markUnavailable() { usage.unavailable = true }

  /// Called inside the existing model admission, immediately before generation starts.
  public func reserve(_ key: String) -> Bool {
    guard !Task.isCancelled, !usage.unavailable, usage.started < limit,
      results[key] == nil
    else { return false }
    usage.started += 1
    results[key] = .finished(nil)
    return true
  }

  public func finish(_ key: String, evidence: Evidence?, cancelled: Bool = false) {
    results[key] = .finished(evidence)
    if evidence != nil { usage.completed += 1 }
    else if cancelled { usage.cancelled += 1 }
    else { usage.failed += 1 }
  }
}
