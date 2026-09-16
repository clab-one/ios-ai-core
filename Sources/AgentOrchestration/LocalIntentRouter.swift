import AgentKernel
import Foundation


/// 입력 한 줄의 **결정론 대역**.
///
/// 뜻을 정하는 주체는 이제 규칙이 아니다 — PCC가 먼저 사용자 의도를 읽고 우리
/// 툴에서 할 일을 고른다(사용자 지시 2026-09-15). 이 타입이 남아 있는 이유는
/// 하나다: **모델을 쓸 수 없는 기기·순간**에도 강한 신호를 가진 문장은 답을
/// 받아야 한다(`TurnRuntime.deterministicRescue`).
///
/// 그래서 여기에는 **기본값 저장이 없다.** 예전에는 분류하지 못한 모든 말이
/// 저장이었고(`case capture`), 그 규칙 때문에 `"커피"` 한 낱말이 AI 판단 없이
/// 보관함 기록이 됐다(사용자 지적 2026-09-15). 보관함은 이제 외부 데이터와
/// 명시적 저장 요청만 받는다 — 명시적 저장은 `memory.save` **툴**이고, 규칙이
/// 아는 것은 그 툴을 부르는 신호뿐이다.
public enum LocalRoute: Equatable, Sendable {
  /// 능력 하나를 바로 실행한다.
  case action(capability: CapabilityID, arguments: [String: ActionValue])
  /// 규칙으로는 모른다 — 모델이 계획한다.
  case escalate(reason: EscalationReason)

  public enum EscalationReason: String, Sendable {
    /// 여러 단계·여러 영역이 섞였다.
    case composite
    /// 무엇을 말하는지 규칙이 모른다.
    case unknown
    /// 뜻이 둘 이상이다.
    case ambiguous
  }
}

public struct LocalIntentRouter: Sendable {
  /// 지금 쓸 수 있는 능력. 연결되지 않은 서비스로는 애초에 보내지 않는다.
  public let available: Set<CapabilityID>
  public let now: () -> Date
  public let calendar: Calendar

  public init(available: Set<CapabilityID>, now: @escaping () -> Date = Date.init,
    calendar: Calendar = .autoupdatingCurrent) {
    self.available = available
    self.now = now
    self.calendar = calendar
  }

  /// 이 문장에 **규칙이 아는 강한 신호**가 있는가.
  ///
  /// **넓은 낱말 분류기를 다시 만들지 않는다.** 그 시도가 이 저장소에서 실제로
  /// 깨진 자리가 둘 있다:
  ///
  /// - `"알려줘"`가 들어 있으면 미리 알림으로 보던 규칙 —
  ///   `"Slack에서 Solana 관련 내용 정리해서 알려줘"`가 미리 알림 요청이 됐다.
  /// - 공급자 이름만 보고 검색으로 보던 규칙 —
  ///   `"Ganesh에게 Gmail로 보내줘"`가 메일 **검색**이 됐다.
  ///
  /// 그래서 규칙이 손을 대는 것은 **강한 신호**뿐이다: 명시적 저장 명령, 녹음
  /// 시작·정지, 시각까지 해석된 Apple 작업, 공급자 이름과 조회 동사가 함께 있는
  /// 문장. 나머지는 전부 모델의 일이다 — 규칙이 모르는 문장에 규칙이 기본값을
  /// 정하지 않는다.
  ///
  /// 그리고 규칙이 내는 실행은 **언제나 계약을 통과한 실행**이다 — 인자가 모자란
  /// 실행을 규칙이 만들어 보내면 그 실패는 어댑터까지 내려간 뒤에 드러난다.
  public func route(_ input: String) -> LocalRoute {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return .escalate(reason: .unknown) }
    // **주소는 뜻을 만들지 않는다 — 주소는 인자다.**
    //
    // 뜻을 정하는 규칙은 문장의 끝을 보고(어미·물음표), 낱말을 부분문자열로 센다.
    // 주소가 문장에 섞이면 둘 다 무너진다: 끝이 주소가 되고, 주소 안의 낱말이
    // 신호로 읽힌다(`mail.google.com`이 메일 영역, `?s=46`이 물음표가 아닌 것).
    // 실기 재현 2026-09-15 02:40: `"이게 무슨 내용이지? https://x.com/…?s=46"`가
    // 질문으로도 읽히지 않아 **저장**으로 떨어졌고, 사용자는 답 대신 메모를 받았다.
    //
    // 그래서 뜻은 주소를 걷어낸 말이 정하고, 주소는 읽을 대상으로만 쓴다.
    let prose = LinkText.prose(in: text)
    let lowered = prose.lowercased()

