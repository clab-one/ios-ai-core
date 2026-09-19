import XCTest

@testable import AgentKernel

/// L0 — **상한은 받는 동안 세어져야 한다.**
///
/// 코드 리뷰 2026-09-18 P1: 문은 `session.data(for:delegate:)`로 받고 있었다. 그
/// API는 전송이 **끝난 뒤** 한 덩이로 돌려주고 완료 핸들러가 본문을 소유하므로
/// `didReceive data:`가 불리지 않는다 — 즉 바이트를 세는 코드가 한 번도 돌지
/// 않았다. 공격자가 흘리는 500 MB는 전부 메모리에 올라온 뒤에 "너무 큼"이 됐다.
///
/// 이 시험은 그 사실을 **끊긴 지점**으로 본다: 16 MiB를 흘리는 서버에 2 MiB
/// 상한으로 붙고, 서버가 16 MiB를 다 보내지 못했는지 센다.
final class StreamingLimitTests: XCTestCase {
  override func tearDown() {
    ChunkedProtocol.reset()
    super.tearDown()
  }

  /// 길이를 **모르는** 응답(chunked)에서도 상한이 뜻을 가진다.
  func testUnknownLengthBodyIsCutWhileArriving() async throws {
    ChunkedProtocol.reset()
    ChunkedProtocol.chunkSize = 256 * 1024
    ChunkedProtocol.chunks = 64  // 16 MiB

    let limit = 2 * 1024 * 1024
    let transport = ContentFetch.standard(
      WebReadConfiguration(byteLimit: limit), session: Self.stubSession())
    do {
      _ = try await transport(URL(string: "https://93.184.216.34/flood")!)
      XCTFail("상한을 넘긴 본문이 통과했다")
    } catch let error as ContentFetchError {
      guard case .tooLarge(let bytes) = error else {
        return XCTFail("사유가 다르다: \(error)")
      }
      // 상한 + 마지막 덩이 하나가 메모리에 남을 수 있는 최대치다.
      XCTAssertGreaterThan(bytes, limit)
      XCTAssertLessThanOrEqual(bytes, limit + ChunkedProtocol.chunkSize)
    }
    // **다 받은 뒤에 거절한 것이 아니다.** 서버는 보내던 중에 끊겼다.
    XCTAssertLessThan(
      ChunkedProtocol.sent, ChunkedProtocol.chunks,
      "16 MiB를 모두 받은 뒤에 거절했다(= 상한이 자원의 한계가 아니다)")
  }

  /// 길이를 **아는** 응답은 선언된 길이로 거절한다 — 본문을 다 받아 볼 이유가 없다.
  func testDeclaredLengthIsRefusedByTheHeader() async throws {
    ChunkedProtocol.reset()
    ChunkedProtocol.declaredLength = 8 * 1024 * 1024
    ChunkedProtocol.chunkSize = 64 * 1024
    ChunkedProtocol.chunks = 128

    let transport = ContentFetch.standard(
      WebReadConfiguration(byteLimit: 2 * 1024 * 1024), session: Self.stubSession())
    do {
      _ = try await transport(URL(string: "https://93.184.216.34/known")!)
      XCTFail("길이를 아는 큰 본문이 통과했다")
    } catch let error as ContentFetchError {
      XCTAssertEqual(error, .tooLarge(bytes: 8 * 1024 * 1024), "선언된 길이로 거절하지 않았다")
    }
    XCTAssertLessThan(ChunkedProtocol.sent, ChunkedProtocol.chunks, "8 MiB를 다 받았다")
  }

  /// 상한 안의 본문은 그대로 온다 — 문이 정상 경로를 막지 않는지 본다.
  func testSmallBodyArrivesWhole() async throws {
    ChunkedProtocol.reset()
    ChunkedProtocol.chunkSize = 16 * 1024
    ChunkedProtocol.chunks = 4  // 64 KiB

    let transport = ContentFetch.standard(
      WebReadConfiguration(byteLimit: 2 * 1024 * 1024), session: Self.stubSession())
    let document = try await transport(URL(string: "https://93.184.216.34/small")!)
    XCTAssertEqual(document.bytes.count, 4 * 16 * 1024)
  }

  private static func stubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ChunkedProtocol.self]
    return URLSession(configuration: configuration)
  }
}

/// 덩이로 흘리는 서버. **끊겼는지**를 센다.
///
/// 멈춤 표시는 **인스턴스의 것**이다. 정적 값으로 두면 앞 시험에서 취소된
/// 작업의 반복이 다음 시험의 `reset()`에 되살아나 죽은 클라이언트로 계속 밀어
/// 넣고, 그 사이 다음 작업은 시작조차 못 한다(실측: 15초 타임아웃).
final class ChunkedProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  private static var sentCount = 0
  nonisolated(unsafe) static var chunkSize = 64 * 1024
  nonisolated(unsafe) static var chunks = 8
  nonisolated(unsafe) static var declaredLength: Int?

  private let stopLock = NSLock()
  private var stopped = false

  static func reset() {
    lock.lock()
    sentCount = 0
    declaredLength = nil
    lock.unlock()
  }

  static var sent: Int {
    lock.lock()
    defer { lock.unlock() }
    return sentCount
  }

  private var isStopped: Bool {
    stopLock.lock()
    defer { stopLock.unlock() }
    return stopped
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let url = request.url ?? URL(string: "https://93.184.216.34/")!
    var headers = ["Content-Type": "text/html; charset=utf-8"]
    if let declared = Self.declaredLength { headers["Content-Length"] = String(declared) }
    let response = HTTPURLResponse(
      url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

    let chunk = Data(repeating: 0x61, count: Self.chunkSize)
    for _ in 0..<Self.chunks {
      if isStopped { return }
      client?.urlProtocol(self, didLoad: chunk)
      Self.lock.lock()
      Self.sentCount += 1
      Self.lock.unlock()
      // 문이 `cancel`을 부를 틈을 준다. 한 덩이도 쉬지 않고 밀어 넣으면
      // 이 시험은 취소를 관측할 수 없다.
      Thread.sleep(forTimeInterval: 0.002)
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {
    stopLock.lock()
    stopped = true
    stopLock.unlock()
  }
}
