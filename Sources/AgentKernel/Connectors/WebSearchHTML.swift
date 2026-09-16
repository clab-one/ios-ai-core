import Foundation

/// 검색 한 번의 네트워크 왕복. **시험이 이 문으로 대역을 세운다.**
///
/// 프로토콜이 아니라 함수인 이유: 값이 하나뿐이고(요청 → 바이트), 그 하나를
/// 타입으로 감싸면 시험마다 대역 타입을 만들어야 한다.
public typealias WebSearchTransport = @Sendable (URLRequest) async throws -> Data

/// 열쇠 없이 부르는 검색 요청과 그 응답 판정.
public enum WebSearchHTTP {
  /// **실측 2026-09-17**: User-Agent가 없으면 `html.duckduckgo.com`이 202를
  /// 돌려주고 결과가 0건이다. iPhone UA로는 200에 열 건이 온다.
  static let userAgent =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) "
    + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

  public static let shared: WebSearchTransport = { request in
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw WebSearchError.malformedResponse
    }
    switch http.statusCode {
    // **사람인지 묻는 응답은 우회하지 않는다.** 다음 엔진으로 간다.
    case 202, 403, 429: throw WebSearchError.challenged
    case 200..<300: return data
    default: throw WebSearchError.rejected(status: http.statusCode)
    }
  }

  /// 폼 본문 요청. 질의는 **URL이 아니라 본문에** 실린다 — 주소는 로그와 프록시에
  /// 남고, 검색어는 사용자 글이다.
  static func form(_ endpoint: String, fields: [(String, String)]) throws -> URLRequest {
    guard let url = URL(string: endpoint) else { throw WebSearchError.malformedResponse }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.httpBody = body(fields)
    request.setValue(
      "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("text/html", forHTTPHeaderField: "Accept")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    return request
  }

  /// 두 엔진이 같은 폼 자리를 쓴다(`q`, `df`). 창이 없으면 `df`를 **보내지 않는다** —
  /// 빈 값을 보내면 공급자가 그것을 필터로 읽는다.
  static func fields(query: String, window: WebSearchWindow?) -> [(String, String)] {
    guard let window else { return [("q", query)] }
    return [("q", query), ("df", window.dayRange)]
  }

  /// 예약되지 않은 글자만 남기고 전부 인코딩한다.
  ///
  /// `URLComponents`를 쓰지 않는 이유는 `+`다. 그 글자를 그대로 두면 서버가 공백으로
  /// 읽고 `"C++"`를 찾는 질의가 `"C  "`가 된다.
  private static func body(_ fields: [(String, String)]) -> Data {
    let unreserved = CharacterSet(
      charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    let pairs = fields.map { key, value in
      let encodedKey = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
      let encodedValue =
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
      return "\(encodedKey)=\(encodedValue)"
    }
    return Data(pairs.joined(separator: "&").utf8)
  }
}

/// DuckDuckGo의 HTML 결과 페이지.
///
/// 열쇠가 필요 없고 JavaScript도 필요 없다. 돌려주는 것은 제목·주소·스니펫뿐이므로
/// **검색 결과 HTML은 기기를 떠나지 않는다** — 떠나는 것은 그 뒤에 만든 작은 근거다.
public struct DuckDuckGoHTMLSearch: WebSearchEngine {
  public let name = "duckduckgo.html"
  private let transport: WebSearchTransport

  public init(transport: @escaping WebSearchTransport = WebSearchHTTP.shared) {
    self.transport = transport
  }

  public func search(
    query: String, limit: Int, window: WebSearchWindow? = nil
  ) async throws -> [WebSearchResult] {
    let data = try await transport(
      try WebSearchHTTP.form(
        "https://html.duckduckgo.com/html/",
        fields: WebSearchHTTP.fields(query: query, window: window)))
    guard let html = String(data: data, encoding: .utf8) else {
      throw WebSearchError.malformedResponse
    }
    return SERPScraper.results(
      in: html, linkClass: "result__a", snippetClass: "result__snippet", limit: limit)
  }
}

/// 같은 공급자의 **가벼운 표 레이아웃.**
///
/// HTML 쪽이 challenge를 세운 순간 이 문이 열려 있는 경우가 있다 — 자동화 차단
/// 경로가 다르다. 마크업도 다르다(`class='result-link'`, `<td class='result-snippet'>`).
public struct DuckDuckGoLiteSearch: WebSearchEngine {
  public let name = "duckduckgo.lite"
  private let transport: WebSearchTransport

  public init(transport: @escaping WebSearchTransport = WebSearchHTTP.shared) {
    self.transport = transport
  }

  public func search(
    query: String, limit: Int, window: WebSearchWindow? = nil
  ) async throws -> [WebSearchResult] {
    let data = try await transport(
      try WebSearchHTTP.form(
        "https://lite.duckduckgo.com/lite/",
        fields: WebSearchHTTP.fields(query: query, window: window)))
    guard let html = String(data: data, encoding: .utf8) else {
      throw WebSearchError.malformedResponse
    }
    return SERPScraper.results(
      in: html, linkClass: "result-link", snippetClass: "result-snippet", limit: limit)
  }
}

/// 검색 결과 페이지에서 **제목·주소·스니펫만** 긁는다.
///
/// 본문 파서가 아니다(`HTMLMarkdown`). 그 둘을 섞지 않는 이유는 입력이 다르기
/// 때문이다: 이쪽은 결과 목록이고 저쪽은 문서다. 다만 토크나이저는 **하나를 쓴다**
/// — 태그를 읽는 두 번째 관례를 만들면 엔티티 해독이 두 곳에서 갈라진다.
enum SERPScraper {
  private enum Kind {
    case link(url: String)
    case snippet
  }

  private struct Capture {
    let name: String
    let kind: Kind
    var depth: Int
    var text: String
  }

  static func results(
    in html: String, linkClass: String, snippetClass: String, limit: Int
  ) -> [WebSearchResult] {
    var staged: [(title: String, url: String, snippet: String)] = []
    var capture: Capture?

    HTMLMarkdown.Tokenizer.walk(html) { token in
      switch token {
      case .open(let name, let attributes):
        // 잡고 있는 중에는 새로 잡지 않는다. 스니펫 안의 `<b>`는 글자일 뿐이다.
        if var active = capture {
          if name == active.name {
            active.depth += 1
            capture = active
          }
          return
        }
        let classes = attributes["class", default: ""].split(whereSeparator: \.isWhitespace)
        if classes.contains(where: { $0 == linkClass }) {
          // **주소가 없거나 쓸 수 없으면 결과가 아니다.** 잡지 않으므로 뒤따르는
          // 스니펫도 앞 결과에 붙지 않는다(앞 결과는 이미 자기 스니펫을 들었다).
          guard let url = canonical(attributes["href"]) else { return }
          capture = Capture(name: name, kind: .link(url: url), depth: 1, text: "")
        } else if classes.contains(where: { $0 == snippetClass }) {
          capture = Capture(name: name, kind: .snippet, depth: 1, text: "")
        }
      case .close(let name):
        guard var active = capture, name == active.name else { return }
        active.depth -= 1
        guard active.depth == 0 else {
          capture = active
          return
        }
        capture = nil
        let text = collapsed(active.text)
        switch active.kind {
        case .link(let url):
          guard staged.count < limit, !text.isEmpty else { return }
          staged.append((title: text, url: url, snippet: ""))
        case .snippet:
          // 스니펫은 **바로 앞 결과**의 것이다. 이미 채워진 자리는 건드리지 않는다.
          guard let last = staged.indices.last, staged[last].snippet.isEmpty else { return }
          staged[last].snippet = text
        }
      case .text(let value):
        guard var active = capture else { return }
        active.text += value
        capture = active
      }
    }

    return staged.map {
      WebSearchResult(title: $0.title, url: $0.url, snippet: $0.snippet)
    }
  }

  /// 결과 주소 하나를 **쓸 수 있는 값으로.**
  ///
  /// 셋을 한다: 공급자 리다이렉트를 벗기고(`/l/?uddg=`), http(s)가 아닌 것을 버리고,
  /// 공급자 자기 주소를 버린다 — 광고는 `duckduckgo.com/y.js`로 가고, 그 주소를
  /// 다음 단계가 읽으면 사용자가 요청하지 않은 페이지를 읽는다.
  private static func canonical(_ raw: String?) -> String? {
    guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return nil }
    if value.hasPrefix("//") { value = "https:" + value }
    guard var url = URL(string: value) else { return nil }
    if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
      let unwrapped = URL(string: target)
    {
      url = unwrapped
    }
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = url.host?.lowercased(), !host.isEmpty,
      host != "duckduckgo.com", !host.hasSuffix(".duckduckgo.com")
    else { return nil }
    return url.absoluteString
  }

  /// 공백을 접는다. 표 레이아웃의 스니펫은 줄바꿈과 들여쓰기를 그대로 들고 온다.
  private static func collapsed(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
