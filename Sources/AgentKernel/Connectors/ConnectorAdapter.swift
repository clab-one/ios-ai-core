import Foundation

/// 외부 서비스 하나. **공급자는 여기까지만 존재한다** — 능력 이름
/// (`mail.search`)에는 공급자가 없고, 어느 공급자로 갈지는 `CapabilityRouter`가
/// 정한다.
public enum ConnectorProvider: String, Sendable, Codable, CaseIterable {
  case google
  case slack

  public var label: String {
    switch self {
    case .google: "Google"
    case .slack: "Slack"
    }
  }
}

/// 공급자의 불변 principal/workspace identity. 표시 이름이나 토큰은 포함하지 않는다.
public struct ConnectorBindingID: Sendable, Hashable, Codable {
  public let provider: ConnectorProvider
  public let principalID: String
  public let workspaceID: String?

  public init(provider: ConnectorProvider, principalID: String, workspaceID: String? = nil) {
    self.provider = provider
    self.principalID = principalID
    self.workspaceID = workspaceID
  }

  /// 저장에 쓰는 **안정된 열쇠**. 표시 이름이 아니라 provider·principal·workspace로
  /// 만든다 — 사용자가 이메일 표시명을 바꿔도 같은 자리를 가리켜야 한다(§4.4).
  public var storageKey: String {
    "\(provider.rawValue)|\(principalID)|\(workspaceID ?? "")"
  }
}

/// Credential-free connection state captured once for a submitted turn.
public struct ConnectorReadinessSnapshot: Sendable, Equatable, Codable {
  public enum State: String, Sendable, Codable {
    case ready, refreshRequired, reauthenticationRequired
  }
  public let binding: ConnectorBindingID
  public let state: State
  public let capabilities: Set<CapabilityID>
  public let scopes: Set<String>
  public let capturedAt: Date
  /// 사람이 읽을 계정 이름. **화면에만 쓴다** — 실행은 `binding`을 쓴다.
  ///
  /// 이 자리가 없던 동안 승인 문의 계정 칸에 OAuth sub와 Slack user_id가 그대로
  /// 나갔다. 같은 공급자 계정이 둘이면 사람은 그 둘을 구별할 수 없다(§2.7).
  public let label: String
  /// workspace의 사람이 읽을 이름(팀 이름). 없으면 빈 값이다.
  public let workspaceLabel: String

  public init(binding: ConnectorBindingID, state: State, capabilities: Set<CapabilityID>,
    scopes: Set<String>, capturedAt: Date = Date(), label: String = "",
    workspaceLabel: String = "") {
    self.binding = binding
    self.state = state
    self.capabilities = capabilities
    self.scopes = scopes
    self.capturedAt = capturedAt
    self.label = label
    self.workspaceLabel = workspaceLabel
  }
}

public protocol ConnectorReadinessProviding: Sendable {
  func connectorReadiness(accountID: String, accountEpoch: UInt64) async -> [ConnectorReadinessSnapshot]
}

/// 연결된 계정 하나. **토큰은 담지 않는다** — 토큰은 Keychain에만 있고 이 값은
/// 화면과 라우터가 들고 다니는 이름표다.
public struct ConnectorAccount: Sendable, Hashable, Codable, Identifiable {
  public let provider: ConnectorProvider
  /// 공급자가 준 계정 식별자(메일 주소·팀 id). 로그에 남기지 않는다.
  public let id: String
  /// 사람이 읽을 이름. 화면에만 쓴다.
  public let label: String
  public let scopes: [String]
  public let connectedAt: Date
  /// 이전 저장값은 nil이다. provider 확인 없이 표시용 id에서 추론하지 않는다.
  public let binding: ConnectorBindingID?

  public init(
    provider: ConnectorProvider, id: String, label: String, scopes: [String],
    connectedAt: Date = Date(), binding: ConnectorBindingID? = nil
  ) {
    self.provider = provider
    self.id = id
    self.label = label
    self.scopes = scopes
    self.connectedAt = connectedAt
    self.binding = binding
  }
}

