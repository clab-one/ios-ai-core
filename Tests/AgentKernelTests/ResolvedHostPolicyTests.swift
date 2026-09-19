import XCTest

@testable import AgentKernel

/// L0 — **이름이 어디를 가리키는지 요청 전에 본다.**
///
/// 코드 리뷰 2026-09-18 P1: 문이 글자만 봤다. 그래서 `evil.example → A 192.168.0.1`
/// 처럼 공개 이름이 사설 주소로 해석되는 경우가 통과했고, 그 경로는 사용자의 LAN을
/// HTTP oracle로 쓰는 길이다.
///
/// 네트워크 없이 확인할 수 있는 것만 본다: 해석 함수가 이름을 주소로 바꾸는가,
/// 그 주소가 표를 지나는가, 그리고 **풀리지 않는 이름으로는 나가지 않는가.**
final class ResolvedHostPolicyTests: XCTestCase {
  private let policy = ContentFetchHostPolicy()

  /// 이름을 해석하면 주소가 나온다. `localhost`는 루프백이므로 표가 잡는다.
  func testResolutionReturnsAddressesThatThePolicyJudges() throws {
    let addresses = try XCTUnwrap(
      ContentFetchHostPolicy.resolve("localhost"), "이름을 해석하지 못했다")
    XCTAssertFalse(addresses.isEmpty)
    XCTAssertTrue(
      addresses.allSatisfy { ContentFetchHostPolicy.isPrivate($0) },
      "루프백을 공개 주소로 읽었다: \(addresses)")
  }

  /// **풀리지 않는 이름으로는 요청을 내지 않는다.** 증명하지 못한 주소는 거절이다.
  func testUnresolvableNameIsRefusedInsteadOfAttempted() {
    let url = URL(string: "https://mori-no-such-host.invalid/page")!
    do {
      _ = try policy.vetResolved(url)
      XCTFail("풀리지 않는 이름으로 나갔다")
    } catch let error as ContentFetchError {
      XCTAssertEqual(error, .unresolvableHost("mori-no-such-host.invalid"))
      XCTAssertEqual(error.reason, "web.read.unresolved")
    } catch {
      XCTFail("사유가 없다: \(error)")
    }
  }

  /// 주소 표기는 **다시 해석하지 않는다.** 위 표가 이미 판정했다.
  func testAddressLiteralsSkipResolution() throws {
    XCTAssertEqual(
      try policy.vetResolved(URL(string: "https://93.184.216.34/page")!).host, "93.184.216.34")
    for blocked in ["https://192.168.0.1/", "https://[::1]/", "http://127.0.0.1:8080/"] {
      XCTAssertThrowsError(
        try policy.vetResolved(URL(string: blocked)!), "사설 주소가 통과했다: \(blocked)")
    }
  }
}
