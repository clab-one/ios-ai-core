import Foundation
import OSLog

/// OAuth 앱 설정. **비밀은 코드에 없다** — 클라이언트 id와 리다이렉트는 번들의
/// 설정값이고, 클라이언트 시크릿은 쓰지 않는다(PKCE 공용 클라이언트).
public struct OAuthClientConfiguration: Sendable {
  public let clientID: String
  public let redirectURI: String
  public let authorizationEndpoint: URL
  public let tokenEndpoint: URL
  public let scopes: [String]

  public init(
    clientID: String, redirectURI: String, authorizationEndpoint: URL, tokenEndpoint: URL,
    scopes: [String]
  ) {
    self.clientID = clientID
    self.redirectURI = redirectURI
    self.authorizationEndpoint = authorizationEndpoint
    self.tokenEndpoint = tokenEndpoint
    self.scopes = scopes
  }

  /// 번들에서 읽는다. 값이 없으면 그 공급자는 **연결할 수 없는 상태**로 남고,
  /// 화면은 그것을 "연결 안 됨"으로 그린다 — 조용히 실패하지 않는다.
  public static func google(bundle: Bundle = .main) -> OAuthClientConfiguration? {
    guard let clientID = bundle.object(forInfoDictionaryKey: "JSGoogleOAuthClientID")
      as? String, !clientID.isEmpty
    else { return nil }
    let redirect =
      bundle.object(forInfoDictionaryKey: "JSGoogleOAuthRedirectURI") as? String
      ?? "\(AgentHost.identity.oauthRedirectScheme):/oauth2redirect/google"
    return OAuthClientConfiguration(
      clientID: clientID,
      redirectURI: redirect,
      authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
      tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
      scopes: [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/userinfo.email",
      ])
  }

  public static func slack(bundle: Bundle = .main) -> OAuthClientConfiguration? {
    guard let clientID = bundle.object(forInfoDictionaryKey: "JSSlackOAuthClientID")
      as? String, !clientID.isEmpty
    else { return nil }
    let redirect =
      bundle.object(forInfoDictionaryKey: "JSSlackOAuthRedirectURI") as? String
      ?? "\(AgentHost.identity.oauthRedirectScheme):/oauth2redirect/slack"
    return OAuthClientConfiguration(
      clientID: clientID,
      redirectURI: redirect,
      authorizationEndpoint: URL(string: "https://slack.com/oauth/v2/authorize")!,
      tokenEndpoint: URL(string: "https://slack.com/api/oauth.v2.access")!,
      // 제품이 "내 Slack 메시지"라고 말하면 공개 채널만으로는 거짓이 된다(§9).
      // 비공개 채널·DM·그룹 DM의 읽기 범위를 함께 요청하고, 채널 이름을 읽을
      // `*:read`와 사람 이름을 읽을 `users:read`까지 받는다.
      scopes: [
        "search:read",
        "channels:history", "groups:history", "im:history", "mpim:history",
        "channels:read", "groups:read", "im:read", "mpim:read",
        "users:read", "chat:write",
      ])
  }

  public static func configuration(
    for provider: ConnectorProvider, bundle: Bundle = .main
  ) -> OAuthClientConfiguration? {
    switch provider {
    case .google: google(bundle: bundle)
    case .slack: slack(bundle: bundle)
    }
  }
}

/// 토큰 갱신. refresh grant 하나만 안다 — 인증 첫 단계(브라우저)는 화면이 진다.
public struct OAuthRefresher: Sendable {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  /// 공급자의 갱신 응답. **모양이 둘이다.**
  ///
  /// 표준 OAuth2는 `access_token`을 최상위에 둔다. Slack은 HTTP 200에 `ok: false`를
  /// 담아 실패를 말하고, 토큰 회전(token rotation)을 켠 앱의 사용자 토큰은
  /// `authed_user` 봉투 안에 온다 — `ok`를 보지 않으면 실패가 성공으로 읽힌다.
  private struct RefreshResponse: Decodable {
    struct AuthedUser: Decodable {
      let access_token: String?
      let refresh_token: String?
      let expires_in: Double?
      let scope: String?
    }
    let ok: Bool?
    let error: String?
    let access_token: String?
    let expires_in: Double?
    let refresh_token: String?
    let scope: String?
    let authed_user: AuthedUser?
  }