    // 1) 저장하라는 **명시적** 말. 저장은 이제 툴이다 — `memory.save`를 규칙이
    //    직접 부른다. 이것이 먼저 오는 이유는 "기억해"가 질문처럼 끝나는 문장도
    //    있기 때문이다("이거 기억해줄 수 있어?").
    //
    //    조회 동사가 함께 있으면 저장이 아니다 — `"저장한 거 찾아줘"`는 찾아
    //    달라는 문장이고, 그 문장을 저장으로 읽으면 질의가 기록이 된다.
    if Self.says(lowered, Self.captureMarkers), !Self.says(lowered, Self.lookupVerbs) {
      return route(to: .memorySave, arguments: ["text": .text(text)])
    }

    // 2) 보내기·전달은 규칙이 정하지 않는다. 받는 사람과 본문은 앞 차례에서
    //    오고(그 해석은 규칙의 일이 아니다), 전송은 되돌릴 수 없다.
    if Self.says(lowered, Self.sendVerbs) { return .escalate(reason: .composite) }

    // 3) 두 영역이 한 문장에 있으면(메일 + 슬랙, 일정 + 채팅) 규칙이 손을 뗀다.
    if Self.domains(in: lowered).count > 1 { return .escalate(reason: .composite) }

    // 4) 녹음. 인자가 없는 능력이라 해석할 값이 없다 — 가장 강한 신호다.
    if Self.says(lowered, Self.recordingMarkers) {
      let stop = Self.says(lowered, ["그만", "정지", "멈춰", "stop", "end"])
      return route(to: stop ? .recordingStop : .recordingStart, arguments: [:])
    }

    // 5) 공유 링크. **무엇을 공유할지 문장에 없으면 발행하지 않는다** — 앱이
    //    최근 기록을 고르면 그것은 사용자가 지시한 공개가 아니다. 대상은 모델이
    //    앞 차례에서 찾아야 하므로 그쪽으로 넘긴다.
    if Self.says(lowered, Self.shareMarkers) {
      return .escalate(reason: .ambiguous)
    }

    // 6) 일정. **시각을 읽지 못하면 만들지 않는다.**
    if Self.says(lowered, Self.calendarMarkers) {
      if Self.says(lowered, ["만들", "잡아", "추가", "등록", "create", "add", "schedule"]) {
        guard let parsed = RelativeDateParser.parse(prose, now: now(), calendar: calendar),
          parsed.hasClockTime
        else {
          return .escalate(reason: .ambiguous)
        }
        return route(
          to: .calendarCreate,
          arguments: [
            "title": .text(Self.subject(from: prose)),
            "start": .timestamp(parsed.date),
          ])
      }
      if Self.says(lowered, Self.lookupVerbs + Self.notifyVerbs) {
        var arguments: [String: ActionValue] = [:]
        if let parsed = RelativeDateParser.parse(prose, now: now(), calendar: calendar) {
          let start = calendar.startOfDay(for: parsed.date)
          arguments["start"] = .timestamp(start)
          arguments["end"] = .timestamp(
            calendar.date(byAdding: .day, value: 1, to: start) ?? start)
        }
        return route(to: .calendarSearch, arguments: arguments)
      }
    }

    // 7) 미리 알림. 두 가지 신호만 받는다:
    //
    //    - 명시적 낱말("리마인드", "미리 알림"),
    //    - 또는 **알려 달라는 말 + 해석된 기한**. 기한이 없으면 그것은 알림 요청이
    //      아니라 "말해 달라"는 요청이고, 그 요청의 답은 알림이 아니라 답변이다.
    //
    //    조회 동사가 함께 있으면(정리해서·찾아서) 알림이 아니다 — 그 문장은
    //    무언가를 읽어 달라는 문장이다.
    let due = RelativeDateParser.parse(prose, now: now(), calendar: calendar)
    let explicitReminder = Self.says(lowered, Self.reminderMarkers)
    let deadlineNotice =
      Self.says(lowered, Self.notifyVerbs) && due != nil
      && !Self.says(lowered, Self.lookupVerbs)
    if explicitReminder || deadlineNotice {
      var arguments: [String: ActionValue] = ["title": .text(Self.subject(from: prose))]
      if let due {
        arguments["due"] = .timestamp(due.date)
        arguments["hasClockTime"] = .flag(due.hasClockTime)
      }
      return route(to: .remindersCreate, arguments: arguments)
    }

