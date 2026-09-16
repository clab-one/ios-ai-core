import CryptoKit
import Foundation

/// Versioned, typed and length-delimited; unlike a display string it is unambiguous.
public enum ActionFingerprint {
  public static func arguments(_ arguments: [String: ActionValue]) -> String {
    var bytes = Data("action-arguments-v1".utf8)
    for key in arguments.keys.sorted() {
      append(key, to: &bytes)
      append(arguments[key]!, to: &bytes)
    }
    return "v1:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  /// 실행의 정체. 표시 문자열의 delimiter나 값 타입이 서로 충돌하지 않는다.
  public static func call(
    _ capability: CapabilityID, _ arguments: [String: ActionValue],
    binding: ConnectorBindingID? = nil
  ) -> String {
    var bytes = Data("action-call-v2".utf8)
    append(capability.rawValue, to: &bytes)
    bytes.append(binding == nil ? 0 : 1)
    if let binding {
      append(binding.provider.rawValue, to: &bytes)
      append(binding.principalID, to: &bytes)
      bytes.append(binding.workspaceID == nil ? 0 : 1)
      if let workspace = binding.workspaceID { append(workspace, to: &bytes) }
    }
    for key in arguments.keys.sorted() {
      append(key, to: &bytes)
      append(arguments[key]!, to: &bytes)
    }
    return capability.rawValue + "#v2:" + SHA256.hash(data: bytes)
      .map { String(format: "%02x", $0) }.joined()
  }

  /// 재실행의 payload/scope 검증. epoch·승인 만료는 실행 자격이지 효과의 정체가 아니다.
  public static func effect(accountID: String, callIdentity: String) -> String {
    var bytes = Data("action-effect-v2".utf8)
    append(accountID, to: &bytes)
    append(callIdentity, to: &bytes)
    return "v2:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  /// 새 실행은 v2로만 쓴다. 이전 키는 동일 트랜잭션의 조회·settlement 별칭이다.
  public static func ledgerKeys(for request: ActionRequest, callIdentity: String) -> (keys: [String], prefix: String?) {
    let prefix = request.turnID.uuidString + "#"
    let canonicalKey = prefix + callIdentity
    let family = prefix + request.capability.rawValue + "#"
    guard request.idempotencyKey.hasPrefix(family) else {
      return ([request.idempotencyKey], nil) // 자동화 등 명시적 논리 키는 바꾸지 않는다.
    }
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    func add(_ text: String) {
      for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x1000_0000_01b3 // 기존 파일에 쓴 상수를 그대로 보존한다.
      }
    }
    func addValue(_ value: ActionValue) {
      switch value {
      case .text(let text): add(text)
      case .number(let number): add(String(number))
      case .flag(let flag): add(flag ? "1" : "0")
      case .timestamp(let date): add(String(date.timeIntervalSince1970))
      case .list(let values):
        for (index, value) in values.enumerated() {
          if index > 0 { add(",") }
          addValue(value)
        }
      }
    }
    for (index, key) in request.arguments.keys.sorted().enumerated() {
      if index > 0 { add("\u{001F}") }
      add(key); add("="); addValue(request.arguments[key]!)
    }
    let key = prefix + request.capability.rawValue + "#" + String(hash, radix: 36)
    var legacy = [key]
    if let binding = request.binding {
      legacy.insert(key + "#" + arguments([
        "provider": .text(binding.provider.rawValue), "principal": .text(binding.principalID),
        "workspace": .text(binding.workspaceID ?? "")]), at: 0)
    }
    return ([canonicalKey] + legacy, family)
  }

  private static func append(_ text: String, to bytes: inout Data) {
    var length = UInt64(text.utf8.count).bigEndian
    withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
    bytes.append(contentsOf: text.utf8)
  }

  private static func append(_ value: ActionValue, to bytes: inout Data) {
    switch value {
    case .text(let text): bytes.append(0); append(text, to: &bytes)
    case .number(let number): bytes.append(1); append(String(number), to: &bytes)
    case .flag(let flag): bytes.append(2); bytes.append(flag ? 1 : 0)
    case .timestamp(let date):
      bytes.append(3); append(String(date.timeIntervalSince1970), to: &bytes)
    case .list(let values):
      bytes.append(4); append(String(values.count), to: &bytes)
      for value in values { append(value, to: &bytes) }
    }
  }
}

/// Propagates the concrete dispatcher request through existing UI adapters.
public enum ActionExecutionScope {
  @TaskLocal public static var current: ActionRequest?
}
