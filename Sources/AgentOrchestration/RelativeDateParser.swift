import Foundation


/// 문장 속의 시각. **모르는 것은 모른다고 말한다.**
///
/// `hasClockTime`이 따로 있는 이유: "금요일까지 보고서"에는 시각이 없다. 앱이
/// 임의로 오전 9시를 정하면 그 시각에 알림이 울리고, 사용자는 자기가 정하지 않은
/// 약속을 본다. 시각이 없으면 날짜만 담아 하루 안의 할 일로 남긴다.
public struct ParsedDateTime: Equatable, Sendable {
  public let date: Date
  public let hasClockTime: Bool
}

/// 결정론 날짜 해석기. 모델을 부르지 않는다 — "내일 오후 3시"는 계산이지 추론이
/// 아니고, 계산을 모델에 맡기면 틀린 값이 조용히 캘린더에 들어간다.
public enum RelativeDateParser {
  /// 한국어·영어의 상대 날짜와 시각을 읽는다. 읽을 수 없으면 nil이다 —
  /// 그 nil이 곧 "임의로 실행하지 않는다"의 근거가 된다.
  public static func parse(
    _ text: String, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent
  ) -> ParsedDateTime? {
    let lowered = text.lowercased()
    guard var day = parseDay(lowered, now: now, calendar: calendar) else {
      // 날짜 없이 시각만 말한 경우("3시에")는 오늘로 본다. 이미 지난 시각이면
      // 내일로 넘긴다 — 지난 시각에 일정을 만들면 그것은 기록이지 약속이 아니다.
      guard let clock = parseClock(lowered) else { return nil }
      let today = apply(clock, to: now, calendar: calendar)
      if let today, today > now { return ParsedDateTime(date: today, hasClockTime: true) }
      guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
        let shifted = apply(clock, to: tomorrow, calendar: calendar)
      else { return nil }
      return ParsedDateTime(date: shifted, hasClockTime: true)
    }
    if let clock = parseClock(lowered), let applied = apply(clock, to: day, calendar: calendar)
    {
      return ParsedDateTime(date: applied, hasClockTime: true)
    }
    // 시각이 없으면 그 날의 시작을 담되 **시각이 없다는 사실을 함께** 올린다.
    day = calendar.startOfDay(for: day)
    return ParsedDateTime(date: day, hasClockTime: false)
  }

  // MARK: 날짜

  private static func parseDay(
    _ text: String, now: Date, calendar: Calendar
  ) -> Date? {
    if text.contains("모레") || text.contains("day after tomorrow") {
      return calendar.date(byAdding: .day, value: 2, to: now)
    }
    if text.contains("내일") || text.contains("tomorrow") {
      return calendar.date(byAdding: .day, value: 1, to: now)
    }
    if text.contains("오늘") || text.contains("today") || text.contains("지금")
      || text.contains("now")
    {
      return now
    }
    if text.contains("다음주") || text.contains("다음 주") || text.contains("next week") {
      let base = calendar.date(byAdding: .day, value: 7, to: now) ?? now
      if let weekday = parseWeekday(text) {
        return nextDate(weekday: weekday, from: base, calendar: calendar, includeToday: true)
      }
      return base
    }
    if let absolute = parseAbsolute(text, now: now, calendar: calendar) {
      return absolute
    }
    if let weekday = parseWeekday(text) {
      return nextDate(weekday: weekday, from: now, calendar: calendar, includeToday: false)
    }
    return nil
  }

  /// `9월 15일`, `9/15`, `Sep 15` 같은 절대 날짜. 연도를 말하지 않으면 **앞으로
  /// 오는 그 날**로 본다 — 지난 날짜로 일정을 만들 이유가 없다.
  private static func parseAbsolute(
    _ text: String, now: Date, calendar: Calendar
  ) -> Date? {
    let patterns = [
      #"(\d{1,2})월\s*(\d{1,2})일"#,
      #"(\d{1,2})/(\d{1,2})"#,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(
          in: text, range: NSRange(text.startIndex..., in: text)),
        match.numberOfRanges == 3,
        let monthRange = Range(match.range(at: 1), in: text),
        let dayRange = Range(match.range(at: 2), in: text),
        let month = Int(text[monthRange]), let day = Int(text[dayRange]),
        (1...12).contains(month), (1...31).contains(day)
      else { continue }
      var components = calendar.dateComponents([.year], from: now)
      components.month = month
      components.day = day
      guard let candidate = calendar.date(from: components) else { continue }
      if candidate < calendar.startOfDay(for: now) {
        components.year = (components.year ?? 0) + 1
        return calendar.date(from: components)
      }
      return candidate
    }
    return nil
  }

  private static func parseWeekday(_ text: String) -> Int? {
    let korean = ["일": 1, "월": 2, "화": 3, "수": 4, "목": 5, "금": 6, "토": 7]
    for (name, index) in korean where text.contains("\(name)요일") {
      return index
    }
    let english = [
      "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5,
      "friday": 6, "saturday": 7,
    ]
    for (name, index) in english where text.contains(name) {
      return index
    }
    return nil
  }

  private static func nextDate(
    weekday: Int, from date: Date, calendar: Calendar, includeToday: Bool
  ) -> Date? {
    let current = calendar.component(.weekday, from: date)
    var delta = (weekday - current + 7) % 7
    if delta == 0 && !includeToday { delta = 7 }
    return calendar.date(byAdding: .day, value: delta, to: date)
  }

  // MARK: 시각

  private struct Clock: Equatable {
    public let hour: Int
    public let minute: Int
  }

  /// 문장 속의 시각. **자정부터의 분**으로 돌려준다.
  ///
  /// 자동화 일정도 같은 해석을 써야 한다(`AutomationScheduleParser`) — 두 자리가
  /// 각자 정규식을 들면 "오후 3시"를 한쪽은 15시로, 다른 쪽은 3시로 읽는다.
  public static func minuteOfDay(in text: String) -> Int? {
    guard let clock = parseClock(text.lowercased()) else { return nil }
    return clock.hour * 60 + clock.minute
  }

  private static func parseClock(_ text: String) -> Clock? {
    let isAfternoon =
      text.contains("오후") || text.contains("저녁") || text.contains("pm")
    let isMorning = text.contains("오전") || text.contains("아침") || text.contains("am")
    // `3시 30분`, `3:30`, `3pm`
    let patterns = [
      #"(\d{1,2})\s*시\s*(\d{1,2})?\s*분?"#,
      #"(\d{1,2}):(\d{2})"#,
      #"(\d{1,2})\s*(?:am|pm)"#,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
        let hourRange = Range(match.range(at: 1), in: text),
        var hour = Int(text[hourRange]), (0...23).contains(hour)
      else { continue }
      var minute = 0
      if match.numberOfRanges > 2, let minuteRange = Range(match.range(at: 2), in: text),
        let parsed = Int(text[minuteRange]), (0...59).contains(parsed)
      {
        minute = parsed
      }
      if isAfternoon, hour < 12 { hour += 12 }
      if isMorning, hour == 12 { hour = 0 }
      return Clock(hour: hour, minute: minute)
    }
    if text.contains("정오") || text.contains("noon") { return Clock(hour: 12, minute: 0) }
    return nil
  }

  private static func apply(_ clock: Clock, to day: Date, calendar: Calendar) -> Date? {
    var components = calendar.dateComponents([.year, .month, .day], from: day)
    components.hour = clock.hour
    components.minute = clock.minute
    return calendar.date(from: components)
  }
}
