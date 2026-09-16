import Foundation

/// Gmail 어댑터. 모델은 이 타입의 이름을 **모른다** — `mail.search`를 부르면
/// 라우터가 연결된 계정을 보고 여기로 보낸다.
public struct GmailAdapter: ConnectorAdapter, ConnectorTargetRevisionReading {
  public let provider: ConnectorProvider = .google
  public var capabilities: Set<CapabilityID> {
    [.mailSearch, .mailRead, .mailSend, .mailReply]
  }

  private let http: ConnectorHTTP
  private static let base = "https://gmail.googleapis.com/gmail/v1/users/me"
  /// 목록 한 번에 볼 최대 통수. 공급자 상한이 아니라 **문맥 상한**이다.
  private static let maxSearchResults = 25

  public init(http: ConnectorHTTP = ConnectorHTTP()) {
    self.http = http
  }

  /// 대상 메일의 지금 `historyId`. 전송·답장 직전 재확인에 쓴다 — 계획 시점에
  /// 본 값과 다르면 그 사이 대상이 갱신된 것이다.
  public func currentTargetRevision(
    _ request: ActionRequest, account: ConnectorAccount, accessToken: String
  ) async throws -> String? {
    guard let id = request.arguments["messageID"]?.textValue, !id.isEmpty else { return nil }
    let message = try await fetch(id: id, token: accessToken, metadataOnly: true)
    return message.historyId
  }

  public func perform(
    _ request: ActionRequest, account: ConnectorAccount, accessToken: String
  ) async throws -> ActionReceipt {
    switch request.capability {
    case .mailSearch:
      return try await search(request, account: account, token: accessToken)
    case .mailRead:
      return try await read(request, account: account, token: accessToken)
    case .mailSend, .mailReply:
      return try await send(request, account: account, token: accessToken)
    default:
      throw ActionError.unsupported(request.capability)
    }
  }

  // MARK: 읽기

  private struct MessageList: Decodable {
    struct Reference: Decodable {
      let id: String
      let threadId: String?
    }
    let messages: [Reference]?
    let nextPageToken: String?
  }

  /// `users.messages.get`의 응답. 페이로드는 **트리**다(`GmailMIMEPart`).
  private struct Message: Decodable {
    let id: String
    let threadId: String?
    let historyId: String?
    let internalDate: String?
    let snippet: String?
    let payload: GmailMIMEPart?

    func header(_ name: String) -> String {
      payload?.header(name) ?? ""
    }
  }

