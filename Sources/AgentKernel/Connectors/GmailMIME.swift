import Foundation

/// Gmail 메시지의 **본문**.
///
/// `snippet`은 본문이 아니다. 그것은 목록에 보이는 한 줄이고, 길이가 200자
/// 안팎이며 인용문·서명이 섞여 있다. 그 값을 본문으로 다루면 "그 메일 읽고
/// 정리해줘"의 답이 제목 근처의 글자 몇 개로 만들어진다.
///
/// 그래서 여기서 하는 일은 넷이다:
///
/// 1. MIME 트리를 **재귀로** 걷는다(`multipart/alternative` 안의
///    `multipart/related` 안의 `text/html`까지).
/// 2. `text/plain`을 먼저 쓰고, 없으면 `text/html`을 기존 변환기로 옮긴다
///    (`HTMLMarkdown` — 붙여넣기 경로가 쓰는 그 변환기다).
/// 3. base64url을 푼다. 선언된 charset을 존중한다 — EUC-KR 메일을 UTF-8로 읽으면
///    글자가 통째로 깨진다.
/// 4. 상한을 건다. 그리고 **잘랐다는 사실을 숨기지 않는다**(`wasTruncated`).
public struct GmailMessageBody: Sendable, Hashable {
  public let text: String
  /// 어느 부분에서 왔는가(`text/plain`·`text/html`). 빈 값이면 본문이 없었다.
  public let mimeType: String
  /// 상한에 걸려 잘렸는가. 화면은 이 값을 배너로 말한다 — 침묵하면 사용자는
  /// 요약이 메일 전체를 담았다고 믿는다.
  public let wasTruncated: Bool
  /// 인용문·서명을 걷어냈는가.
  public let didTrimQuotedReply: Bool

  public init(
    text: String, mimeType: String, wasTruncated: Bool = false,
    didTrimQuotedReply: Bool = false
  ) {
    self.text = text
    self.mimeType = mimeType
    self.wasTruncated = wasTruncated
    self.didTrimQuotedReply = didTrimQuotedReply
  }

  public static let empty = GmailMessageBody(text: "", mimeType: "")
}

/// Gmail `users.messages.get?format=full`의 페이로드 트리.
public struct GmailMIMEPart: Decodable, Sendable {
  public struct Header: Decodable, Sendable {
    public let name: String
    public let value: String
  }

  public struct Body: Decodable, Sendable {
    public let size: Int?
    /// base64url. 큰 본문은 여기가 비고 `attachmentId`만 온다.
    public let data: String?
    public let attachmentId: String?
  }

  public let partId: String?
  public let mimeType: String?
  public let filename: String?
  public let headers: [Header]?
  public let body: Body?
  public let parts: [GmailMIMEPart]?

  public func header(_ name: String) -> String {
    headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
  }

  /// 이 부분이 **첨부**인가. 파일 이름이 있거나 `Content-Disposition: attachment`면
  /// 본문이 아니다 — `notes.txt`를 본문으로 읽으면 사용자가 쓴 글이 사라진다.
  var isAttachment: Bool {
    if let filename, !filename.isEmpty { return true }
    return header("Content-Disposition").lowercased().contains("attachment")
  }

  var charset: String? {
    let contentType = header("Content-Type")
    guard let range = contentType.range(of: "charset=", options: .caseInsensitive) else {
      return nil
    }
    let raw = contentType[range.upperBound...]
      .prefix { $0 != ";" }
      .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    return raw.isEmpty ? nil : raw
  }
}

public enum GmailMIME {
  /// 본문으로 가져갈 최대 바이트. 넘으면 자르고 잘랐다고 말한다.
  public static let maxBodyBytes = 64 * 1_024

  /// 트리에서 본문 부분을 고른다. `text/plain`이 `text/html`을 이긴다.
  public static func textPart(in root: GmailMIMEPart) -> GmailMIMEPart? {
    var plain: GmailMIMEPart?
    var html: GmailMIMEPart?
    walk(root) { part in
      guard !part.isAttachment else { return }
      switch part.mimeType?.lowercased() {
      case "text/plain" where plain == nil:
        plain = part
      case "text/html" where html == nil:
        html = part
      default:
        break
      }
    }
    return plain ?? html
  }

  /// 트리의 모든 첨부. `mail.read`가 본문을 찾지 못했을 때 텍스트 첨부로
  /// 물러서는 자리이고, 그 판단은 호출부가 한다.
  public static func attachments(in root: GmailMIMEPart) -> [GmailMIMEPart] {
    var found: [GmailMIMEPart] = []
    walk(root) { part in
      if part.isAttachment, part.body?.attachmentId != nil { found.append(part) }
    }
    return found
  }