  public func refresh(
    _ token: OAuthToken, provider: ConnectorProvider,
    configuration: OAuthClientConfiguration
  ) async throws -> OAuthToken {
    guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
      throw ConnectorError.reauthenticationRequired(provider)
    }
    var request = URLRequest(url: configuration.tokenEndpoint)
    request.httpMethod = "POST"
    request.setValue(
      "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var form = URLComponents()
    form.queryItems = [
      URLQueryItem(name: "client_id", value: configuration.clientID),
      URLQueryItem(name: "grant_type", value: "refresh_token"),
      URLQueryItem(name: "refresh_token", value: refreshToken),
    ]
    request.httpBody = form.percentEncodedQuery.map { Data($0.utf8) }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      let decoded = try? JSONDecoder().decode(RefreshResponse.self, from: data),
      decoded.ok != false
    else {
      throw ConnectorError.reauthenticationRequired(provider)
    }
    // 사용자 토큰이 봉투 안에 왔으면 그것이 우리 토큰이다. 최상위 값은 봇 토큰일
    // 수 있고, 봇 토큰으로 `search.messages`를 부르면 거절된다.
    let access = decoded.authed_user?.access_token ?? decoded.access_token
    guard let access, !access.isEmpty else {
      throw ConnectorError.reauthenticationRequired(provider)
    }
    let renewed = decoded.authed_user?.refresh_token ?? decoded.refresh_token
    let lifetime = decoded.authed_user?.expires_in ?? decoded.expires_in
    let scope = decoded.authed_user?.scope ?? decoded.scope
    return OAuthToken(
      accessToken: access,
      // 공급자가 새 refresh 토큰을 주지 않으면 **기존 것을 유지한다** — 버리면
      // 다음 갱신에서 사용자가 다시 로그인해야 한다.
      refreshToken: renewed ?? refreshToken,
      // 만료를 말하지 않은 토큰에 만료를 **지어내지 않는다.** 회전을 켜지 않은
      // Slack 사용자 토큰은 만료가 없다.
      expiresAt: lifetime.map { Date().addingTimeInterval($0) },
      scopes: Self.scopes(scope, provider: provider) ?? token.scopes)
  }

  /// 범위 목록의 구분자가 공급자마다 다르다 — Google은 공백, Slack은 쉼표다.
  private static func scopes(_ raw: String?, provider: ConnectorProvider) -> [String]? {
    guard let raw, !raw.isEmpty else { return nil }
    let separator: Character = provider == .slack ? "," : " "
    return raw.split(separator: separator).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
  }
}

