import Foundation

/// Revokes in-flight work even when an account signs out and back in with the same ID.
public enum AssistantAccountEpoch {
  private static let lock = NSLock()
  private static var value: UInt64 = 0

  public static var current: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  public static func invalidate() {
    lock.lock()
    defer { lock.unlock() }
    value &+= 1
  }
}
