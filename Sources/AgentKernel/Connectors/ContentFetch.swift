import Foundation

/// 공개 웹 주소 하나를 **읽어도 되는가.**
///
/// 이 문이 필요한 이유는 주소의 출처다. `web.read`의 인자는 앞 단계의 검색 결과에서
/// 오고(`ResolvableArgument.url`), 검색 결과는 인터넷이 준 글이다 — 즉 **바깥이 고른
/// 주소로 이 기기가 HTTP 요청을 낸다.** 그 주소가 `192.168.0.1`이면 우리는 사용자의
/// 집 안을 긁어 모델에게 보여 주는 도구가 된다.
///
/// ## 막는 것
/// - `http`/`https` 밖의 스킴(`file:`·`ftp:`·앱 커스텀 스킴)
/// - 주소에 박힌 자격증명(`https://user:pass@host/`) — 우리가 보낼 열쇠가 아니다
/// - 루프백·링크로컬·사설 대역·CGNAT·멀티캐스트, `localhost`·`.local`·`.internal`
/// - 네 마디로 읽히지 않는 숫자 주소(`http://2130706433/`, `http://0x7f000001/`) —
///   해석이 구현마다 달라서, 그 차이가 그대로 우회로가 된다
/// - **리다이렉트의 매 홉**(`ContentFetchGate`). 첫 주소만 보면 공개 호스트가 302로
///   사설 주소를 가리키는 순간 이 문은 아무 일도 하지 않은 것이 된다
///
/// ## 막지 못하는 것 — 적어 둔다
/// 이름은 문자열로만 본다. 그래서 **이름이 사설 주소로 해석되는 경우는 통과한다.**
/// 두 가지가 섞여 있다:
///
/// 1. 처음부터 사설을 가리키는 이름(`evil.example → A 192.168.0.1`). 이쪽은 요청
///    전에 이름을 직접 해석해(`getaddrinfo`) 돌아온 **모든** 주소를 이 표로 걸면
///    막을 수 있다 — 하나라도 사설이면 거절이다.
/// 2. 해석과 연결 사이에 답이 바뀌는 경우(DNS rebinding·TOCTOU). 이쪽은 해석을
///    우리가 해도 남는다. 소켓이 실제로 연결한 주소를 봐야 하고 그 훅이
///    `URLSession`에 없다 — 막으려면 주소로 직접 요청하고 `Host` 헤더를 세우는
///    경로가 필요하고, 그때 TLS 검증과 HTTP/2 재사용을 우리가 다시 맞춘다.
public struct ContentFetchHostPolicy: Sendable {
  public init() {}

