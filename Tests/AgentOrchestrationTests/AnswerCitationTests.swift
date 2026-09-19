import XCTest

@testable import AgentOrchestration

/// L0 — **답의 줄마다 어느 근거에서 왔는지 말한다.**
///
/// 출처 칩이 여섯 개 서 있어도 사용자는 어느 것이 이 문장의 근거인지 알 수 없었다.
/// 번호는 모델이 붙이고, 호스트는 **가리키는 것이 없는 번호를 버린다** — 아무것도
/// 가리키지 않는 각주는 근거가 아니라 장식이다.
@available(iOS 26.0, *)
final class AnswerCitationTests: XCTestCase {
  private func point(_ text: String, _ evidence: Int) -> GeneratedFinalAnswer.Point {
    GeneratedFinalAnswer.Point(text: text, evidence: evidence)
  }

  /// 줄마다 번호가 따라간다. `0`은 대화에서 온 줄이다 — 번호를 두지 않는다.
  func testEachLineKeepsTheEvidenceNumberItCameFrom() {
    let points = TurnFinalizer.points(
      [point("M4 Max는 16코어 CPU예요", 2), point("가격은 기억하고 계신 대로예요", 0)],
      relevant: [1, 2], evidenceCount: 3)
    XCTAssertEqual(points.map(\.text), ["M4 Max는 16코어 CPU예요", "가격은 기억하고 계신 대로예요"])
    XCTAssertEqual(points.map(\.evidence), [2, nil])
  }

  /// **문맥에 실린 것보다 큰 번호는 버린다.** 모델이 센 것과 우리가 실은 것이
  /// 어긋난 경우이고, 그 번호는 아무것도 가리키지 않는다.
  func testNumberBeyondTheEvidenceIsDropped() {
    let points = TurnFinalizer.points(
      [point("아홉 번째 근거에서 왔다고 한다", 9)], relevant: [], evidenceCount: 3)
    XCTAssertEqual(points.map(\.evidence), [nil])
    XCTAssertEqual(points.map(\.text), ["아홉 번째 근거에서 왔다고 한다"])
  }

  /// **같은 답 안의 자기모순도 버린다.** 모델이 `relevant`에서 맞다고 고르지 않은
  /// 근거를 한 줄이 가리키면, 그 번호를 세우는 일은 답과 무관한 출처를 근거로
  /// 보여 주는 일이다.
  func testNumberOutsideTheModelsOwnRelevantListIsDropped() {
    let points = TurnFinalizer.points(
      [point("첫 근거에서 왔다", 1), point("세 번째 근거에서 왔다", 3)],
      relevant: [1], evidenceCount: 3)
    XCTAssertEqual(points.map(\.evidence), [1, nil])
  }

  /// 빈 줄은 답이 아니다.
  func testBlankLinesAreDropped() {
    XCTAssertEqual(
      TurnFinalizer.points(
        [point("   ", 1), point("\n", 0), point("남는 줄", 1)],
        relevant: [1], evidenceCount: 1
      ).map(\.text), ["남는 줄"])
  }

  /// 표는 한 장이 한 덩이다 — 세 줄로 자르면 행 하나만 남는다(실기 2026-09-18).
  /// 번호가 붙어도 그 상한은 그대로다.
  @MainActor
  func testTablesStillSurviveTheClamp() {
    let table = (0..<9).map { AnswerPoint(text: "| 행 \($0) |", evidence: 1) }
    XCTAssertEqual(TurnRuntime.clamped(table).count, 9)
    let prose = (0..<9).map { AnswerPoint(text: "문장 \($0)", evidence: nil) }
    XCTAssertEqual(TurnRuntime.clamped(prose).count, 3)
  }
}
