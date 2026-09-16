import Foundation
import OSLog
import Security

/// 토큰 한 벌. **이 값은 Keychain 밖으로 나가면 메모리에만 있다** — 파일·로그·
/// 사용자 기본값에 적지 않는다.
public struct OAuthToken: Sendable, Codable, Hashable {
  public let accessToken: String
  public let refreshToken: String?
  public let expiresAt: Date?
  public let scopes: [String]

  public init(
    accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil,
    scopes: [String] = []
  ) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
    self.scopes = scopes
  }

  /// 만료 30초 전부터 만료로 본다 — 경계에서 보낸 요청이 401로 죽는 것을 막는다.
  public var isExpired: Bool {
    guard let expiresAt else { return false }
    return expiresAt.timeIntervalSinceNow < 30
  }
}

/// 토큰이 실제로 놓이는 **한 자리**.
///
/// 이 겹옷이 있는 이유는 하나다: **삭제 실패를 주입할 수 있어야** 연결 해제의 계약을
/// 시험할 수 있다. `SecItemDelete`의 실패는 기기가 잠겨 있거나 접근 그룹이 바뀔 때
/// 실제로 일어나고, 그 실패를 성공으로 접으면 화면은 "연결 해제됨"을 보여 주는데
/// 토큰은 Keychain에 남는다 — 그 토큰 하나로 그 계정의 메일을 읽을 수 있다.
///
/// 계정 이름표(`account`)만 받는다. 서비스 이름과 접근성은 구현이 소유한다.
public protocol OAuthTokenVault: Sendable {
  func write(_ data: Data, account: String) throws
  func read(account: String) -> Data?
  /// 지웠는가. **없어서 지우지 못한 것은 지운 것으로 본다.**
  func delete(account: String) -> Bool
}

/// 기기의 Keychain. 잠금 해제 뒤에만 읽히고 백업으로 다른 기기에 따라가지 않는다.
public struct KeychainOAuthTokenVault: OAuthTokenVault {
  /// 실패에 담는 것은 `OSStatus` 하나다 — 토큰도, 계정 식별자도 담지 않는다.
  public enum Failure: Error, Equatable, Sendable {
    case writeRejected(OSStatus)
  }

  private let service: String

  public init(service: String = "dev.hyunminkim.justsend.connector") {
    self.service = service
  }