  /// 통과하면 같은 주소를 돌려준다. 막으면 **왜 막았는지**를 던진다 — "실패"
  /// 한 낱말로 접으면 사설 주소를 막은 것과 서버가 죽은 것이 같은 사실이 된다.
  public func vet(_ url: URL) throws -> URL {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      throw ContentFetchError.unsupportedScheme(url.scheme ?? "")
    }
    guard url.user == nil, url.password == nil else {
      throw ContentFetchError.credentialsInURL
    }
    guard let host = url.host, !host.isEmpty else { throw ContentFetchError.missingHost }
    let lowered = host.lowercased()
    guard !Self.isPrivate(lowered) else { throw ContentFetchError.privateHost(lowered) }
    return url
  }

  /// 이름이든 주소든 **바깥이 아닌 것**을 가린다.
  static func isPrivate(_ host: String) -> Bool {
    if host == "localhost" || host.hasSuffix(".localhost") { return true }
    if host.hasSuffix(".local") || host.hasSuffix(".internal") || host.hasSuffix(".home.arpa") {
      return true
    }
    if host.contains(":") { return isPrivateIPv6(host) }
    if let octets = Self.octets(host) { return isPrivate(octets) }
    // 숫자와 점으로만 된 이름은 주소다. 네 마디로 읽히지 않으면 거절한다 —
    // `2130706433`은 `inet_aton`에서 `127.0.0.1`이고 우리 파서에서는 이름이다.
    if host.hasPrefix("0x") { return true }
    if host.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." }) { return true }
    return false
  }

  /// 점 네 마디. 십진수 세 자리까지만 읽는다 — `0177.0.0.1`(8진수)은 여기서 이름이
  /// 되고, 숫자뿐인 이름은 위에서 거절된다.
  static func octets(_ host: String) -> [UInt8]? {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(4)
    for part in parts {
      guard !part.isEmpty, part.count <= 3,
        part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = UInt8(part)
      else { return nil }
      out.append(value)
    }
    return out
  }

  static func isPrivate(_ octets: [UInt8]) -> Bool {
    switch (octets[0], octets[1]) {
    case (0, _), (10, _), (127, _): return true  // 미지정·사설·루프백
    case (169, 254): return true  // 링크로컬
    case (172, 16...31): return true  // 사설
    case (192, 168): return true  // 사설
    case (100, 64...127): return true  // CGNAT
    case (198, 18...19): return true  // 벤치마킹
    case (224...255, _): return true  // 멀티캐스트·예약
    default: return false
    }
  }

  /// **주소로 바꿔 놓고 본다.** 글자 앞머리로 판정하면 같은 주소의 다른 표기가
  /// 전부 새 구멍이다 — `::1`은 막고 `0:0:0:0:0:0:0:1`은 통과하는 식이다.
  /// `inet_pton`은 16바이트를 돌려주므로 접두사를 숫자로 잴 수 있다.
  static func isPrivateIPv6(_ host: String) -> Bool {
    // 존 인덱스(`fe80::1%en0`)는 떼고 본다.
    let address = String(host.split(separator: "%", maxSplits: 1).first ?? "")
    var bytes = [UInt8](repeating: 0, count: 16)
    guard address.withCString({ inet_pton(AF_INET6, $0, &bytes) }) == 1 else {
      // 읽히지 않는 표기는 거절한다 — 모르는 주소로 요청을 내지 않는다.
      return true
    }
    // `::`(미지정)과 `::1`(루프백).
    if bytes[0..<15].allSatisfy({ $0 == 0 }) { return true }
    // IPv4를 품은 표기들. 품은 주소를 v4 표로 다시 잰다 — `::ffff:192.168.0.1`과
    // NAT64의 `64:ff9b::192.168.0.1`이 여기로 온다.
    if let embedded = Self.embeddedIPv4(bytes) { return Self.isPrivate(embedded) }
    switch (bytes[0], bytes[1]) {
    case (0xff, _): return true  // ff00::/8 멀티캐스트
    case (0xfc, _), (0xfd, _): return true  // fc00::/7 유니크 로컬
    case (0xfe, let second) where second & 0xc0 == 0x80: return true  // fe80::/10 링크로컬
    case (0xfe, let second) where second & 0xc0 == 0xc0: return true  // fec0::/10 사이트로컬
    default: return false
    }
  }

  /// IPv4가 실려 있으면 그 네 바이트. 매핑(`::ffff:`)·호환(`::`)·NAT64(`64:ff9b::`).
  static func embeddedIPv4(_ bytes: [UInt8]) -> [UInt8]? {
    let tail = Array(bytes[12..<16])
    if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
      return tail
    }
    if bytes[0..<12].allSatisfy({ $0 == 0 }) { return tail }
    if bytes[0] == 0x00, bytes[1] == 0x64, bytes[2] == 0xff, bytes[3] == 0x9b,
      bytes[4..<12].allSatisfy({ $0 == 0 })
    {
      return tail
    }
    return nil
  }
}

/// 읽지 못한 이유. **사유를 나눠 든다** — 막은 것과 없는 것과 못 읽은 것은 다르다.
public enum ContentFetchError: Error, Sendable, Equatable {
  case unsupportedScheme(String)
  case credentialsInURL
  case missingHost
  /// 사설·루프백·링크로컬 주소다. 이 기기의 안쪽을 읽어 주지 않는다.
  case privateHost(String)
  /// 리다이렉트가 그 문 밖을 가리켰다. **따라가지 않는다.**
  case redirectRefused(String)
  case rejected(status: Int)
  case malformedResponse
  case tooLarge(bytes: Int)
  /// 글이 아니다(PDF·이미지·압축). 여기서 멈추는 것이 정직하다 — 바이트를 글자로
  /// 읽어 넘기면 모델이 그 쓰레기에서 "사실"을 뽑는다.
  case unsupportedType(String)
  case undecodableText
  case emptyDocument

