import Foundation
import OSLog

/// 코어를 얹은 앱이 **자기 이름을 알려 주는 한 자리.**
///
/// 이 값이 없던 동안 코어는 자기를 얹은 앱이 JustSend라고 믿었다 — 로그 서브시스템,
/// Keychain 서비스, 사용자 기본값 접두사, OAuth 리다이렉트가 모두 한 앱의 번들
/// 식별자로 박혀 있었다. 다른 앱이 이 코어를 붙이면 그 앱의 토큰이 **남의 이름을 쓴
/// Keychain 항목**에 쌓이고, 두 앱을 한 기기에 깔면 서로의 토큰을 본다.
///
/// 파생값은 번들 식별자 하나에서 나온다. 각 자리를 따로 넘길 수 있지만, 넘기지
/// 않으면 한 번들에서 유도된 값끼리 갈라지지 않는다.
public struct AgentHostIdentity: Sendable {
  /// 앱의 번들 식별자. 파생값 전부의 뿌리다.
  public let bundleIdentifier: String
  /// `OSLog` 서브시스템. 콘솔에서 이 앱의 코어 로그를 거르는 이름이다.
  public let logSubsystem: String
  /// 커넥터 토큰이 놓이는 Keychain 서비스 이름.
  ///
  /// **이 값을 바꾸면 이미 저장된 토큰을 찾지 못한다.** 기존 설치가 있는 앱은
  /// 처음 쓰던 값을 명시로 넘겨야 한다.
  public let keychainService: String
  /// 사용자 기본값 열쇠의 접두사. 계정 이름표 목록이 이 아래에 놓인다.
  public let defaultsNamespace: String
  /// 근거 인용의 스킴(`<scheme>:receipt`). 화면과 로그가 근거의 출처를 가리키는 이름.
  public let citationScheme: String
  /// OAuth 리다이렉트 URI의 스킴. 번들에 `JS*OAuthRedirectURI`가 없을 때만 쓰인다.
  public let oauthRedirectScheme: String
  /// 이 앱의 서명에 Private Cloud Compute 권한이 있는가.
  ///
  /// **코어가 알 수 없는 값이다.** iOS에는 자기 엔타이틀먼트를 읽는 공개 API가 없고
  /// (`SecTaskCopyValueForEntitlement`는 macOS 전용), 권한 없이 PCC 세션을 만들면
  /// 프레임워크가 예외가 아니라 `fatalError`로 프로세스를 끝낸다. 그래서 앱이
  /// 자기 서명을 보고 말해 주어야 한다 — 기본값은 **부르지 않는 쪽**이다.
  public let isPrivateCloudComputeEntitled: Bool

  /// 번들 식별자 하나로 전부 유도한다. 개별 자리는 필요할 때만 덮어쓴다.
  ///
  /// - Parameters:
  ///   - bundleIdentifier: 앱 번들 식별자(예: `com.example.app`).
  ///   - privateCloudComputeEntitled: 서명에 PCC 권한이 있는가.
  public init(
    bundleIdentifier: String,
    privateCloudComputeEntitled: Bool = false,
    logSubsystem: String? = nil,
    keychainService: String? = nil,
    defaultsNamespace: String? = nil,
    citationScheme: String? = nil,
    oauthRedirectScheme: String? = nil
  ) {
    let shortName =
      bundleIdentifier.split(separator: ".").last.map(String.init) ?? bundleIdentifier
    self.bundleIdentifier = bundleIdentifier
    self.logSubsystem = logSubsystem ?? bundleIdentifier
    self.keychainService = keychainService ?? "\(bundleIdentifier).connector"
    self.defaultsNamespace = defaultsNamespace ?? shortName
    self.citationScheme = citationScheme ?? shortName
    self.oauthRedirectScheme = oauthRedirectScheme ?? bundleIdentifier
    self.isPrivateCloudComputeEntitled = privateCloudComputeEntitled
  }

  /// 설정하지 않은 호스트의 값. 실행 중인 번들에서 읽는다.
  ///
  /// 코어가 **틀린 이름으로 조용히 도는 것보다** 번들이 말하는 이름으로 도는 것이
  /// 낫다. 다만 이미 출하된 앱은 처음 쓰던 이름을 명시로 넘겨야 한다 — 유도된
  /// 이름과 다르면 저장된 토큰을 찾지 못한다.
  public static func fromRunningBundle() -> AgentHostIdentity {
    AgentHostIdentity(
      bundleIdentifier: Bundle.main.bundleIdentifier ?? "ios-ai-core")
  }
}

/// 코어가 자기 호스트를 묻는 자리.
///
/// 앱은 **첫 코어 호출 전에** 한 번 `configure`를 부른다. 부르지 않으면 실행 중인
/// 번들에서 유도한 값으로 돈다.
public enum AgentHost {
  private static let lock = NSLock()
  private nonisolated(unsafe) static var configured: AgentHostIdentity?
  private nonisolated(unsafe) static var loggers: [String: Logger] = [:]

  /// 호스트 신원을 알려 준다. 앱 기동에서 한 번 부른다.
  ///
  /// 뒤늦게 다시 부르면 이미 만들어진 `Logger`는 앞선 서브시스템을 들고 있다 —
  /// 로그가 갈라질 뿐 동작은 바뀌지 않는다. 열쇠·스킴은 호출 시점마다 읽으므로
  /// 즉시 반영된다.
  public static func configure(_ identity: AgentHostIdentity) {
    lock.lock()
    configured = identity
    loggers.removeAll()
    lock.unlock()
  }

  /// 지금 신원. 설정되지 않았으면 실행 중인 번들에서 유도한다.
  public static var identity: AgentHostIdentity {
    lock.lock()
    defer { lock.unlock() }
    if let configured { return configured }
    let derived = AgentHostIdentity.fromRunningBundle()
    configured = derived
    return derived
  }

  /// 범주별 로거. 서브시스템은 호스트 신원에서 온다.
  ///
  /// 범주마다 한 번만 만든다 — `Logger`는 값이지만 만들 때 `os_log_create`가 돌고,
  /// 커넥터 HTTP처럼 요청마다 적는 자리가 그 비용을 반복해 낼 이유가 없다.
  public static func logger(_ category: String) -> Logger {
    lock.lock()
    if let cached = loggers[category] {
      lock.unlock()
      return cached
    }
    let subsystem = (configured ?? AgentHostIdentity.fromRunningBundle()).logSubsystem
    if configured == nil { configured = AgentHostIdentity.fromRunningBundle() }
    let logger = Logger(subsystem: subsystem, category: category)
    loggers[category] = logger
    lock.unlock()
    return logger
  }
}