  private func query(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  public func write(_ data: Data, account: String) throws {
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      // 기기 잠금 해제 뒤에만 읽힌다. 백업으로 다른 기기에 따라가지 않는다.
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(
      query(account: account) as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var insert = query(account: account)
      insert.merge(attributes) { current, _ in current }
      let addStatus = SecItemAdd(insert as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw Failure.writeRejected(addStatus) }
      return
    }
    guard status == errSecSuccess else { throw Failure.writeRejected(status) }
  }

  public func read(account: String) -> Data? {
    var request = query(account: account)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else { return nil }
    return data
  }

  public func delete(account: String) -> Bool {
    let status = SecItemDelete(query(account: account) as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
  }
}

public enum OAuthAccountStoreError: Error, Equatable, Sendable {
  /// 토큰을 기기에서 지우지 못했다 — **연결 해제는 일어나지 않았다.**
  ///
  /// 이 오류를 받은 화면은 계정을 연결된 상태로 그대로 두고 실패를 말해야 한다.
  /// 이름표만 지우면 사용자는 해제됐다고 믿고, 남은 토큰은 아무도 찾지 못한다.
  case tokenNotDeleted(ConnectorProvider)
}

/// 연결 계정과 토큰의 보관소.
///
/// **계정 범위가 열쇠에 들어간다.** JustSend 계정을 바꿨을 때 이전 사용자의
/// Gmail 토큰이 보이면 그것은 유출이다 — 열쇠에 범위를 넣으면 조회 자체가
/// 다른 계정의 토큰에 닿지 못한다.
public actor OAuthAccountStore {
  private static let log = Logger(
    subsystem: "dev.hyunminkim.justsend", category: "connector-auth")

  /// 계정 이름표는 Keychain이 아니라 앱 기본값에 둔다 — 비밀이 아니고, 화면이
  /// 목록을 그릴 때 Keychain을 두드리지 않아야 한다.
  private let defaults: UserDefaults
  private let accountScope: @Sendable () -> String
  /// 토큰이 놓이는 자리. 기본값은 기기의 Keychain이고, 시험은 실패를 주입한다.
  private let vault: any OAuthTokenVault

  public init(
    defaults: UserDefaults = .standard,
    vault: any OAuthTokenVault = KeychainOAuthTokenVault(),
    accountScope: @escaping @Sendable () -> String
  ) {
    self.defaults = defaults
    self.vault = vault
    self.accountScope = accountScope
  }

  private func directoryKey() -> String {
    "justsend.connectors.\(accountScope())"
  }

  public func currentAccountScope() -> String { accountScope() }

  public func accounts() -> [ConnectorAccount] {
    directory().accounts
  }

  /// 이름표 목록과 **읽을 수 있었는가.**
  ///
  /// 읽지 못한 것은 "연결된 계정이 없다"와 같지 않다. 그 둘을 같은 값으로 접으면
  /// 손상된 목록 하나가 두 가지를 동시에 만든다: 화면에서 연결이 사라지고,
  /// 계정 경계 정리가 **지울 것이 없다고 판단해 토큰을 기기에 남긴다.**
  /// 그렇게 남은 토큰은 이름표가 없으므로 이후 어떤 정리도 찾지 못한다.
  private func directory() -> (accounts: [ConnectorAccount], readable: Bool) {
    guard let data = defaults.data(forKey: directoryKey()) else { return ([], true) }
    do {
      return (try JSONDecoder().decode([ConnectorAccount].self, from: data), true)
    } catch {
      Self.log.error("connector directory unreadable scope=\(self.accountScope().isEmpty ? "none" : "set", privacy: .public)")
      return ([], false)
    }
  }

  public func accounts(for provider: ConnectorProvider) -> [ConnectorAccount] {
    accounts().filter { $0.provider == provider }
  }

  /// 계정 연결. 이름표를 적고 토큰을 Keychain에 넣는다.
  @discardableResult
  public func connect(
    _ account: ConnectorAccount, token: OAuthToken, expectedAccountScope: String? = nil
  ) throws -> ConnectorAccount {
    if let expectedAccountScope, expectedAccountScope != accountScope() {
      throw ActionError.accountChanged
    }
    let existing = accounts()
    let prior = existing.first {
      $0.provider == account.provider
        && ($0.id == account.id || (account.binding != nil && $0.binding == account.binding))
    }
    let saved = ConnectorAccount(
      provider: account.provider, id: prior?.id ?? account.id, label: account.label,
      scopes: account.scopes, connectedAt: account.connectedAt, binding: account.binding)
    try write(token: token, for: saved)
    var current = existing.filter {
      !($0.provider == saved.provider && $0.id == saved.id)
    }
    current.append(saved)
    persist(current)
    Self.log.info(
      "connector connected provider=\(account.provider.rawValue, privacy: .public)")
    return saved
  }

  /// 연결 해제. **토큰을 지우지 못하면 이름표도 지우지 않는다.**
  ///
  /// 예전에는 `delete(for:)`의 답을 버리고 이름표를 지웠다. 그러면 Keychain 삭제가
  /// 실패한 판에서 화면은 "연결 해제됨"을 보여 주는데 토큰은 기기에 남고, 이름표가
  /// 사라졌으므로 **이후 어떤 정리도 그 토큰을 찾지 못한다**(계정 경계 정리도
  /// 이름표 목록을 보고 지운다 — `clearAll`). 그래서 이 자리는 사용자 계약처럼
  /// 원자적으로 움직인다: 토큰이 지워졌을 때만 연결이 해제된 것이다.
  public func disconnect(_ account: ConnectorAccount) throws {
    guard vault.delete(account: keychainAccount(for: account)) else {
      Self.log.error(
        "connector disconnect failed provider=\(account.provider.rawValue, privacy: .public)"
      )
      throw OAuthAccountStoreError.tokenNotDeleted(account.provider)
    }
    persist(
      accounts().filter { !($0.provider == account.provider && $0.id == account.id) })
    Self.log.info(
      "connector disconnected provider=\(account.provider.rawValue, privacy: .public)")
  }

  /// 계정 전환 시 호출. **토큰은 남기고 이름표만 범위 밖으로 둔다**고 하면 다음
  /// 사용자가 조회할 수 없지만 기기에는 남는다 — 그래서 지운다.
  ///
  /// 돌려주는 값은 **정말 지웠는가**다. Keychain 삭제는 실패할 수 있고(기기 잠금
  /// 상태·접근 그룹 변경), 그 실패를 삼키면 로그아웃한 기기에 앞사람의 Gmail·Slack
  /// 토큰이 남는다 — 그 토큰 하나로 앞사람의 메일을 읽을 수 있다.
  @discardableResult
  public func clearAll() -> Bool {
    let listed = directory()
    // **읽지 못한 목록을 "비었다"로 접지 않는다.** 그렇게 접으면 열쇠를 지우고
    // 깨끗하다고 답하는데, 이름표 없는 토큰은 그 뒤로 아무도 찾지 못한다. 대신
    // 실패를 답으로 돌려주면 연기된 정리가 다시 시도한다(`AccountBoundaryPurge`).
    guard listed.readable else {
      Self.log.error("connector tokens not cleared reason=directoryUnreadable")
      return false
    }
    let remaining = listed.accounts.filter { !delete(for: $0) }
    guard remaining.isEmpty else {
      // 지우지 못한 토큰의 **이름표는 남긴다** — 다시 시도할 때 무엇을 지워야
      // 하는지 아는 유일한 자리다. 이름표에는 계정 범위가 붙어 있어 다음
      // 사용자에게는 보이지 않는다.
      persist(remaining)
      Self.log.error(
        "connector tokens not cleared count=\(remaining.count, privacy: .public)")
      return false
    }
    defaults.removeObject(forKey: directoryKey())
    return true
  }

  public func resolveIdentity(
    for account: ConnectorAccount, resolved: ConnectorAccount, expectedAccountScope: String
  ) throws -> ConnectorAccount {
    guard accountScope() == expectedAccountScope else { throw ActionError.accountChanged }
    var current = accounts()
    guard let index = current.firstIndex(of: account), let binding = resolved.binding,
      binding.provider == account.provider
    else { throw ConnectorError.notConnected(account.provider) }
    let updated = ConnectorAccount(
      provider: account.provider, id: account.id, label: resolved.label,
      scopes: account.scopes, connectedAt: account.connectedAt, binding: binding)
    current[index] = updated
    persist(current)
    return updated
  }

  public func token(
    for account: ConnectorAccount, expectedAccountScope: String? = nil
  ) -> OAuthToken? {
    guard expectedAccountScope == nil || expectedAccountScope == accountScope(),
      accounts().contains(account)
    else { return nil }
    return read(for: account)
  }

  public func store(
    token: OAuthToken, for account: ConnectorAccount, expectedAccountScope: String? = nil
  ) throws {
    guard expectedAccountScope == nil || expectedAccountScope == accountScope() else {
      throw ActionError.accountChanged
    }
    guard accounts().contains(account) else {
      throw ConnectorError.notConnected(account.provider)
    }
    try write(token: token, for: account)
  }

  private func persist(_ accounts: [ConnectorAccount]) {
    guard let data = try? JSONEncoder().encode(accounts) else { return }
    defaults.set(data, forKey: directoryKey())
  }

  // MARK: Keychain

  private func keychainAccount(for account: ConnectorAccount) -> String {
    "\(accountScope())|\(account.provider.rawValue)|\(account.id)"
  }

  private func write(token: OAuthToken, for account: ConnectorAccount) throws {
    do {
      try vault.write(
        try JSONEncoder().encode(token), account: keychainAccount(for: account))
    } catch {
      // 저장하지 못한 토큰은 없는 토큰이다 — 다시 인증해야 한다. 원문 오류는
      // 로그에도 싣지 않는다(`OSStatus`만 담긴 값이지만 경계를 좁게 둔다).
      Self.log.error(
        "connector token write failed provider=\(account.provider.rawValue, privacy: .public)"
      )
      throw ConnectorError.reauthenticationRequired(account.provider)
    }
  }

  private func read(for account: ConnectorAccount) -> OAuthToken? {
    guard let data = vault.read(account: keychainAccount(for: account)) else {
      return nil
    }
    return try? JSONDecoder().decode(OAuthToken.self, from: data)
  }

  /// 지웠는가. 없어서 지우지 못한 것은 지운 것으로 본다.
  private func delete(for account: ConnectorAccount) -> Bool {
    let deleted = vault.delete(account: keychainAccount(for: account))
    if !deleted {
      Self.log.error(
        "connector token delete failed provider=\(account.provider.rawValue, privacy: .public)"
      )
    }
    return deleted
  }
}
