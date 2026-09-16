import Foundation

/// 웹 검색 공급자 설정. **공급자 이름이 능력에 들어가지 않는다** —
/// `web.search`는 "웹에서 찾는다"의 이름이고, 어느 서비스로 찾는지는 설정이 정한다.
///
/// 값이 없으면 그 능력은 **등록되지 않는다**(연결 안 된 서비스와 같은 취급).
/// 키를 코드에 넣지 않는 이유는 연결 설정과 같다 — 저장소에 적힌 비밀은 비밀이 아니다.
public struct WebSearchConfiguration: Sendable {
  public let endpoint: URL
  /// 질의를 실을 쿼리 인자 이름(`q`·`query`).
  public let queryParameter: String
  /// 인증 헤더 이름과 값. 헤더가 아니라 쿼리로 키를 받는 공급자는
  /// `keyParameter`를 쓴다 — 어느 쪽이든 **URL 로그에 남지 않도록** 헤더를 먼저 쓴다.
  public let keyHeader: String?
  public let keyParameter: String?
  public let key: String

  public init(
    endpoint: URL, queryParameter: String = "q", keyHeader: String? = nil,
    keyParameter: String? = nil, key: String
  ) {
    self.endpoint = endpoint
    self.queryParameter = queryParameter
    self.keyHeader = keyHeader
    self.keyParameter = keyParameter
    self.key = key
  }

  /// 번들에서 읽는다. 하나라도 없으면 nil이고, 그때 `web.search`는 없는 능력이다.
  public static func fromBundle(_ bundle: Bundle = .main) -> WebSearchConfiguration? {
    func string(_ key: String) -> String? {
      guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return nil }
      return value
    }
    guard let raw = string("JSWebSearchEndpoint"), let endpoint = URL(string: raw),
      let key = string("JSWebSearchAPIKey")
    else { return nil }
    return WebSearchConfiguration(
      endpoint: endpoint,
      queryParameter: string("JSWebSearchQueryParameter") ?? "q",
      keyHeader: string("JSWebSearchAPIKeyHeader"),
      keyParameter: string("JSWebSearchAPIKeyParameter"),
      key: key)
  }

  public func request(query: String, limit: Int) -> URLRequest? {
    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
    var items = components?.queryItems ?? []
    items.append(URLQueryItem(name: queryParameter, value: query))
    items.append(URLQueryItem(name: "count", value: String(limit)))
    if let keyParameter { items.append(URLQueryItem(name: keyParameter, value: key)) }
    components?.queryItems = items
    guard let url = components?.url else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let keyHeader { request.setValue(key, forHTTPHeaderField: keyHeader) }
    return request
  }
}

/// 검색 결과 한 줄.
public struct WebSearchResult: Sendable, Hashable {
  public let title: String
  public let url: String
  public let snippet: String

  public init(title: String, url: String, snippet: String) {
    self.title = title
    self.url = url
    self.snippet = snippet
  }
}

/// 공급자의 JSON에서 결과 줄을 **모양으로** 찾는다.
///
/// 공급자마다 감싸는 이름이 다르다(`web.results`·`organic`·`webPages.value`). 그
/// 이름들을 목록으로 들고 있으면 공급자를 하나 바꿀 때마다 이 파일을 고쳐야 하고,
/// 목록에 없는 공급자는 조용히 0건이 된다.
///
/// 그래서 이름이 아니라 **모양**을 찾는다: 제목처럼 생긴 칸과 주소처럼 생긴 칸을
/// 가진 객체의 배열. 그 판정은 결정론적이고, 낯선 공급자에서도 성립한다.
public enum WebSearchResultParser {
  private static let titleKeys = ["title", "name", "heading"]
  private static let urlKeys = ["url", "link", "href", "displayUrl", "display_url"]
  private static let snippetKeys = [
    "description", "snippet", "content", "text", "excerpt", "summary",
  ]

  public static func parse(_ data: Data, limit: Int) -> [WebSearchResult] {
    guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
    var found: [WebSearchResult] = []
    collect(root, into: &found, limit: limit)
    return Array(found.prefix(limit))
  }

  private static func collect(
    _ node: Any, into found: inout [WebSearchResult], limit: Int
  ) {
    guard found.count < limit else { return }
    switch node {
    case let array as [Any]:
      // 배열의 원소가 결과 모양이면 그 배열이 결과 목록이다.
      for element in array {
        guard found.count < limit else { return }
        if let object = element as? [String: Any], let result = result(from: object) {
          found.append(result)
        } else {
          collect(element, into: &found, limit: limit)
        }
      }
    case let object as [String: Any]:
      // 결정론적 순서로 걷는다 — 사전의 순서는 실행마다 다르고, 그러면 같은
      // 응답이 실행마다 다른 결과 순서를 낸다.
      for key in object.keys.sorted() {
        guard found.count < limit else { return }
        if let value = object[key] { collect(value, into: &found, limit: limit) }
      }
    default:
      return
    }
  }

  private static func result(from object: [String: Any]) -> WebSearchResult? {
    guard let url = value(in: object, keys: urlKeys),
      url.hasPrefix("http"),
      let title = value(in: object, keys: titleKeys)
    else { return nil }
    return WebSearchResult(
      title: title, url: url, snippet: value(in: object, keys: snippetKeys) ?? "")
  }

  private static func value(in object: [String: Any], keys: [String]) -> String? {
    for key in keys {
      guard let match = object.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })
      else { continue }
      if let text = match.value as? String,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return text
      }
    }
    return nil
  }
}
