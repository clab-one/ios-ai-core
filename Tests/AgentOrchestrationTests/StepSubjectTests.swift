import AgentKernel
import XCTest

@testable import AgentOrchestration

/// L0 — 단계 줄이 말하는 **대상**은 사람이 읽는 글자여야 한다.
///
/// 실기 2026-09-19: 위키백과 주소를 읽은 단계의 곁글이
/// `ko.wikipedia.org · %EA%B2%80%EC%83%89_%EC%A6%9D%E…`였다. 주소는 퍼센트
/// 인코딩으로 오는데 그 상태로 60자에서 잘려, 조각난 `%E…`는 화면에서도 다시
/// 풀 수 없었다.
@MainActor
final class StepSubjectTests: XCTestCase {
  func testEncodedURLBecomesReadableBeforeItIsShortened() {
    let subject = TurnRuntime.subject(of: [
      "url": .text(
        "https://ko.wikipedia.org/wiki/%EA%B2%80%EC%83%89_%EC%A6%9D%EA%B0%95_%EC%83%9D%EC%84%B1")
    ])
    XCTAssertFalse(subject.contains("%"), "기계의 글자가 남았다: \(subject)")
    XCTAssertTrue(subject.contains("검색_증강_생성"), "주소의 뜻이 사라졌다: \(subject)")
  }

  /// 짧은 값은 그대로다 — 이 자리는 줄이는 곳이 아니라 고르는 곳이다.
  func testShortSubjectIsUntouched() {
    XCTAssertEqual(TurnRuntime.subject(of: ["title": .text("치과 예약")]), "치과 예약")
  }

  /// 푼 뒤에도 긴 값은 줄인다.
  func testLongSubjectIsStillShortened() {
    let long = String(repeating: "가", count: 80)
    let subject = TurnRuntime.subject(of: ["text": .text(long)])
    XCTAssertEqual(subject.count, 61, "60자 + 말줄임표가 아니다: \(subject.count)")
    XCTAssertTrue(subject.hasSuffix("…"))
  }
}