    // 8) **주소가 문장에 있고 읽어 달라고 했으면 그 주소를 읽는다.**
    //
    //    이 자리가 없던 동안 `"<링크> 요약해줘"`는 아래 10)의 **내 기록 검색**으로
    //    떨어졌다 — 앱은 그 URL 문자열을 보관함에서 찾고, 당연히 못 찾고, 사용자는
    //    요약 대신 "찾지 못했어요"를 받았다(실기 재현 2026-09-14, 스크린샷의
    //    `m.blog.naver.com` 차례). 웹 읽기는 계정을 요구하지 않는 능력이고
    //    (`RootView.registerCapabilities`), 읽어 온 글이 곧 합성의 재료다.
    //
    //    공급자 이름보다 먼저 본다. `"이 메일 링크 요약해줘"`의 대상은 메일함이
    //    아니라 손에 들린 그 주소다.
    //    **묻는 문장도 읽어 달라는 문장이다.** `"이게 무슨 내용이지?"`에는 조회
    //    동사가 없지만(찾아·요약·정리 어느 것도), 주소를 손에 들고 묻는 말의 답은
    //    그 주소를 읽어야 나온다. 이 조건이 동사뿐이던 동안 그 문장은 저장이 됐다.
    if let url = LinkText.firstExplicitURL(in: text),
      Self.says(lowered, Self.lookupVerbs) || Self.isQuestion(lowered)
    {
      return route(to: .webRead, arguments: ["url": .text(url.absoluteString)])
    }

    // 9) 공급자 이름 + 조회 동사. **이름만으로는 아무것도 하지 않는다** — 공급자
    //    이름은 "무엇으로"를 말하고 "무엇을"은 동사가 말한다.
    let query = Self.searchQuery(from: prose)
    if Self.says(lowered, Self.mailMarkers), Self.says(lowered, Self.lookupVerbs) {
      return route(to: .mailSearch, arguments: ["query": .text(query)])
    }
    if Self.says(lowered, Self.chatMarkers), Self.says(lowered, Self.lookupVerbs) {
      return route(to: .chatSearch, arguments: ["query": .text(query)])
    }
    if Self.says(lowered, Self.webMarkers), Self.says(lowered, Self.lookupVerbs) {
      return route(to: .webSearch, arguments: ["query": .text(query)])
    }

    // 10) 내 기록 찾기. 공급자 이름이 없는 조회는 내 기록에 대한 조회다.
    if Self.says(lowered, Self.lookupVerbs) {
      return route(to: .memorySearch, arguments: ["query": .text(query)])
    }