public enum ConnectorIdentity {
  /// provider의 불변 identity와 사람이 읽는 이름표를 따로 수집한다.
  public static func resolve(provider: ConnectorProvider, token: OAuthToken, session: URLSession = .shared) async throws
    -> ConnectorAccount
  {
    let endpoint = provider == .google
      ? "https://www.googleapis.com/oauth2/v3/userinfo" : "https://slack.com/api/auth.test"
    guard let url = URL(string: endpoint) else { throw ConnectorError.malformedResponse }
    var request = URLRequest(url: url)
    if provider == .slack { request.httpMethod = "POST" }
    request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
    else { throw ConnectorError.malformedResponse }
    switch provider {
    case .google:
      struct UserInfo: Decodable { let email: String; let sub: String }
      guard let info = try? JSONDecoder().decode(UserInfo.self, from: data),
        !info.email.isEmpty, !info.sub.isEmpty
      else { throw ConnectorError.malformedResponse }
      return ConnectorAccount(
        provider: provider, id: info.email, label: info.email, scopes: token.scopes,
        binding: ConnectorBindingID(provider: provider, principalID: info.sub))
    case .slack:
      struct AuthTest: Decodable {
        let ok: Bool
        let user_id: String
        let team_id: String
        let team: String?
      }
      guard let info = try? JSONDecoder().decode(AuthTest.self, from: data), info.ok,
        !info.user_id.isEmpty, !info.team_id.isEmpty
      else { throw ConnectorError.malformedResponse }
      return ConnectorAccount(
        provider: provider, id: "\(info.team_id):\(info.user_id)",
        label: info.team ?? provider.label, scopes: token.scopes,
        binding: ConnectorBindingID(
          provider: provider, principalID: info.user_id, workspaceID: info.team_id))
    }
  }
}

/// **바깥에서 온 글.** 메일 본문·Slack 메시지·웹 문서가 여기 담긴다.
///
/// 타입을 따로 둔 이유는 하나다: 외부 글이 모델의 **지시 평면**으로 들어가지
/// 못하게 컴파일러가 막아야 한다. `String`이면 실수 한 번으로 메일 본문이
/// instructions에 섞여 들어가고, 그 순간 남이 보낸 문장이 우리 앱의 명령이 된다.
public struct UntrustedText: Sendable, Hashable {
  /// 출처 한 줄(`gmail:message`). 문맥에 함께 실어 "이것은 데이터다"를 명시한다.
  public let origin: String
  private let raw: String

  public init(origin: String, _ raw: String) {
    self.origin = origin
    self.raw = raw
  }

  /// 화면에 그릴 때 쓴다.
  public var forDisplay: String { raw }

  /// 모델 문맥의 **데이터 구획**에 넣을 때만 쓴다. 경계 표시를 값 안에 넣어,
  /// 실수로 지시문에 이어 붙여도 구획이 남는다.
  public func forModelContext(limit: Int = 1_200) -> String {
    let clipped = raw.count > limit ? String(raw.prefix(limit)) + "…" : raw
    return "<<<data origin=\(origin)>>>\n\(clipped)\n<<<end>>>"
  }
}

/// 공급자 어댑터. 실제 HTTP는 각 구현이 진다.
public protocol ConnectorAdapter: Sendable {
  var provider: ConnectorProvider { get }
  var capabilities: Set<CapabilityID> { get }
  /// 토큰은 **호출 시점에** 주입된다. 어댑터는 토큰을 보관하지 않는다.
  func perform(
    _ request: ActionRequest, account: ConnectorAccount, accessToken: String
  ) async throws -> ActionReceipt
}

/// 대상의 **지금 revision**을 읽는 어댑터. 답장·수정·삭제 직전 재확인의 재료다.
///
/// 어댑터가 이것을 구현하지 않거나 공급자가 revision을 주지 않으면 `nil`이고,
/// 그때는 재확인 없이 지나간다 — revision 부재를 기능 차단 사유로 삼지 않는다(§4.4).
public protocol ConnectorTargetRevisionReading: Sendable {
  func currentTargetRevision(
    _ request: ActionRequest, account: ConnectorAccount, accessToken: String
  ) async throws -> String?
}

public enum ConnectorError: Error, Sendable, Hashable {
  /// 연결된 계정이 없다. 사용자가 연결해야 한다.
  case notConnected(ConnectorProvider)
  /// 토큰이 만료되고 갱신도 실패했다 — 다시 연결해야 한다.
  case reauthenticationRequired(ConnectorProvider)
  /// 공급자가 잠시 거절했다(429·5xx). 재시도 정책이 다룬다.
  case throttled(retryAfter: TimeInterval)
  /// 공급자가 거절했다. 본문은 담지 않는다 — 토큰·주소가 섞일 수 있다.
  case rejected(status: Int)
  case malformedResponse
  /// 전송의 결과를 모른다. **자동 재시도하지 않는다** — 두 번 보내는 것보다
  /// 한 번도 못 보낸 것이 낫다.
  case sendOutcomeUnknown
}
