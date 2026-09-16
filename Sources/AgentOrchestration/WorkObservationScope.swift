import AgentKernel
import Foundation

/// "오늘 내가 처리해야 하는 것"을 **공급자 하나의 의도가 아니라 관찰 범위로**
/// 읽는다(§12 PR 4).
///
/// 이 문장에는 공급자가 없다. 그런데 규칙이 공급자를 하나 고르면 그 순간 답은
/// 반쪽이 된다 — 일정만 보거나 미리 알림만 보는 답이 "오늘 처리할 것"이라고
/// 말한다. 그래서 여기서는 **어느 영역을 봐야 하는가**만 정하고, 실제 실행은
/// 읽기 전용 단계들의 bounded fanout이 한다.
///
/// **공급자 검색은 여기서 만들지 않는다.** Gmail·Slack 검색은 질의가 필수이고
/// (`CapabilityContract.mailSearch`), 시간만으로 메일함을 훑는 것은 질의가 아니다.
/// 규칙이 `is:unread` 같은 값을 지어내면 사용자가 요청하지 않은 범위를 조용히
/// 고르는 것이 된다 — 그 판단은 모델의 일이고, 이 타입은 기기 안에서 확실한
/// 영역만 연다.
public struct WorkObservationScope: Sendable, Equatable {
  public enum Horizon: String, Sendable, Equatable {
    case today, tomorrow, thisWeek
  }

  public let horizon: Horizon

  /// 이 문장이 **업무 정리 질문**인가.
  ///
  /// 두 조건이 함께 있어야 한다: 기간을 가리키는 말과, 처리할 것을 묻는 말.
  /// 하나만으로는 열지 않는다 — `"오늘 일정 뭐야"`는 일정 하나를 묻는 문장이고,
  /// 그 문장은 기존 단일 영역 규칙이 이미 정확히 답한다.
  public static func detect(_ input: String) -> WorkObservationScope? {
    let text = LinkText.prose(in: input).lowercased()
    guard !text.isEmpty else { return nil }
    // 영역을 이름으로 부른 문장은 이 범위가 아니다(그 영역의 규칙이 답한다).
    guard !namesASingleDomain(text) else { return nil }
    guard let horizon = horizon(in: text) else { return nil }
    guard triageMarkers.contains(where: { text.contains($0) }) else { return nil }
    return WorkObservationScope(horizon: horizon)
  }

  /// 이 범위가 여는 **읽기 전용** 단계들. 순서는 고정이다 — 같은 질문이 같은
  /// 순서를 내야 결과 병합도 결정론이 된다.
  public func steps(available: Set<CapabilityID>, now: Date, calendar: Calendar) -> [PlannedStep] {
    let interval = self.interval(now: now, calendar: calendar)
    var steps: [PlannedStep] = []
    if available.contains(.calendarSearch) {
      steps.append(
        PlannedStep(
          capability: .calendarSearch,
          arguments: [
            "start": .timestamp(interval.start), "end": .timestamp(interval.end),
          ]))
    }
    if available.contains(.remindersSearch) {
      // 질의 없는 조회 = 열려 있는 미리 알림 전부. 기간으로 좁히지 않는다 —
      // 지난 기한이 남아 있는 것이야말로 "처리해야 하는 것"이다.
      steps.append(PlannedStep(capability: .remindersSearch, arguments: [:]))
    }
    return steps
  }

  public func interval(now: Date, calendar: Calendar) -> DateInterval {
    let startOfDay = calendar.startOfDay(for: now)
    switch horizon {
    case .today:
      let end = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? now
      return DateInterval(start: startOfDay, end: end)
    case .tomorrow:
      let start = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
      let end = calendar.date(byAdding: .day, value: 2, to: startOfDay) ?? start
      return DateInterval(start: start, end: end)
    case .thisWeek:
      let end = calendar.date(byAdding: .day, value: 7, to: startOfDay) ?? startOfDay
      return DateInterval(start: startOfDay, end: end)
    }
  }

  private static func horizon(in text: String) -> Horizon? {
    if text.contains("이번 주") || text.contains("이번주") || text.contains("this week")
      || text.contains("주간")
    {
      return .thisWeek
    }
    if text.contains("내일") || text.contains("tomorrow") { return .tomorrow }
    if text.contains("오늘") || text.contains("today") { return .today }
    return nil
  }

  /// 처리할 것을 묻는 말. **"정리해줘" 하나로는 열지 않는다** — 그 말은 글을
  /// 정리해 달라는 뜻으로도 쓰이고(`"Slack에서 Solana 정리해줘"`), 그 문장을
  /// 업무 브리핑으로 읽으면 사용자가 요청한 검색이 사라진다.
  private static let triageMarkers = [
    "뭐 해야", "뭐해야", "무엇을 해야", "할 일", "할일", "처리해야", "챙길", "챙겨야",
    "브리핑", "일정 정리", "what do i need", "what should i do", "to do", "todo",
    "my day", "agenda",
  ]

  /// 영역 이름이 하나만 들어 있는 문장은 그 영역의 질문이다.
  private static func namesASingleDomain(_ text: String) -> Bool {
    let domains = [
      ["메일", "이메일", "gmail", "mail"],
      ["슬랙", "slack", "채팅", "메시지"],
      ["기록", "메모", "보관함"],
    ]
    return domains.contains { markers in markers.contains { text.contains($0) } }
  }
}