    // 11) 규칙이 아는 신호가 하나도 없다. **기본값 저장이 없다** — 여기서
    //     저장으로 떨어지던 동안 `"커피"` 한 낱말이 AI 판단 없이 보관함 기록이
    //     됐다(사용자 지적 2026-09-15). 뜻을 모르는 문장의 뜻은 모델이 읽는다.
    return .escalate(reason: .unknown)
  }

  /// 능력이 등록되지 않았다면(연결 안 된 서비스·꺼진 권한) 모델에게 넘겨
  /// 사용자에게 연결을 권하게 한다. 인자가 계약을 통과하지 못하면 되물어야 하므로
  /// 같은 길로 보낸다 — 규칙은 **실행 가능한 것만** 실행으로 만든다.
  private func route(
    to capability: CapabilityID, arguments: [String: ActionValue]
  ) -> LocalRoute {
    guard available.contains(capability) else { return .escalate(reason: .unknown) }
    switch CapabilityContract.normalize(arguments, for: capability) {
    case .success(let normalized):
      return .action(capability: capability, arguments: normalized)
    case .failure:
      return .escalate(reason: .ambiguous)
    }
  }

  // MARK: 신호

  // 표는 **한 벌뿐이다**(`IntentVocabulary`). 여기에 사본을 두던 동안 라우터가
  // 아는 신호를 스케치가 몰랐고, 그러면 규칙이 부르는 툴이 범위에 없는 순간이
  // 온다 — 구제가 계획을 내도 그 툴이 보이지 않아 차례가 빈손으로 끝난다.
  private static let captureMarkers = IntentVocabulary.captureMarkers
  private static let sendVerbs = IntentVocabulary.sendVerbs
  private static let lookupVerbs = IntentVocabulary.lookupVerbs
  private static let notifyVerbs = IntentVocabulary.notifyVerbs
  private static let reminderMarkers = IntentVocabulary.reminderMarkers
  private static let calendarMarkers = IntentVocabulary.calendarMarkers
  private static let mailMarkers = IntentVocabulary.mailMarkers
  private static let chatMarkers = IntentVocabulary.chatMarkers
  private static let webMarkers = IntentVocabulary.webMarkers
  private static let recordingMarkers = IntentVocabulary.recordingMarkers
  private static let shareMarkers = IntentVocabulary.shareMarkers

  private static func says(_ text: String, _ needles: [String]) -> Bool {
    needles.contains { text.contains($0) }
  }

  /// 한 문장이 건드리는 영역. 둘 이상이면 규칙이 손을 뗀다.
  ///
  /// `알려줘`는 영역이 아니다 — 영역으로 세면 `"Slack에서 정리해서 알려줘"`가
  /// 두 영역으로 읽혀 늘 모델로 넘어갔다. 그 판정은 우연히 맞았을 뿐이고,
  /// 우연히 맞는 규칙은 다음 문장에서 틀린다.
  private static func domains(in text: String) -> Set<String> {
    var found: Set<String> = []
    if says(text, mailMarkers) { found.insert("mail") }
    if says(text, chatMarkers) { found.insert("chat") }
    if says(text, calendarMarkers) { found.insert("calendar") }
    if says(text, reminderMarkers) { found.insert("reminders") }
    if says(text, recordingMarkers) { found.insert("recording") }
    if says(text, shareMarkers) { found.insert("share") }
    if says(text, webMarkers) { found.insert("web") }
    return found
  }

  /// **질문 판정은 좁다.**
  ///
  /// 부분문자열로 의문사를 찾던 자리다. 그러면 "내일 보고서 제출해줘"·"when I get
  /// home buy milk"처럼 평범한 평서문이 질문으로 분류된다. 지금 이 판정이 정하는
  /// 것은 **주소를 읽을 것인가** 하나뿐이고(8번), 그래서 좁아야 한다.
  ///
  /// 그래서 판정은 문장의 **끝**만 본다: 물음표, 또는 문장을 끝내는 의문 어미.
  private static func isQuestion(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasSuffix("?") { return true }
    // 한국어는 어미가 문장의 끝에 온다 — 중간에 나온 "뭐"는 인용이거나 명사다.
    return ["뭐야", "뭔가요", "무엇인가요", "어때", "어떤가요", "일까", "인가요", "맞나요"]
      .contains { trimmed.hasSuffix($0) }
  }

  /// 검색어. 지시어를 걷어낸 나머지가 질의다 — 문장을 그대로 질의로 쓰면
  /// "찾아줘"라는 낱말이 검색어에 섞인다.
  private static func searchQuery(from text: String) -> String {
    var query = text
    for marker in [
      "찾아줘", "찾아", "검색해줘", "검색해", "검색", "보여줘", "정리해서", "정리해줘", "정리해",
      "요약해서", "요약해줘", "요약해", "알려줘", "알려 줘", "에서", "관련", "내용",
      "gmail", "slack", "슬랙", "메일", "이메일", "mail", "웹에서", "웹", "인터넷", "구글에서",
      "find", "search", "show me", "summarize", "please",
    ] {
      query = query.replacingOccurrences(
        of: marker, with: " ", options: [.caseInsensitive])
    }
    let cleaned = query.replacingOccurrences(
      of: #"\s+"#, with: " ", options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    // 다 걷어내 아무것도 남지 않으면 원문을 쓴다 — 빈 질의는 공급자에게
    // "전부 주세요"로 읽힌다.
    return cleaned.isEmpty ? text : cleaned
  }

  /// 일정·할 일의 제목. 시각 표현과 지시어를 걷어낸 나머지다.
  private static func subject(from text: String) -> String {
    var subject = text
    for marker in [
      "일정 만들어줘", "일정 만들어", "일정 잡아줘", "일정 추가", "일정", "알려줘", "알려 줘",
      "리마인드", "만들어줘", "만들어", "추가해줘", "추가", "등록해줘",
      "create", "add", "schedule", "remind me",
      // 시각 표현은 `due`가 이미 든다. 제목에 남기면 "금요일 보고서 제출"처럼
      // 날짜가 두 번 적힌 할 일이 된다.
      "내일", "오늘", "모레", "다음주", "다음 주", "오전", "오후", "정오", "tomorrow", "today",
      "next week",
      "월요일", "화요일", "수요일", "목요일", "금요일", "토요일", "일요일",
      "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ] {
      subject = subject.replacingOccurrences(
        of: marker, with: " ", options: [.caseInsensitive])
    }
    // 시각 표현(`3시`, `15:00`)을 지운다.
    for pattern in [#"\d{1,2}\s*시\s*(\d{1,2}\s*분)?"#, #"\d{1,2}:\d{2}"#, #"\d{1,2}\s*(am|pm)"#]
    {
      subject = subject.replacingOccurrences(
        of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
    }
    for particle in ["에 ", "에서 ", "까지 ", "부터 "] {
      subject = subject.replacingOccurrences(of: particle, with: " ")
    }
    let cleaned = subject.replacingOccurrences(
      of: #"\s+"#, with: " ", options: .regularExpression
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    // 다 걷어내 아무것도 남지 않으면 원문을 쓴다 — 제목 없는 일정을 만들지 않는다.
    return cleaned.isEmpty ? text : cleaned
  }
}
