import AgentKernel
import XCTest

@testable import AgentOrchestration

/// **L0: 네트워크 0회.** 문(`ContentFetchTransport`)에 대역을 세운다.
///
/// 여기서 보는 것은 세 가지다: 바깥이 준 주소를 어디까지 거절하는가, 받은 바이트가
/// 어떤 줄이 되는가, 그 줄이 다음 단계의 인자가 되는가.
final class WebReadTests: XCTestCase {

  // MARK: 주소 심사

  func testPrivateAndLocalAddressesAreRefused() throws {
    // 검색 결과는 인터넷이 준 글이고, 그 글이 고른 주소로 이 기기가 요청을 낸다.
    let refused: [(String, String)] = [
      ("http://localhost/admin", "web.read.privateHost"),
      ("http://127.0.0.1:8080/", "web.read.privateHost"),
      ("http://0.0.0.0/", "web.read.privateHost"),
      ("http://10.0.0.5/", "web.read.privateHost"),
      ("http://172.20.1.1/", "web.read.privateHost"),
      ("http://192.168.0.1/", "web.read.privateHost"),
      ("http://169.254.169.254/latest/meta-data/", "web.read.privateHost"),
      ("http://100.100.0.1/", "web.read.privateHost"),
      ("http://[::1]/", "web.read.privateHost"),
      ("http://[fd00::1]/", "web.read.privateHost"),
      ("http://[fe80::1%25en0]/", "web.read.privateHost"),
      ("http://[::ffff:127.0.0.1]/", "web.read.privateHost"),
      ("http://nas.local/", "web.read.privateHost"),
      ("http://wiki.internal/", "web.read.privateHost"),
      // 네 마디로 읽히지 않는 숫자 주소. `inet_aton`에서는 127.0.0.1이다.
      ("http://2130706433/", "web.read.privateHost"),
      ("http://0x7f000001/", "web.read.privateHost"),
      ("http://017700000001/", "web.read.privateHost"),
      ("file:///etc/passwd", "web.read.scheme"),
      ("ftp://example.com/x", "web.read.scheme"),
      ("https://user:secret@example.com/", "web.read.credentials"),
    ]
    let policy = ContentFetchHostPolicy()
    for (raw, reason) in refused {
      let url = try XCTUnwrap(URL(string: raw), raw)
      do {
        _ = try policy.vet(url)
        XCTFail("통과시켰다: \(raw)")
      } catch let error as ContentFetchError {
        XCTAssertEqual(error.reason, reason, raw)
      }
    }
  }

  func testPublicAddressesPass() throws {
    for raw in [
      "https://www.apple.com/newsroom/", "http://example.com/a?b=c",
      "https://192.0.2.10/", "https://[2606:4700::1111]/",
    ] {
      let url = try XCTUnwrap(URL(string: raw), raw)
      XCTAssertNoThrow(try ContentFetchHostPolicy().vet(url), raw)
    }
  }

  // MARK: 바이트 → 줄

  func testHTMLBecomesBodyAndTitle() async throws {
    let receipt = try await read(
      "https://example.com/pcc",
      document: Self.html(
        """
        <h1>PCC가 서버로 확장됐다</h1>
        <p>애플은 서버 추론의 검증 가능성을 이야기한다.</p>
        <script>var tracker = 1;</script>
        """))

    let row = try XCTUnwrap(CapabilitySourceRow.rows(in: receipt.details).first)
    XCTAssertEqual(row.title, "PCC가 서버로 확장됐다")
    XCTAssertTrue(row.body.contains("검증 가능성"), "본문이 비었다: \(row.body)")
    XCTAssertFalse(row.body.contains("tracker"), "스크립트가 본문으로 올라왔다")
    XCTAssertEqual(row.identifier, "https://example.com/pcc")
    XCTAssertEqual(receipt.coverage.first?.state, .complete)
    XCTAssertEqual(receipt.coverage.first?.readCount, 1)
  }

  /// 줄의 `body`가 다음 단계의 인자가 되는가. 이 줄 모양이 틀리면 읽기는 성공하고
  /// 요약은 되물음으로 끝난다.
  func testBodyFeedsSourceTextSlot() async throws {
    let receipt = try await read(
      "https://example.com/pcc",
      document: Self.html("<p>애플은 서버 추론의 검증 가능성을 이야기한다.</p>"))

    let resolved = TurnRuntime.resolvedValue(for: "sourceText", in: [receipt])
    XCTAssertEqual(resolved?.textValue?.contains("검증 가능성"), true, "원문 자리가 비었다")
  }

