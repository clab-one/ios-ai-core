import AgentKernel
import Foundation

/// 계획을 묻지 않고 끝낼 수 있는 차례를 **문 앞에서 가른다**
/// (`docs/AGENT_RUNTIME_DESIGN.ko.md` §책임 경계·§EscalationPolicy).
///
/// 오늘은 모든 차례가 PCC 계획 호출 하나를 지난다. "다음 일정 뭐야?"에 그 호출을
/// 쓰는 것은 GPU로 `2 + 2`를 계산하는 일이다. 이 문은 그런 차례에서 **모델을
/// 아예 부르지 않는다.**
///
/// ## 이 문이 지키는 경계
///
/// 1. **읽기 전용만.** 돌려주는 단계의 능력은 `.observes`여야 한다. 자연어
///    낱말로 쓰기를 확정하지 않는다는 금지(`docs` §입력과 hard rules)는 그대로다 —
///    `"내일 일정 만들어줘"`는 이 문을 지나지 못하고 계획 경로로 간다.
/// 2. **인자는 기기에서만 온다.** 시각은 차례의 기준 시각과 달력이 준다. 모델이
///    채운 값도, 문장에서 긁어낸 자유 문자열도 인자가 되지 않는다.
/// 3. **모르면 통과시킨다.** 맞지 않으면 `nil`이고, 그 차례는 기존 계획 경로를
///    그대로 탄다. 이 문의 오판 비용은 "PCC를 한 번 더 부른다"여야 하고,
///    "사용자가 말한 일을 못 한다"가 되면 안 된다.
///
/// 규칙 표를 늘릴 때마다 위 셋을 다시 본다. 특히 2번 — 문장에서 값을 긁기
/// 시작하는 순간 이 문은 파서가 되고, 파서의 오판은 조용한 오답이 된다.
public enum IntentGate {
  /// 결정론으로 잡은 차례 하나.
  public struct Route: Sendable, Equatable {
    /// 바로 실행할 단계들. 전부 읽기 전용이다.
    public let steps: [PlannedStep]
    /// 어떤 규칙이 잡았는가. 계측에 남는다 — 이유 없는 우회는 버그로 읽는다.
    public let reason: String
  }

  /// 이 문을 지나면 안 되는 낱말. **쓰기를 시키는 동사**다.
  ///
  /// `"내일 일정"`과 `"내일 일정 만들어줘"`는 같은 명사를 들고 서로 다른 일을
  /// 말한다. 명사만 보고 읽기로 확정하면 만들어 달라는 요청에 목록을 돌려준다.
  private static let writeVerbs = [
    "만들", "추가", "등록", "잡아", "생성", "옮겨", "변경", "수정", "바꿔", "지워", "삭제",
    "취소", "보내", "알려줘야", "예약해", "create", "add", "schedule", "move", "delete",
    "cancel", "remove", "send", "update",
  ]

  /// 일정 읽기를 가리키는 명사.
  private static let calendarNouns = ["일정", "스케줄", "약속", "calendar", "event", "schedule"]

  /// 이 차례를 결정론으로 끝낼 수 있는가.
  ///
  /// - Parameters:
  ///   - input: 사용자가 쓴 문장 그대로.
  ///   - scope: 이번 차례에 실제로 등록된 능력. 손이 없는 능력으로 길을 만들지 않는다.
  ///   - now: 차례의 기준 시각(`TurnContextSnapshot.referenceTime`).
  ///   - calendar: 차례의 달력. 하루 경계를 기기 시간대로 잡는다.
  /// 문의 판정. **왜 올라갔는지까지 값으로 돌려준다** — 이유 없는 승격은 계측에서
  /// 버그로 읽는다(설계 §EscalationPolicy).
  public enum Decision: Sendable, Equatable {
    case route(Route)
    case escalate(reason: String)

    public var route: Route? {
      if case .route(let value) = self { return value }
      return nil
    }
  }

  public static func route(
    input: String, scope: CapabilityScope, now: Date, calendar: Calendar
  ) -> Route? {
    decide(input: input, scope: scope, now: now, calendar: calendar).route
  }