  /// 로그와 화면에 남길 한 낱말. **값은 담지 않는다**(주소·상태는 담기지 않는다).
  public var reason: String {
    switch self {
    case .unsupportedScheme: return "web.read.scheme"
    case .credentialsInURL: return "web.read.credentials"
    case .missingHost: return "web.read.host"
    case .privateHost: return "web.read.privateHost"
    case .redirectRefused: return "web.read.redirect"
    case .rejected: return "web.read.rejected"
    case .malformedResponse: return "web.read.malformed"
    case .tooLarge: return "web.read.tooLarge"
    case .unsupportedType: return "web.read.unsupportedType"
    case .undecodableText: return "web.read.undecodable"
    case .emptyDocument: return "web.read.empty"
    }
  }
}

/// 받아 온 문서 하나. **바이트와 그 바이트를 읽는 법**이 함께 온다.
///
/// 글자로 이미 옮긴 값을 들지 않는 이유는 인코딩이다. 응답 헤더의 charset을 버리고
/// UTF-8로 단정하면 EUC-KR 페이지가 물음표 벽이 되고, 그 벽에서 모델이 사실을 뽑는다.
package struct FetchedDocument: Sendable, Equatable {
  /// 리다이렉트를 따라간 **최종 주소.**
  package let url: URL
  package let mimeType: String
  package let encoding: String.Encoding
  package let bytes: Data

  package init(url: URL, mimeType: String, encoding: String.Encoding = .utf8, bytes: Data) {
    self.url = url
    self.mimeType = mimeType
    self.encoding = encoding
    self.bytes = bytes
  }
}

/// 문서 한 건의 네트워크 왕복. **시험이 이 문으로 대역을 세운다.**
///
/// 호스트에게는 열려 있지 않다(`package`). 주입된 문은 리다이렉트를 자기가 따라가고,
/// 따라간 홉은 우리 표를 지나지 않는다 — 첫 주소만 통과시키면 공개 이름이 302 하나로
/// 사설 주소를 읽게 만든다. 호스트가 조절할 것은 문이 아니라 정책이다
/// (`WebReadConfiguration`).
package typealias ContentFetchTransport = @Sendable (URL) async throws -> FetchedDocument

/// 읽기의 **조절판.** 호스트가 만지는 것은 이 값이고, 문은 코어가 만든다.
public struct WebReadConfiguration: Sendable {
  public let policy: ContentFetchHostPolicy
  public let byteLimit: Int
  public let timeout: TimeInterval

  public init(
    policy: ContentFetchHostPolicy = ContentFetchHostPolicy(),
    byteLimit: Int = ContentFetch.byteLimit,
    timeout: TimeInterval = ContentFetch.timeout
  ) {
    self.policy = policy
    self.byteLimit = byteLimit
    self.timeout = timeout
  }

  public static let standard = WebReadConfiguration()
}

/// 공개 웹에서 문서 하나를 받아 온다.
///
/// `ConnectorHTTP`를 쓰지 않는 이유는 두 가지다. 그 문은 `accessToken`을 요구하고
/// (공개 웹에는 열쇠가 없다), 리다이렉트를 홉마다 검사할 자리가 없다 — 그 검사를
/// 거기에 넣으면 공급자 API 호출 전부가 웹 정책을 지나간다.
public enum ContentFetch {
  /// 받을 바이트 상한. 넘으면 **자르지 않고 거절한다** — 잘린 HTML은 잘린 문장이
  /// 아니라 닫히지 않은 태그 무덤이고, 그 무덤에서 뽑은 사실은 문서의 사실이 아니다.
  public static let byteLimit = 2 * 1024 * 1024
  public static let timeout: TimeInterval = 15