  /// 리다이렉트를 따라간 **최종 주소**가 식별자다. 첫 주소를 적으면 근거의 출처가
  /// 사용자가 열 수 없는 주소가 된다.
  func testIdentifierIsTheFinalURL() async throws {
    let receipt = try await read(
      "https://example.com/short",
      document: Self.html("<p>본문</p>", url: "https://news.example.org/full-article"))

    let row = try XCTUnwrap(CapabilitySourceRow.rows(in: receipt.details).first)
    XCTAssertEqual(row.identifier, "https://news.example.org/full-article")
  }

  func testBinaryDocumentIsRefusedInsteadOfRead() async throws {
    do {
      _ = try await read(
        "https://example.com/paper.pdf",
        document: FetchedDocument(
          url: URL(string: "https://example.com/paper.pdf")!,
          mimeType: "application/pdf", bytes: Data([0x25, 0x50, 0x44, 0x46])))
      XCTFail("PDF를 글로 읽었다")
    } catch let error as ActionError {
      XCTAssertEqual(error, .failed(reason: "web.read.unsupportedType"))
    }
  }

  func testPrivateHostIsRefusedBeforeTheRequestIsMade() async throws {
    // 문에 닿기 전에 막힌다 — 대역은 부르면 실패하도록 세운다.
    let tool = WebReadTool { _ in
      XCTFail("사설 주소로 요청을 냈다")
      throw ContentFetchError.malformedResponse
    }
    do {
      _ = try await tool.perform(
        ActionRequest(
          capability: .webRead, arguments: ["url": .text("http://192.168.1.1/")],
          origin: .modelPlan, accountID: "acct"))
      XCTFail("사설 주소를 읽었다")
    } catch let error as ActionError {
      XCTAssertEqual(error, .failed(reason: "web.read.privateHost"))
    }
  }

  /// 자른 사실은 **범위에 적는다.** 조용히 자르면 차례가 문서를 다 읽은 것처럼 말한다.
  func testTruncationIsRecordedInCoverage() async throws {
    let long = String(repeating: "애플은 서버 추론의 검증 가능성을 이야기한다. ", count: 3_000)
    XCTAssertGreaterThan(long.count, WebReadTool.characterLimit)

    let receipt = try await read(
      "https://example.com/long", document: Self.html("<p>\(long)</p>"))
    let row = try XCTUnwrap(CapabilitySourceRow.rows(in: receipt.details).first)
    XCTAssertEqual(row.body.count, WebReadTool.characterLimit)
    let coverage = try XCTUnwrap(receipt.coverage.first)
    XCTAssertEqual(coverage.state, .partial)
    XCTAssertTrue(coverage.truncated)
    XCTAssertEqual(coverage.reason, .truncation)
  }

  /// 헤더가 시킨 charset으로 읽는다. UTF-8로 단정하면 EUC-KR 페이지가 물음표 벽이
  /// 되고, 그 벽에서 기기 모델이 "사실"을 뽑는다.
  func testDeclaredCharsetIsHonored() async throws {
    let encoding = ContentFetch.encoding("euc-kr")
    XCTAssertNotEqual(encoding, String.Encoding.utf8, "euc-kr를 인코딩으로 옮기지 못했다")
    XCTAssertEqual(ContentFetch.encoding(nil), String.Encoding.utf8)
    XCTAssertEqual(ContentFetch.encoding("nonsense-charset"), String.Encoding.utf8)

    let source = "애플은 검증 가능성을 이야기한다"
    let bytes = try XCTUnwrap(("<p>" + source + "</p>").data(using: encoding))
    let receipt = try await read(
      "https://example.com/euckr",
      document: FetchedDocument(
        url: URL(string: "https://example.com/euckr")!,
        mimeType: "text/html; charset=euc-kr", encoding: encoding, bytes: bytes))

    let row = try XCTUnwrap(CapabilitySourceRow.rows(in: receipt.details).first)
    XCTAssertEqual(row.body, source, "선언한 charset으로 읽지 않았다")
  }

  // MARK: 대역

  private static func html(_ body: String, url: String = "https://example.com/pcc")
    -> FetchedDocument
  {
    FetchedDocument(
      url: URL(string: url)!, mimeType: "text/html; charset=utf-8",
      bytes: Data("<html><body>\(body)</body></html>".utf8))
  }

  private func read(_ url: String, document: FetchedDocument) async throws -> ActionReceipt {
    let tool = WebReadTool { _ in document }
    return try await tool.perform(
      ActionRequest(
        capability: .webRead, arguments: ["url": .text(url)],
        origin: .modelPlan, accountID: "acct"))
  }
}
