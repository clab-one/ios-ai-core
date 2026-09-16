import Foundation

/// Slack 어댑터. `chat.*` 능력의 한 공급자다.
///
/// 검색은 후보만 반환한다. 선택한 스레드의 본문은 chat.read가 읽는다.
public struct SlackAdapter: ConnectorAdapter {
  public let provider: ConnectorProvider = .slack
  public var capabilities: Set<CapabilityID> {
    [.chatSearch, .chatRead, .chatSend, .chatReply]
  }

  private let http: ConnectorHTTP
  private static let base = "https://slack.com/api"
  /// 검색에서 문맥으로 가져갈 최대 건수.
  private static let maxMatches = 20

  public init(http: ConnectorHTTP = ConnectorHTTP()) {
    self.http = http
  }

  public func perform(
    _ request: ActionRequest, account: ConnectorAccount, accessToken: String
  ) async throws -> ActionReceipt {
    switch request.capability {
    case .chatSearch:
      return try await search(request, account: account, token: accessToken)
    case .chatRead:
      return try await read(request, account: account, token: accessToken)
    case .chatSend, .chatReply:
      return try await post(request, token: accessToken)
    default:
      throw ActionError.unsupported(request.capability)
    }
  }

  // MARK: 응답 모양
  //
  // Slack은 HTTP 200에 `ok: false`를 담아 실패를 말한다. 상태 코드만 보면 모든
  // 실패가 성공으로 읽힌다 — 그래서 `ok`를 먼저 본다.

  private struct SearchResponse: Decodable {
    struct Messages: Decodable {
      struct Match: Decodable {
        let text: String?
        let username: String?
        let user: String?
        let ts: String?
        let permalink: String?
        let channel: Channel?
        struct Channel: Decodable {
          let id: String?
          let name: String?
          /// DM·비공개 채널 여부. 제품이 "내 Slack 메시지"라고 말하면 이것들도
          /// 결과에 있어야 한다(§9).
          let is_im: Bool?
          let is_mpim: Bool?
          let is_private: Bool?
        }
      }
      struct Paging: Decodable {
        let page: Int?
        let pages: Int?
      }
      let matches: [Match]?
      let paging: Paging?
    }
    let ok: Bool
    let error: String?
    let messages: Messages?
  }

  private struct HistoryResponse: Decodable {
    struct Message: Decodable {
      let text: String?
      let user: String?
      let username: String?
      let ts: String?
      let thread_ts: String?
      let reply_count: Int?
      struct Edit: Decodable { let ts: String? }
      let edited: Edit?
    }
    let ok: Bool
    let error: String?
    let messages: [Message]?
    struct Metadata: Decodable {
      let next_cursor: String?
    }
    let response_metadata: Metadata?
  }

  private struct PostResponse: Decodable {
    let ok: Bool
    let error: String?
    let ts: String?
    let channel: String?
  }

  /// Slack 질의의 날짜 형식(`YYYY-MM-DD`). 공급자가 정한 모양이다.
  private static func day(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  // MARK: 검색

  private func search(_ request: ActionRequest, account: ConnectorAccount, token: String) async throws -> ActionReceipt {
    guard let query = request.arguments["query"]?.textValue, !query.isEmpty else {
      throw ActionError.invalidArguments(reason: "query")
    }
    let limit = min(
      max(Int(request.arguments["limit"]?.numberValue ?? 10), 1), Self.maxMatches)
    // 기간은 **Slack의 질의 문법**으로 싣는다(`after:`·`before:`). 공급자가 거르면
    // 우리가 받아오는 양이 그만큼 줄고, 그 양이 곧 문맥이다.
    let scoped = [
      query,
      request.arguments["after"]?.dateValue.map { "after:\(Self.day($0))" },
      request.arguments["before"]?.dateValue.map { "before:\(Self.day($0))" },
    ].compactMap { $0 }.joined(separator: " ")
    var components = URLComponents(string: "\(Self.base)/search.messages")!
    components.queryItems = [
      URLQueryItem(name: "query", value: scoped),
      URLQueryItem(name: "count", value: String(limit)),
      URLQueryItem(name: "sort", value: "timestamp"),
    ]
    // Slack 검색의 쪽 넘김은 커서가 아니라 **1부터 세는 page**다. 능력 계약의
    // `cursor`를 그 숫자로 옮긴다 — 호출부는 공급자의 방식을 알지 않는다.
    if let cursor = request.arguments["cursor"]?.textValue, let page = Int(cursor), page > 1 {
      components.queryItems?.append(URLQueryItem(name: "page", value: String(page)))
    }
    guard let url = components.url else { throw ActionError.invalidArguments(reason: "url") }
    let data = try await http.get(url, accessToken: token)
    guard let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data) else {
      throw ActionError.failed(reason: "chat.decode")
    }
    guard decoded.ok else { throw Self.failure(decoded.error, capability: request.capability) }

    let matches = Array((decoded.messages?.matches ?? []).prefix(limit))
    let rows = matches.map(Self.row)

    var details = CapabilitySourceRow.detail(rows)
    let paging = decoded.messages?.paging
    let page = paging?.page ?? 1
    // 다음 장이 있으면 그 쪽 번호가 커서다. 없으면 빈 값이다 — 빈 커서는
    // "더 없다"는 뜻이고, 호출부는 그것으로 멈춘다.
    details["cursor"] = .text(page < (paging?.pages ?? page) ? String(page + 1) : "")
    details["matchCount"] = .number(Double(matches.count))
    return ActionReceipt(
      requestID: request.id, capability: request.capability,
      summary: "chat.search.result",
      details: details,
      sources: matches.compactMap { match in
        Self.source(request, account: account, channel: match.channel?.id, ts: match.ts,
          deepLink: match.permalink.flatMap(URL.init(string:)))
      },
      coverage: Self.coverage(request, account: account, count: matches.count,
        read: 0, cursor: details["cursor"]?.textValue ?? ""))
  }