  private static func source(
    _ message: Message, request: ActionRequest, account: ConnectorAccount
  ) -> SourceReference? {
    guard let binding = account.binding else { return nil }
    let timestamp = message.internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1_000) }
    var link = URLComponents(string: "https://mail.google.com/mail/")!
    link.queryItems = [URLQueryItem(name: "authuser", value: account.id)]
    link.fragment = "all/\(message.id)"
    return SourceReference(
      accountID: request.accountID, binding: .connector(binding), kind: .mailMessage,
      id: message.id, containerID: message.threadId, revision: message.historyId,
      timestamp: timestamp, deepLink: link.url)
  }

  private static func coverage(
    _ request: ActionRequest, account: ConnectorAccount, discovered: Int, read: Int,
    hasMore: Bool, truncated: Bool = false, reason: CoverageRecord.Reason? = nil
  ) -> [CoverageRecord] {
    guard let binding = account.binding else { return [] }
    let reason = reason ?? (truncated ? .truncation : (hasMore ? .pagination : nil))
    return [CoverageRecord(
      binding: .connector(binding), capability: request.capability,
      queryFingerprint: ActionFingerprint.arguments(request.arguments),
      state: reason == nil ? .complete : .partial,
      discoveredCount: discovered, readCount: read, paginationExhausted: !hasMore,
      truncated: truncated, reason: reason)]
  }

  private struct AttachmentBody: Decodable {
    let size: Int?
    let data: String?
  }
  /// Gmail 질의의 날짜 형식(`YYYY/MM/DD`). 공급자가 정한 모양이다.
  private static func day(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy/MM/dd"
    return formatter.string(from: date)
  }


  private func search(_ request: ActionRequest, account: ConnectorAccount, token: String) async throws -> ActionReceipt {
    guard let query = request.arguments["query"]?.textValue, !query.isEmpty else {
      throw ActionError.invalidArguments(reason: "query")
    }
    let limit = min(
      max(Int(request.arguments["limit"]?.numberValue ?? 10), 1), Self.maxSearchResults)
    // 기간은 **Gmail의 질의 문법**으로 싣는다. 받아온 뒤 걸러 내면 받아오는 양만
    // 늘어나고, 그 양이 문맥을 채운다.
    let scoped = [
      query,
      request.arguments["after"]?.dateValue.map { "after:\(Self.day($0))" },
      request.arguments["before"]?.dateValue.map { "before:\(Self.day($0))" },
    ].compactMap { $0 }.joined(separator: " ")
    var components = URLComponents(string: "\(Self.base)/messages")!
    components.queryItems = [
      URLQueryItem(name: "q", value: scoped),
      URLQueryItem(name: "maxResults", value: String(limit)),
    ]
    // 커서는 공급자의 `pageToken`이다. 이름을 능력 계약의 `cursor`로 정규화해
    // 두면 호출부가 공급자를 알지 않아도 다음 장을 넘길 수 있다.
    if let cursor = request.arguments["cursor"]?.textValue, !cursor.isEmpty {
      components.queryItems?.append(URLQueryItem(name: "pageToken", value: cursor))
    }
    guard let url = components.url else { throw ActionError.invalidArguments(reason: "url") }
    let data = try await http.get(url, accessToken: token)
    guard let list = try? JSONDecoder().decode(MessageList.self, from: data) else {
      throw ActionError.failed(reason: "mail.decode")
    }
    // 본문은 목록 단계에서 읽지 않는다 — 스무 통의 본문을 문맥에 실으면 문맥이
    // 통째로 남의 글이 된다. 필요한 통만 `mail.read`가 다시 읽는다.
    var rows: [CapabilitySourceRow] = []
    var sources: [SourceReference] = []
    for reference in (list.messages ?? []).prefix(limit) {
      guard let message = try? await fetch(id: reference.id, token: token, metadataOnly: true)
      else { continue }
      if let source = Self.source(message, request: request, account: account) {
        sources.append(source)
      }
      rows.append(
        CapabilitySourceRow(
          title: message.header("Subject"),
          subtitle: message.header("From"),
          identifier: message.id,
          timestamp: message.header("Date")))
    }
    var details = CapabilitySourceRow.detail(rows)
    details["cursor"] = .text(list.nextPageToken ?? "")
    return ActionReceipt(
      requestID: request.id, capability: request.capability,
      summary: "mail.search.result",
      details: details, sources: sources,
      coverage: Self.coverage(request, account: account,
        discovered: list.messages?.count ?? 0, read: 0,
        hasMore: !(list.nextPageToken ?? "").isEmpty,
        reason: rows.count < min(list.messages?.count ?? 0, limit) ? .metadataUnavailable : nil))
  }

  /// 한 통을 **실제 본문까지** 읽는다.
  ///
  /// `snippet`을 본문으로 쓰지 않는다. 그 값은 목록용 한 줄이고, 그것으로 요약을
  /// 만들면 사용자는 앱이 메일을 읽었다고 믿는다.
  private func read(_ request: ActionRequest, account: ConnectorAccount, token: String) async throws -> ActionReceipt {
    guard let id = request.arguments["messageID"]?.textValue, !id.isEmpty else {
      throw ActionError.invalidArguments(reason: "messageID")
    }
    let message = try await fetch(id: id, token: token, metadataOnly: false)
    let body = try await resolveBody(of: message, token: token)
    // 본문은 **원문 그대로** 올린다. 감싸는 자리는 축약기 하나다
    // (`CapabilitySourceRow.body` 주석).
    let row = CapabilitySourceRow(
      title: message.header("Subject"),
      subtitle: message.header("From"),
      body: body.text,
      identifier: message.id,
      timestamp: message.header("Date"))
    var details = CapabilitySourceRow.detail([row])
    details["from"] = .text(message.header("From"))
    details["subject"] = .text(message.header("Subject"))
    details["threadID"] = .text(message.threadId ?? "")
    details["messageIDHeader"] = .text(message.header("Message-ID"))
    details["body"] = .text(body.text)
    details["bodyMimeType"] = .text(body.mimeType)
    // **읽은 범위를 숨기지 않는다.** 상한에 걸려 잘렸으면 그 사실이 수령증에 남고,
    // 화면이 그것을 말한다(`app/AGENTS.md` — "읽은 범위").
    details["truncated"] = .flag(body.wasTruncated)
    details["quotedReplyTrimmed"] = .flag(body.didTrimQuotedReply)
    return ActionReceipt(
      requestID: request.id, capability: request.capability, externalID: message.id,
      summary: "mail.read.result",
      details: details, sources: Self.source(message, request: request, account: account).map { [$0] } ?? [],
      coverage: Self.coverage(request, account: account,
        discovered: 1, read: body.mimeType == "text/snippet" ? 0 : 1, hasMore: false,
        truncated: body.wasTruncated,
        reason: body.mimeType == "text/snippet" ? .bodyUnavailable : nil))
  }

  /// 본문 하나를 확정한다. 순서는 `text/plain` → `text/html` → 텍스트 첨부다.
  private func resolveBody(
    of message: Message, token: String
  ) async throws -> GmailMessageBody {
    guard let payload = message.payload else {
      return GmailMessageBody(text: message.snippet ?? "", mimeType: "text/snippet")
    }
    if let part = GmailMIME.textPart(in: payload),
      let data = try await payloadData(part, messageID: message.id, token: token)
    {
      let body = GmailMIME.body(from: part, decoded: data)
      if !body.text.isEmpty { return body }
    }
    // 본문이 첨부로 실려 오는 메일이 있다(일부 메일링 리스트·자동 발송). 텍스트
    // 첨부 하나까지는 본문으로 받아들인다.
    for attachment in GmailMIME.attachments(in: payload)
    where (attachment.mimeType ?? "").lowercased().hasPrefix("text/") {
      guard let data = try await payloadData(
        attachment, messageID: message.id, token: token)
      else { continue }
      let body = GmailMIME.body(from: attachment, decoded: data)
      if !body.text.isEmpty { return body }
    }
    // 아무것도 읽지 못했으면 **지어내지 않는다.** snippet은 본문이 아니라고
    // 표시해 둔다 — 그 사실이 화면과 합성 재료의 신뢰도를 정한다.
    let snippet = message.snippet ?? ""
    return snippet.isEmpty
      ? .empty : GmailMessageBody(text: snippet, mimeType: "text/snippet")
  }

  /// 부분의 바이트. 인라인 `data`가 없으면 첨부 엔드포인트에서 받아온다.
  private func payloadData(
    _ part: GmailMIMEPart, messageID: String, token: String
  ) async throws -> Data? {
    if let inline = part.body?.data, !inline.isEmpty {
      return GmailMIME.decodeBase64URL(inline)
    }
    guard let attachmentID = part.body?.attachmentId, !attachmentID.isEmpty,
      // 상한을 **받기 전에** 본다. 20MB 첨부를 내려받아 자르는 것은 낭비다.
      (part.body?.size ?? 0) <= GmailMIME.maxBodyBytes * 8,
      let url = URL(
        string: "\(Self.base)/messages/\(messageID)/attachments/\(attachmentID)")
    else { return nil }
    let data = try await http.get(url, accessToken: token)
    guard let decoded = try? JSONDecoder().decode(AttachmentBody.self, from: data),
      let raw = decoded.data
    else { return nil }
    return GmailMIME.decodeBase64URL(raw)
  }

  private func fetch(id: String, token: String, metadataOnly: Bool) async throws -> Message {
    var components = URLComponents(string: "\(Self.base)/messages/\(id)")!
    components.queryItems =
      metadataOnly
      ? [
        URLQueryItem(name: "format", value: "metadata"),
        URLQueryItem(name: "metadataHeaders", value: "From"),
        URLQueryItem(name: "metadataHeaders", value: "Subject"),
        URLQueryItem(name: "metadataHeaders", value: "Date"),
      ]
      : [URLQueryItem(name: "format", value: "full")]
    guard let url = components.url else { throw ActionError.invalidArguments(reason: "url") }
    let data = try await http.get(url, accessToken: token)
    guard let message = try? JSONDecoder().decode(Message.self, from: data) else {
      throw ActionError.failed(reason: "mail.decode")
    }
    return message
  }

  // MARK: 쓰기

  private struct SendResult: Decodable {
    let id: String
    let threadId: String?
  }

  private func send(
    _ request: ActionRequest, account: ConnectorAccount, token: String
  ) async throws -> ActionReceipt {
    guard let to = request.arguments["to"]?.textValue, !to.isEmpty else {
      throw ActionError.ambiguous(reason: "to")
    }
    guard let body = request.arguments["body"]?.textValue, !body.isEmpty else {
      throw ActionError.invalidArguments(reason: "body")
    }
    let subject = request.arguments["subject"]?.textValue ?? ""
    let threadID = request.arguments["threadID"]?.textValue
    if request.capability == .mailReply, threadID == nil {
      throw ActionError.ambiguous(reason: "threadID")
    }
    let raw = Self.rfc822(
      from: account.id, to: to, subject: subject, body: body,
      inReplyTo: request.arguments["messageIDHeader"]?.textValue)
    var payload: [String: Any] = ["raw": raw]
    if let threadID { payload["threadId"] = threadID }
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
      let url = URL(string: "\(Self.base)/messages/send")
    else {
      throw ActionError.failed(reason: "mail.encode")
    }
    let response = try await http.post(url, accessToken: token, body: data)
    guard let result = try? JSONDecoder().decode(SendResult.self, from: response) else {
      // 보내졌는지 알 수 없다. **여기서 다시 보내지 않는다.**
      throw ActionError.failed(reason: "mail.sendOutcomeUnknown")
    }
    return ActionReceipt(
      requestID: request.id, capability: request.capability, externalID: result.id,
      summary: "mail.send.done",
      details: ["to": .text(to), "subject": .text(subject)])
  }

  /// 전송 원문. base64url로 싣는 것이 Gmail API의 요건이다.
  private static func rfc822(
    from: String, to: String, subject: String, body: String, inReplyTo: String?
  ) -> String {
    var lines = [
      "From: \(from)",
      "To: \(to)",
      "Subject: \(encodeHeader(subject))",
      "MIME-Version: 1.0",
      "Content-Type: text/plain; charset=UTF-8",
    ]
    if let inReplyTo, !inReplyTo.isEmpty {
      lines.append("In-Reply-To: \(inReplyTo)")
      lines.append("References: \(inReplyTo)")
    }
    let message = lines.joined(separator: "\r\n") + "\r\n\r\n" + body
    return Data(message.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  /// 한글 제목은 헤더에 그대로 실을 수 없다 — RFC 2047로 접어 보낸다.
  private static func encodeHeader(_ value: String) -> String {
    guard value.contains(where: { !$0.isASCII }) else { return value }
    return "=?UTF-8?B?\(Data(value.utf8).base64EncodedString())?="
  }
}
