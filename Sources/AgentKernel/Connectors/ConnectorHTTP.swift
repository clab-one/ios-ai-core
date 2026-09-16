import Foundation
import OSLog

/// 공급자 호출의 공통 규칙 — 재시도·속도 제한·오류 정규화가 한 자리에 있다.
///
/// OpenWorker에서 가져온 것은 이 **정책들**이다(pagination·rate limit·retry·
/// error normalization). 가져오지 않은 것은 그 프로젝트의 파이썬 에이전트 루프와
/// 모델 공급자 UI다 — 그 둘은 우리 구조(코드가 orchestration을 소유한다)와 반대다.
public struct ConnectorHTTP: Sendable {
  private static let log = AgentHost.logger("connector-http")

  private let session: URLSession
  /// 읽기 요청의 재시도 횟수. **쓰기는 재시도하지 않는다**(`send`).
  private let readRetries: Int

  public init(session: URLSession = .shared, readRetries: Int = 2) {
    self.session = session
    self.readRetries = readRetries
  }

  /// 읽기. 429/5xx는 `Retry-After`를 존중해 물러난 뒤 다시 시도한다.
  public func get(
    _ url: URL, accessToken: String, headers: [String: String] = [:]
  ) async throws -> Data {
    var attempt = 0
    while true {
      do {
        return try await perform(
          request(url: url, method: "GET", accessToken: accessToken, headers: headers))
      } catch ConnectorError.throttled(let retryAfter) where attempt < readRetries {
        attempt += 1
        try? await Task.sleep(for: .seconds(min(retryAfter, 8)))
      } catch ConnectorError.rejected(let status)
        where status >= 500 && attempt < readRetries
      {
        attempt += 1
        try? await Task.sleep(for: .seconds(pow(2, Double(attempt))))
      }
    }
  }

  /// 쓰기. **한 번만 보낸다.**
  ///
  /// 응답을 받지 못한 전송은 `sendOutcomeUnknown`이다. 자동으로 다시 보내면
  /// 사용자가 모르는 두 번째 메일이 나간다 — 재시도는 사람이 결정한다.
  public func post(
    _ url: URL, accessToken: String, body: Data, contentType: String = "application/json",
    headers: [String: String] = [:]
  ) async throws -> Data {
    var merged = headers
    merged["Content-Type"] = contentType
    var urlRequest = request(
      url: url, method: "POST", accessToken: accessToken, headers: merged)
    urlRequest.httpBody = body
    do {
      return try await perform(urlRequest)
    } catch let error as ConnectorError {
      throw error
    } catch {
      throw ConnectorError.sendOutcomeUnknown
    }
  }

  private func request(
    url: URL, method: String, accessToken: String, headers: [String: String]
  ) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    // 토큰은 헤더에만 실린다. URL에 실으면 로그·리다이렉트를 타고 새어 나간다.
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    request.timeoutInterval = 20
    return request
  }

  private func perform(_ request: URLRequest) async throws -> Data {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw ConnectorError.malformedResponse
    }
    switch http.statusCode {
    case 200..<300:
      return data
    case 401, 403:
      // 어느 공급자인지는 호출부가 안다 — 여기서는 상태만 말한다.
      throw ConnectorError.rejected(status: http.statusCode)
    case 429:
      let retryAfter =
        (http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)) ?? 2
      Self.log.info("connector throttled status=429")
      throw ConnectorError.throttled(retryAfter: retryAfter)
    default:
      // 본문을 로그에 남기지 않는다 — 메일 제목·주소가 오류 본문에 실려 온다.
      Self.log.error("connector rejected status=\(http.statusCode, privacy: .public)")
      throw ConnectorError.rejected(status: http.statusCode)
    }
  }

  /// 목록 한 페이지. 공급자마다 이름이 다른 커서를 한 낱말로 정규화한다.
  public struct Page<Element: Sendable>: Sendable {
    public let elements: [Element]
    public let nextCursor: String?
    public init(elements: [Element], nextCursor: String?) {
      self.elements = elements
      self.nextCursor = nextCursor
    }
  }
}