/// 공급자 중립 능력을 실제 계정으로 내려보내는 자리.
///
/// `mail.search`가 어느 어댑터로 갈지, 어느 계정의 토큰을 쓸지를 **코드가** 정한다.
/// 모델은 계정을 고르지 않는다 — 고르게 하면 계정 이름이 문맥에 들어가야 하고,
/// 그 순간 계정 목록이 모델 입력이 된다.
public struct ConnectorRouter: CapabilityHandler, ConnectorReadinessProviding,
  TargetRevisionVerifying
{
  private static let log = AgentHost.logger("connector-router")

  private let adapters: [any ConnectorAdapter]
  private let store: OAuthAccountStore
  private let refresher: OAuthRefresher
  private let bundle: Bundle
  private let identitySession: URLSession

  public init(
    adapters: [any ConnectorAdapter],
    store: OAuthAccountStore,
    refresher: OAuthRefresher = OAuthRefresher(),
    bundle: Bundle = .main,
    identitySession: URLSession = .shared
  ) {
    self.identitySession = identitySession
    self.adapters = adapters
    self.store = store
    self.refresher = refresher
    self.bundle = bundle
  }

  public var capabilities: Set<CapabilityID> {
    adapters.reduce(into: Set<CapabilityID>()) { $0.formUnion($1.capabilities) }
  }

  public func perform(_ request: ActionRequest) async throws -> ActionReceipt {
    let candidates = adapters.filter { $0.capabilities.contains(request.capability) }
    guard !candidates.isEmpty else { throw ActionError.unsupported(request.capability) }

    try await validate(request)
    let preferred = request.binding?.provider ?? request.arguments["provider"]?.textValue.flatMap(
      ConnectorProvider.init(rawValue:))
    var matches: [(any ConnectorAdapter, ConnectorAccount)] = []
    for adapter in candidates where preferred == nil || adapter.provider == preferred {
      for account in await store.accounts(for: adapter.provider)
      where request.binding == nil || account.binding == request.binding {
        matches.append((adapter, account))
      }
    }
    guard matches.count <= 1 else { throw ActionError.ambiguous(reason: "connectorBinding") }
    for (adapter, storedAccount) in matches {
      let token = try await validToken(for: storedAccount, request: request)
      var account = storedAccount
      if account.binding == nil {
        let resolved = try await ConnectorIdentity.resolve(
          provider: account.provider, token: token, session: identitySession)
        try await validate(request, account: account)
        account = try await store.resolveIdentity(
          for: account, resolved: resolved, expectedAccountScope: request.accountID)
      }
      try await validate(request, account: account)
      do {
        let receipt = try await adapter.perform(
          request, account: account, accessToken: token.accessToken)
        if request.capability.executionClass == .readOnly { try await validate(request, account: account) }
        Self.logCall(adapter.provider, request.capability, outcome: "ok")
        return receipt
      } catch ConnectorError.rejected(let status) where status == 401 {
        // 한 번은 갱신하고 다시 시도한다. 갱신에도 401이면 재인증이 필요하다.
        let renewed = try await forceRefresh(account: account, request: request)
        try await validate(request, account: account)
        do {
          let receipt = try await adapter.perform(
            request, account: account, accessToken: renewed.accessToken)
          if request.capability.executionClass == .readOnly { try await validate(request, account: account) }
          Self.logCall(adapter.provider, request.capability, outcome: "ok.refreshed")
          return receipt
        } catch let error as ConnectorError {
          // **재시도의 실패도 번역한다.** 이 자리가 번역되지 않아서, 갱신 뒤에도
          // 401이면 호출부가 `ConnectorError`를 그대로 받았다 — 승인 계층은
          // `ActionError`만 읽으므로 그 실패는 "재인증 필요"로 읽히지 않았다.
          Self.logCall(
            adapter.provider, request.capability, outcome: "failed.afterRefresh")
          throw Self.translate(error, capability: request.capability)
        }
      } catch let error as ConnectorError {
        Self.logCall(adapter.provider, request.capability, outcome: "failed")
        throw Self.translate(error, capability: request.capability)
      }
    }
    throw ActionError.notAuthorized(request.capability)
  }

  public func connectorReadiness(accountID: String, accountEpoch: UInt64) async -> [ConnectorReadinessSnapshot] {
    let scope = await store.currentAccountScope()
    guard scope == accountID, accountEpoch == AssistantAccountEpoch.current else { return [] }
    var result: [ConnectorReadinessSnapshot] = []
    for adapter in adapters {
      for storedAccount in await store.accounts(for: adapter.provider) {
        let token = await store.token(for: storedAccount, expectedAccountScope: accountID)
        var account = storedAccount
        if account.binding == nil, let token,
          let resolved = try? await ConnectorIdentity.resolve(
            provider: account.provider, token: token, session: identitySession),
          accountEpoch == AssistantAccountEpoch.current,
          let migrated = try? await store.resolveIdentity(
            for: account, resolved: resolved, expectedAccountScope: accountID) {
          account = migrated
        }
        guard let binding = account.binding else { continue }
        let state: ConnectorReadinessSnapshot.State
        if let token {
          state = token.isExpired
            ? (token.refreshToken == nil ? .reauthenticationRequired : .refreshRequired) : .ready
        } else { state = .reauthenticationRequired }
        result.append(ConnectorReadinessSnapshot(
          binding: binding, state: state, capabilities: adapter.capabilities,
          scopes: Set(token?.scopes ?? account.scopes),
          // 이름표는 저장된 계정이 이미 들고 있다. 승인 문이 이 값을 쓰고, 실행은
          // 계속 `binding`을 쓴다. workspace의 **별도 이름**은 저장하지 않으므로
          // 비워 둔다 — 같은 이름을 두 칸에 적으면 화면이 그것을 두 값으로 읽는다.
          label: account.label))
      }
    }
    guard !Task.isCancelled, accountEpoch == AssistantAccountEpoch.current else { return [] }
    return result.sorted {
      ($0.binding.provider.rawValue, $0.binding.principalID, $0.binding.workspaceID ?? "")
        < ($1.binding.provider.rawValue, $1.binding.principalID, $1.binding.workspaceID ?? "")
    }
  }

  /// 연결된 공급자 목록 — 화면(연결)과 도구 프로필이 함께 읽는다.
  public func connectedProviders() async -> Set<ConnectorProvider> {
    var providers: Set<ConnectorProvider> = []
    for adapter in adapters where !(await store.accounts(for: adapter.provider)).isEmpty {
      providers.insert(adapter.provider)
    }
    return providers
  }

  /// 대상의 지금 revision. 이 능력을 맡은 어댑터가 읽을 수 있을 때만 값이 있다.
  ///
  /// **읽지 못하는 것과 바뀐 것은 다르다.** 읽을 수 없으면 nil을 돌려 재확인을
  /// 건너뛰고, 공급자가 거절하면 그 오류가 그대로 올라가 실행이 멈춘다(§PR5).
  public func currentTargetRevision(for request: ActionRequest) async throws -> String? {
    for adapter in adapters where adapter.capabilities.contains(request.capability) {
      guard let reader = adapter as? any ConnectorTargetRevisionReading else { continue }
      if let preferred = request.binding?.provider, preferred != adapter.provider { continue }
      for account in await store.accounts(for: adapter.provider)
      where request.binding == nil || account.binding == request.binding {
        let token = try await validToken(for: account, request: request)
        return try await reader.currentTargetRevision(
          request, account: account, accessToken: token.accessToken)
      }
    }
    return nil
  }

  private func validate(_ request: ActionRequest, account: ConnectorAccount? = nil) async throws {
    let scope = await store.currentAccountScope()
    if let account, !(await store.accounts()).contains(account) {
      throw ActionError.notAuthorized(request.capability)
    }
    guard !Task.isCancelled else { throw ActionError.cancelled }
    guard request.accountEpoch == AssistantAccountEpoch.current, request.accountID == scope
    else { throw ActionError.accountChanged }
  }

  private func validToken(for account: ConnectorAccount, request: ActionRequest) async throws -> OAuthToken {
    try await validate(request, account: account)
    guard let token = await store.token(for: account, expectedAccountScope: request.accountID) else {
      throw ActionError.notAuthorized(request.capability)
    }
    guard token.isExpired else { return token }
    return try await forceRefresh(account: account, request: request, existing: token)
  }

  private func forceRefresh(
    account: ConnectorAccount, request: ActionRequest, existing: OAuthToken? = nil
  ) async throws -> OAuthToken {
    guard let configuration = OAuthClientConfiguration.configuration(
      for: account.provider, bundle: bundle)
    else {
      throw ActionError.notAuthorized(request.capability)
    }
    let stored: OAuthToken?
    if let existing {
      stored = existing
    } else {
      stored = await store.token(for: account, expectedAccountScope: request.accountID)
    }
    guard let token = stored else {
      throw ActionError.notAuthorized(request.capability)
    }
    do {
      let renewed = try await refresher.refresh(
        token, provider: account.provider, configuration: configuration)
      try await validate(request, account: account)
      try await store.store(token: renewed, for: account, expectedAccountScope: request.accountID)
      return renewed
    } catch let error as ActionError {
      throw error
    } catch {
      Self.log.info(
        "connector reauth required provider=\(account.provider.rawValue, privacy: .public)")
      throw ActionError.notAuthorized(request.capability)
    }
  }

  private static func translate(
    _ error: ConnectorError, capability: CapabilityID
  ) -> ActionError {
    switch error {
    case .notConnected, .reauthenticationRequired:
      return .notAuthorized(capability)
    case .throttled:
      return .failed(reason: "throttled")
    case .rejected(let status):
      return .failed(reason: "provider:\(status)")
    case .malformedResponse:
      return .failed(reason: "malformed")
    case .sendOutcomeUnknown:
      // 사용자에게 "보냈다"고 말하지 않는다. 확인되지 않은 전송은 실패로 둔다.
      return .failed(reason: "sendOutcomeUnknown")
    }
  }

  /// 호출 하나의 결과 한 줄. **실기 검수의 유일한 관찰 창**이다 — 어댑터에는
  /// 로그가 없어서 운영자는 검색이 돌았는지, 401 뒤 갱신이 통했는지 알 수 없었다.
  ///
  /// 싣는 것은 공급자·능력·결과뿐이다. 질의·본문·주소·토큰은 싣지 않는다.
  private static func logCall(
    _ provider: ConnectorProvider, _ capability: CapabilityID, outcome: String
  ) {
    log.info(
      """
      connector call provider=\(provider.rawValue, privacy: .public) \
      capability=\(capability.rawValue, privacy: .public) \
      outcome=\(outcome, privacy: .public)
      """)
  }
}