  package static func standard(
    _ configuration: WebReadConfiguration = .standard,
    session: URLSession = .shared
  ) -> ContentFetchTransport {
    let policy = configuration.policy
    let byteLimit = configuration.byteLimit
    let timeout = configuration.timeout
    return { url in
      let target = try policy.vet(url)
      var request = URLRequest(url: target)
      request.timeoutInterval = timeout
      // 쿠키를 들고 가지 않는다. 읽기는 익명이어야 한다 — 로그인된 세션으로 읽으면
      // 사용자만 볼 수 있는 페이지가 근거가 된다.
      request.httpShouldHandleCookies = false
      // 같은 앱이 같은 클라이언트로 부른다. UA를 두 벌 두면 한쪽만 고치게 된다.
      request.setValue(WebSearchHTTP.userAgent, forHTTPHeaderField: "User-Agent")
      request.setValue(
        "text/html,application/xhtml+xml,text/plain;q=0.8", forHTTPHeaderField: "Accept")

      let gate = ContentFetchGate(policy: policy, byteLimit: byteLimit)
      let received: (Data, URLResponse)
      do {
        received = try await session.data(for: request, delegate: gate)
      } catch {
        // 문에서 끊은 요청은 `URLError.cancelled`로 돌아온다. **끊은 이유가 사실이다.**
        if let refusal = gate.refusal { throw refusal }
        throw error
      }
      // 리다이렉트를 막으면 URLSession은 그 3xx 응답을 **성공으로** 돌려준다.
      if let refusal = gate.refusal { throw refusal }

      guard let http = received.1 as? HTTPURLResponse else {
        throw ContentFetchError.malformedResponse
      }
      guard (200..<300).contains(http.statusCode) else {
        throw ContentFetchError.rejected(status: http.statusCode)
      }
      guard received.0.count <= byteLimit else {
        throw ContentFetchError.tooLarge(bytes: received.0.count)
      }
      return FetchedDocument(
        url: http.url ?? target,
        mimeType: (http.value(forHTTPHeaderField: "Content-Type") ?? http.mimeType ?? "")
          .lowercased(),
        encoding: Self.encoding(http.textEncodingName),
        bytes: received.0)
    }
  }

  /// 헤더의 charset 이름을 인코딩으로. 모르는 이름은 UTF-8로 본다 — 그 뒤에
  /// `WebReadTool`이 해독 실패를 한 번 더 받아 낸다.
  package static func encoding(_ name: String?) -> String.Encoding {
    guard let name else { return .utf8 }
    let converted = CFStringConvertIANACharSetNameToEncoding(name as CFString)
    guard converted != kCFStringEncodingInvalidId else { return .utf8 }
    return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(converted))
  }
}

/// 리다이렉트 홉과 응답 크기를 **요청이 진행되는 중에** 막는다.
///
/// 정책을 첫 주소에만 적용하면 공개 호스트가 302 하나로 사설 주소를 읽게 만든다.
/// 크기를 다 받은 뒤에 재면 이미 받은 것이고 — 받은 것은 메모리에 있다.
private final class ContentFetchGate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let policy: ContentFetchHostPolicy
  private let byteLimit: Int
  private let lock = NSLock()
  private var recorded: ContentFetchError?

  init(policy: ContentFetchHostPolicy, byteLimit: Int) {
    self.policy = policy
    self.byteLimit = byteLimit
    super.init()
  }

  /// **처음 막은 이유**를 든다. 뒤에 따라오는 취소 오류는 결과이지 이유가 아니다.
  var refusal: ContentFetchError? {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  private func record(_ error: ContentFetchError) {
    lock.lock()
    if recorded == nil { recorded = error }
    lock.unlock()
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let url = request.url else {
      record(.missingHost)
      completionHandler(nil)
      return
    }
    do {
      _ = try policy.vet(url)
      completionHandler(request)
    } catch let error as ContentFetchError {
      record(error)
      completionHandler(nil)
    } catch {
      record(.redirectRefused(url.absoluteString))
      completionHandler(nil)
    }
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    // 길이를 모르는 응답(chunked)은 여기서 재지 못한다 — 받은 뒤 한 번 더 잰다.
    if response.expectedContentLength > Int64(byteLimit) {
      record(.tooLarge(bytes: Int(response.expectedContentLength)))
      completionHandler(.cancel)
      return
    }
    completionHandler(.allow)
  }
}