  private static func walk(_ part: GmailMIMEPart, _ visit: (GmailMIMEPart) -> Void) {
    visit(part)
    for child in part.parts ?? [] { walk(child, visit) }
  }

  /// base64url을 푼다. Gmail은 패딩을 빼고 `-_`를 쓴다.
  public static func decodeBase64URL(_ raw: String) -> Data? {
    var normalized = raw
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
      .replacingOccurrences(of: "\r", with: "")
      .replacingOccurrences(of: "\n", with: "")
    let remainder = normalized.count % 4
    if remainder > 0 {
      normalized.append(String(repeating: "=", count: 4 - remainder))
    }
    return Data(base64Encoded: normalized)
  }

  /// 바이트를 글자로. 선언된 charset을 먼저 쓰고, 없으면 UTF-8, 그다음 CP949다 —
  /// 한국어 메일에 charset이 빠져 있는 경우가 실제로 있다.
  public static func decodeText(_ data: Data, charset: String?) -> String? {
    if let charset {
      let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
      if cf != kCFStringEncodingInvalidId {
        let encoding = String.Encoding(
          rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        if let text = String(data: data, encoding: encoding) { return text }
      }
    }
    if let text = String(data: data, encoding: .utf8) { return text }
    let cp949 = String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
    return String(data: data, encoding: cp949)
  }

  /// 부분 하나를 사람이 읽을 글로. HTML은 기존 변환기를 지난다.
  public static func body(
    from part: GmailMIMEPart, decoded data: Data
  ) -> GmailMessageBody {
    let clipped = data.count > maxBodyBytes ? data.prefix(maxBodyBytes) : data
    guard let raw = decodeText(Data(clipped), charset: part.charset) else {
      return .empty
    }
    let mimeType = part.mimeType?.lowercased() ?? "text/plain"
    let text = mimeType == "text/html" ? HTMLMarkdown.markdown(fromHTML: raw) : raw
    let trimmed = trimQuotedReply(text)
    return GmailMessageBody(
      text: trimmed.text,
      mimeType: mimeType,
      wasTruncated: data.count > maxBodyBytes,
      didTrimQuotedReply: trimmed.didTrim)
  }

  /// 인용문과 서명을 걷어낸다. **확실한 경계만** 자른다.
  ///
  /// 자를 수 있는 경계는 표준이 정한 것들이다: RFC 3676의 서명 구분선(`-- `),
  /// 메일 클라이언트가 넣는 인용 머리줄(`On … wrote:`·`…님이 작성:`), Outlook의
  /// 구분선과 전달 머리(`From:` 블록). 그 밖에는 손대지 않는다 — 본문 한복판의
  /// `>`는 인용이 아니라 화살표일 수 있다.
  ///
  /// 자른 뒤 남는 글이 없으면 **자르지 않은 원문**을 돌려준다. 인용만으로 이뤄진
  /// 메일도 있고, 그 경우 사용자가 읽고 싶은 것은 그 인용이다.
  public static func trimQuotedReply(_ text: String) -> (text: String, didTrim: Bool) {
    let lines = text.components(separatedBy: "\n")
    guard let boundary = lines.firstIndex(where: { isReplyBoundary($0) }) else {
      return (text.trimmingCharacters(in: .whitespacesAndNewlines), false)
    }
    let kept = lines[..<boundary].joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !kept.isEmpty else {
      return (text.trimmingCharacters(in: .whitespacesAndNewlines), false)
    }
    return (kept, true)
  }

  private static func isReplyBoundary(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    // RFC 3676 서명 구분선.
    if trimmed == "--" || line == "-- " { return true }
    // Outlook·Gmail의 구분선.
    if trimmed.count >= 5, trimmed.allSatisfy({ $0 == "_" }) { return true }
    if trimmed.hasPrefix("-----Original Message-----") { return true }
    // 인용 머리줄. 끝이 콜론이고 작성/wrote를 말하는 한 줄만 본다.
    let lowered = trimmed.lowercased()
    if lowered.hasSuffix("wrote:"), lowered.hasPrefix("on ") { return true }
    if trimmed.hasSuffix("작성:") || trimmed.hasSuffix("작성했습니다:") { return true }
    if lowered.hasPrefix("from:"), trimmed.contains("@") { return true }
    return false
  }
}