  // MARK: 선택한 채널 또는 스레드 읽기

  private func read(_ request: ActionRequest, account: ConnectorAccount, token: String) async throws -> ActionReceipt {
    guard let channel = request.arguments["channelID"]?.textValue, !channel.isEmpty else {
      throw ActionError.ambiguous(reason: "channelID")
    }
    let thread = request.arguments["threadTS"]?.textValue.flatMap { $0.isEmpty ? nil : $0 }
    let endpoint = thread == nil ? "conversations.history" : "conversations.replies"
    let limit = min(max(Int(request.arguments["limit"]?.numberValue ?? 20), 1), 50)
    var components = URLComponents(string: "\(Self.base)/\(endpoint)")!
    components.queryItems = [
      URLQueryItem(name: "channel", value: channel),
      URLQueryItem(name: "limit", value: String(limit)),
    ]
    if let thread { components.queryItems?.append(URLQueryItem(name: "ts", value: thread)) }
    if let cursor = request.arguments["cursor"]?.textValue, !cursor.isEmpty {
      components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor))
    }
    guard let url = components.url else { throw ActionError.invalidArguments(reason: "url") }
    let data = try await http.get(url, accessToken: token)
    guard let decoded = try? JSONDecoder().decode(HistoryResponse.self, from: data) else {
      throw ActionError.failed(reason: "chat.decode")
    }
    guard decoded.ok else { throw Self.failure(decoded.error, capability: request.capability) }
    let messages = decoded.messages ?? []
    let rows = messages.map { message in
      CapabilitySourceRow(
        title: channel, subtitle: message.username ?? message.user ?? "",
        body: message.text ?? "", identifier: channel, timestamp: message.ts ?? "")
    }
    let cursor = decoded.response_metadata?.next_cursor ?? ""
    var details = CapabilitySourceRow.detail(rows)
    details["cursor"] = .text(cursor)
    return ActionReceipt(
      requestID: request.id, capability: request.capability,
      summary: "chat.read.result", details: details,
      sources: messages.compactMap { message in
        Self.source(request, account: account, channel: channel, ts: message.ts,
          revision: message.edited?.ts ?? ActionFingerprint.arguments(["text": .text(message.text ?? "")]))
      },
      coverage: Self.coverage(request, account: account, count: rows.count, read: rows.count, cursor: cursor))
  }

  private static func source(
    _ request: ActionRequest, account: ConnectorAccount, channel: String?, ts: String?,
    revision: String? = nil, deepLink: URL? = nil
  ) -> SourceReference? {
    guard let binding = account.binding, let channel, !channel.isEmpty, let ts, !ts.isEmpty else { return nil }
    var link = URLComponents(string: "slack://channel")!
    link.queryItems = [URLQueryItem(name: "id", value: channel), URLQueryItem(name: "message", value: ts)]
    if let workspace = binding.workspaceID {
      link.queryItems?.append(URLQueryItem(name: "team", value: workspace))
    }
    return SourceReference(
      accountID: request.accountID, binding: .connector(binding), kind: .chatMessage,
      id: ts, containerID: channel, revision: revision,
      timestamp: Double(ts).map { Date(timeIntervalSince1970: $0) }, deepLink: deepLink ?? link.url)
  }

  private static func coverage(
    _ request: ActionRequest, account: ConnectorAccount, count: Int, read: Int, cursor: String
  ) -> [CoverageRecord] {
    guard let binding = account.binding else { return [] }
    return [CoverageRecord(
      binding: .connector(binding), capability: request.capability,
      queryFingerprint: ActionFingerprint.arguments(request.arguments),
      state: cursor.isEmpty ? .complete : .partial, discoveredCount: count, readCount: read,
      paginationExhausted: cursor.isEmpty, reason: cursor.isEmpty ? nil : .pagination)]
  }

  // MARK: 쓰기

  private func post(_ request: ActionRequest, token: String) async throws -> ActionReceipt {
    guard let channel = request.arguments["channelID"]?.textValue, !channel.isEmpty else {
      throw ActionError.ambiguous(reason: "channelID")
    }
    guard let text = request.arguments["text"]?.textValue, !text.isEmpty else {
      throw ActionError.invalidArguments(reason: "text")
    }
    var payload: [String: Any] = ["channel": channel, "text": text]
    if request.capability == .chatReply {
      guard let thread = request.arguments["threadTS"]?.textValue, !thread.isEmpty else {
        throw ActionError.ambiguous(reason: "threadTS")
      }
      payload["thread_ts"] = thread
    }
    guard let body = try? JSONSerialization.data(withJSONObject: payload),
      let url = URL(string: "\(Self.base)/chat.postMessage")
    else { throw ActionError.failed(reason: "chat.encode") }
    let data = try await http.post(url, accessToken: token, body: body)
    guard let decoded = try? JSONDecoder().decode(PostResponse.self, from: data) else {
      throw ActionError.failed(reason: "chat.sendOutcomeUnknown")
    }
    guard decoded.ok else { throw Self.failure(decoded.error, capability: request.capability) }
    return ActionReceipt(
      requestID: request.id, capability: request.capability,
      externalID: decoded.ts,
      summary: "chat.send.done",
      details: ["channel": .text(channel)])
  }

  private static func row(_ match: SearchResponse.Messages.Match) -> CapabilitySourceRow {
    // `identifier`는 **채널 id**다. 스레드를 펼치거나 답장하려면 채널 id가
    // 필요하고, 이름은 사람에게 보이는 값일 뿐이다. `timestamp`는 Slack의 `ts`
    // 그대로다 — 그 값이 곧 스레드 열쇠다(`thread_ts`).
    CapabilitySourceRow(
      title: match.channel.map(Self.channelLabel) ?? "",
      subtitle: match.username ?? match.user ?? "",
      body: match.text ?? "",
      identifier: match.channel?.id ?? "",
      timestamp: match.ts ?? "")
  }

  /// 채널 이름. DM과 그룹 DM은 이름이 없으므로 종류를 말한다 — 빈 이름은
  /// 사용자가 어디서 온 글인지 알 수 없게 한다.
  private static func channelLabel(
    _ channel: SearchResponse.Messages.Match.Channel
  ) -> String {
    if let name = channel.name, !name.isEmpty { return name }
    if channel.is_im == true { return "DM" }
    if channel.is_mpim == true { return "group DM" }
    return channel.id ?? ""
  }

  /// Slack의 오류 낱말을 우리 오류로 옮긴다. **원문을 사용자에게 그대로 보이지
  /// 않는다** — 토큰 범위 이름이 섞여 나온다.
  private static func failure(_ code: String?, capability: CapabilityID) -> ActionError {
    switch code {
    case "not_authed", "invalid_auth", "token_revoked", "account_inactive",
      "token_expired":
      return .notAuthorized(capability)
    // 범위가 모자란 것은 재인증으로 고쳐진다 — 사용자가 다시 연결하면 새 범위를
    // 받는다. 실패로만 말하면 사용자는 무엇을 해야 할지 알 수 없다.
    case "missing_scope", "not_allowed_token_type":
      return .notAuthorized(capability)
    case "ratelimited", "rate_limited":
      return .failed(reason: "chat.throttled")
    case "channel_not_found", "not_in_channel", "thread_not_found":
      return .ambiguous(reason: "channelID")
    default:
      return .failed(reason: "chat.rejected")
    }
  }
}