  public static func decide(
    input: String, scope: CapabilityScope, now: Date, calendar: Calendar
  ) -> Decision {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return .escalate(reason: "empty") }
    guard text.count <= maximumInputCharacters else { return .escalate(reason: "tooLong") }
    let lowered = text.lowercased()
    guard !writeVerbs.contains(where: { lowered.contains($0) }) else {
      // 쓰기 동사가 섞였다. 이 문은 읽기만 통과시키므로 계획 경로가 판단한다.
      return .escalate(reason: "writeVerb")
    }
    guard calendarNouns.contains(where: { lowered.contains($0) }) || asksForNextEvent(lowered)
    else { return .escalate(reason: "unmatched") }
    // 명사는 맞는데 손이 없다. 숨기지 않고 사유로 남긴다 — 이 값이 자주 보이면
    // 등록이 빠진 것이지 문장이 이상한 것이 아니다.
    guard scope.contains(.calendarSearch) else { return .escalate(reason: "capabilityMissing") }

    if let window = dayWindow(lowered, now: now, calendar: calendar) {
      return .route(
        Route(
          steps: [calendarStep(from: window.start, to: window.end, limit: 20)],
          reason: window.reason))
    }
    if asksForNextEvent(lowered) {
      // 다음 한 건. 창은 일주일로 둔다 — 그보다 먼 일정을 "다음"이라고 부르면
      // 사람은 자기가 물은 것과 다른 답을 받는다.
      let end = calendar.date(byAdding: .day, value: 7, to: now) ?? now
      return .route(
        Route(steps: [calendarStep(from: now, to: end, limit: 1)], reason: "calendar.next"))
    }
    // 명사는 맞지만 창을 특정하지 못했다("이번 주 일정" 같은 지역 규칙이 걸린 범위).
    return .escalate(reason: "windowUnknown")
  }

  /// 문장 하나가 이 문을 지날 수 있는 길이의 상한.
  ///
  /// 긴 문장에는 이 규칙이 모르는 조건이 붙어 있다(`"오늘 일정 중에 회의만 빼고
  /// 정리해서 메일로 보내줘"`). 길이로 거르는 것은 뜻을 읽는 것이 아니라 **모르는
  /// 것을 통과시키지 않는** 장치다.
  static let maximumInputCharacters = 30

  private static func asksForNextEvent(_ lowered: String) -> Bool {
    let markers = ["다음 일정", "다음일정", "담 일정", "next event", "next meeting", "next appointment"]
    return markers.contains { lowered.contains($0) }
  }

  private struct Window {
    let start: Date
    let end: Date
    let reason: String
  }

  /// 하루 또는 이번 주 단위 질문만 받는다.
  ///
  /// 주 경계는 **지역 규칙이다.** 여기서 "월요일 시작"이라고 단정하지 않고
  /// 차례의 달력(`Calendar.dateInterval(of:for:)`)에게 묻는다 — 그 달력은
  /// 호스트가 기기 설정에서 만들어 실어 준 값이다.
  private static func dayWindow(_ lowered: String, now: Date, calendar: Calendar) -> Window? {
    let today = calendar.startOfDay(for: now)
    guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
    if lowered.contains("오늘") || lowered.contains("today") {
      return Window(start: today, end: tomorrow, reason: "calendar.today")
    }
    if lowered.contains("내일") || lowered.contains("tomorrow") {
      guard let dayAfter = calendar.date(byAdding: .day, value: 1, to: tomorrow) else { return nil }
      return Window(start: tomorrow, end: dayAfter, reason: "calendar.tomorrow")
    }
    if lowered.contains("이번 주") || lowered.contains("이번주") || lowered.contains("this week") {
      guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
      return Window(start: week.start, end: week.end, reason: "calendar.thisWeek")
    }
    return nil
  }

  private static func calendarStep(from start: Date, to end: Date, limit: Int) -> PlannedStep {
    PlannedStep(
      capability: .calendarSearch,
      arguments: [
        "start": .timestamp(start), "end": .timestamp(end), "limit": .number(Double(limit)),
      ])
  }
}
