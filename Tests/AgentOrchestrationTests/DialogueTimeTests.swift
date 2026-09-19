import XCTest

@testable import AgentOrchestration

/// L0 — **앞차례의 줄이 언제 오간 것인지 문맥이 말한다.**
///
/// `<<<now>>>`는 지금만 말한다. 시각이 없던 동안 `"어제 얘기한 그 일정"`을 모델이
/// 짚을 근거는 문맥에 하나도 없었다 — 대화는 시간이 없는 평면이었다.
final class DialogueTimeTests: XCTestCase {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
    return calendar
  }()

  /// 시각은 **지역 시각 한 조각**이다: `2026-09-15 17:43`.
  func testStampIsALocalMinute() throws {
    let date = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 17, minute: 43)))
    XCTAssertEqual(
      ConversationContextCompiler.stamp(date, calendar: calendar), "2026-09-15 17:43")
  }

  /// 창에 실린 줄이 그 시각을 들고 간다.
  func testRenderedHistoryCarriesTheTime() throws {
    let value = DialogueHistoryWindow.render([
      .init(turnID: "a", role: "user", text: "그 일정 언제였지?", at: "2026-09-15 17:43")
    ])
    let row = try XCTUnwrap(value.split(separator: "\n").last)
    let parsed = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: String])
    XCTAssertEqual(parsed["at"], "2026-09-15 17:43")
    XCTAssertEqual(parsed["text"], "그 일정 언제였지?")
  }

  /// 시각이 없는 줄에는 **빈 칸을 싣지 않는다** — 예산은 글자로 센다.
  func testEntryWithoutATimeCarriesNoField() throws {
    let value = DialogueHistoryWindow.render([.init(turnID: "a", role: "user", text: "안녕")])
    let row = try XCTUnwrap(value.split(separator: "\n").last)
    let parsed = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: String])
    XCTAssertNil(parsed["at"])
  }

  /// 시각이 붙어도 **인코딩 뒤 예산**을 넘지 않는다.
  func testTimeStampsStayInsideTheBudget() {
    let entries = (0..<20).map {
      DialogueHistoryWindow.Entry(
        turnID: "t\($0)", role: "user", text: String(repeating: "긴 줄 ", count: 40),
        at: "2026-09-15 17:43")
    }
    let value = DialogueHistoryWindow.render(entries, characterBudget: 600)
    XCTAssertLessThanOrEqual(value.count, 600)
    for line in value.split(separator: "\n") {
      XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
    }
  }
}
