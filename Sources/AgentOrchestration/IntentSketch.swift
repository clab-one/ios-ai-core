import AgentKernel
import Foundation


/// 문장이 건드리는 **영역**. `CapabilityID.domain`의 앞마디와 같은 낱말을 쓴다 —
/// 갈라 두면 영역 판정과 능력 선택 사이에 옮겨 쓰는 표가 하나 더 생긴다.
public enum CapabilityDomain: String, Sendable, Hashable, CaseIterable {
  case memory
  case artifact
  case content
  case recording
  case calendar
  case reminders
  case people
  case mail
  case chat
  case web
  case share

  /// 이 영역의 능력 전부. **등록 여부는 보지 않는다** — 교집합은
  /// `CapabilityScope`가 낸다(§8: desired ∩ registered).
  public var capabilities: Set<CapabilityID> {
    switch self {
    case .memory: [.memorySearch, .memoryRead, .memorySave]
    case .artifact: [.artifactFind, .artifactRead]
    case .content: [.contentRead, .contentSummarize, .contentIngest]
    case .recording: [.recordingStart, .recordingStop, .recordingRead]
    case .calendar: [.calendarSearch, .calendarCreate, .calendarUpdate, .calendarDelete]
    case .reminders:
      [
        .remindersSearch, .remindersCreate, .remindersUpdate, .remindersComplete,
        .remindersDelete,
      ]
    case .people: [.peopleResolve, .contactsRead]
    case .mail: [.mailSearch, .mailRead, .mailSend, .mailReply]
    case .chat: [.chatSearch, .chatRead, .chatSend, .chatReply]
    case .web: [.webSearch, .webRead, .webFetch]
    case .share: [.sharePublish, .shareRevoke]
    }
  }

  /// 이 영역의 **읽기만**. 쓰기 동사가 문장에 없으면 이것만 펼친다 —
  /// 최소 권한은 규칙이지 권고가 아니다(§8).
  public var readCapabilities: Set<CapabilityID> {
    capabilities.filter { $0.executionClass == .readOnly }
  }

  public static func named(_ raw: String) -> CapabilityDomain? {
    switch raw {
    case "contacts": .people
    default: CapabilityDomain(rawValue: raw)
    }
  }
}

/// 문장이 시키는 **일의 종류**. 정확한 인자까지는 여기서 정하지 않는다(§6).
public enum OperationHint: String, Sendable, Hashable, CaseIterable {
  case search
  case read
  case create
  case send
  case publish
  case save
  case record
  case delete
}

/// 첫 판단의 결과. **요청을 전부 이해한 값이 아니다** — 어느 도구를 펼칠지
/// 정하는 데 필요한 만큼만 담는다.
public struct IntentSketch: Sendable, Equatable {
  public enum Complexity: String, Sendable {
    /// 한 영역·한 동작.
    case single
    /// 여러 영역이거나 읽기 뒤에 쓰기가 온다.
    case composite
  }

  public enum Ambiguity: String, Sendable {
    case clear
    /// 쓰기를 시켰는데 대상이나 시각이 문장에 없다.
    case underspecified
  }

  public var domains: Set<CapabilityDomain>
  public var operations: Set<OperationHint>
  public var complexity: Complexity
  public var ambiguity: Ambiguity
  /// 문장에 그대로 적힌 주소. 있으면 그 주소를 읽는 것이 이 차례의 불변식이다(§24).
  public var explicitURL: URL?

  /// 이 문장이 바깥 세계를 바꾸려 하는가. 승인 경계와 노출 범위가 이 값을 본다.
  public var wantsWrite: Bool {
    !operations.isDisjoint(with: [.create, .send, .publish, .delete])
  }
}

/// 규칙으로 만드는 **첫 스케치**.
///
/// **정확도보다 회수율이다**(§7). 영역 하나를 놓치면 PCC는 그 도구를 볼 기회조차
/// 없고, 그 차례는 조용히 실패한다. 반대로 하나 더 펼친 비용은 도구 스키마 몇 줄이다.
///
/// 낱말 표는 `IntentVocabulary` 하나뿐이다 — 결정론 라우터(`LocalIntentRouter`)와
/// 같은 표를 본다. 표가 둘이 되면 라우터가 아는 신호를 스케치가 모르는 순간이 온다.
public struct IntentSketcher: Sendable {
  public let now: () -> Date
  public let calendar: Calendar

  public init(now: @escaping () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent) {
    self.now = now
    self.calendar = calendar
  }

  public func sketch(_ input: String) -> IntentSketch {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    // 신호는 **주소를 걷어낸 말**에서 센다(`LocalIntentRouter`와 같은 규칙).
    // 주소 안의 낱말은 사용자가 말한 것이 아니다 — `mail.google.com`은 메일을
    // 말하지 않고, 경로의 `/2026/09/15/`는 기한을 말하지 않는다.
    let prose = LinkText.prose(in: text)
    let lowered = prose.lowercased()
    let url = LinkText.firstExplicitURL(in: text)

    var operations = Self.operations(in: lowered)
    var domains = Self.domains(in: lowered)

    // **주소가 손에 있으면 웹이 영역이다.** 이 줄이 없던 동안 `"<주소> 요약해줘"`는
    // 보관함 검색으로 떨어졌다(실기 재현 2026-09-14).
    if url != nil {
      domains.insert(.web)
      operations.insert(.read)
    }

    // 보내라는 문장은 **받는 사람을 먼저 확정한다.** 이름을 주소로 바꾸는 일은
    // 연락처 조회의 일이고, 그 능력이 펼쳐져 있지 않으면 모델은 주소를 지어낸다.
    if operations.contains(.send) {
      domains.insert(.people)
      // 매체를 말하지 않은 전송은 **둘 다 펼친다**(회수율). 실제 전송은
      // `ApprovalPolicy`가 사람에게 한 번 더 묻는다 — 노출이 곧 실행이 아니다.
      if domains.isDisjoint(with: [.mail, .chat]) {
        domains.formUnion([.mail, .chat])
      }
    }

    // **리마인드를 말한 문장은 만들라는 문장이다.** 조회 동사가 함께 있으면
    // 아니다("미리 알림에서 찾아줘"). 이 줄이 없던 동안
    // `"금요일까지 보고서 제출한다고 리마인드 해줘"`에 `reminders.create`가
    // 보이지 않았다 — 낱말표에 `리마인`은 있었지만 그것을 **쓰기 동작**으로
    // 읽는 자리가 없었다(시험 실측).
    if Self.says(lowered, IntentVocabulary.reminderMarkers), !operations.contains(.search)
    {
      operations.insert(.create)
    }
    // 알려 달라는 말 + 해석된 기한 = 미리 알림. 결정론 라우터와 같은 신호다
    // (`LocalIntentRouter` 7번). 기한이 없으면 그것은 답을 달라는 요청이다.
    if Self.says(lowered, IntentVocabulary.notifyVerbs),
      !operations.contains(.search),
      RelativeDateParser.parse(prose, now: now(), calendar: calendar) != nil
    {
      domains.insert(.reminders)
      operations.insert(.create)
    }

    // 내 기록은 **언제나 후보다.** 지역 회수는 싸고, 개인 기록이 답을 들고 있을
    // 가능성은 어느 요청에서나 있다. 예전 프로파일 넷이 모두 `memory.search`를
    // 들고 있던 것과 같은 판단이다.
    domains.insert(.memory)
    if operations.contains(.search) || operations.contains(.read) {
      domains.insert(.artifact)
    }
    if operations.isEmpty { operations.insert(.search) }

    let composite =
      Self.externalDomains(in: domains).count > 1
      || (operations.contains(.search) && domains.contains(.people))
      || (!operations.isDisjoint(with: [.create, .send, .publish])
        && !operations.isDisjoint(with: [.search, .read]))
      || Self.says(lowered, IntentVocabulary.conjunctions)

    // **규칙이 영역을 못 집었으면 읽기 전부를 펼친다.**
    //
    // 실기 2026-09-15: `"신의존재 전화번호 뭐야"`에 `people`이 켜지지 않았다 —
    // 사람 신호가 조사와 `연락처`뿐이고 `전화번호`는 표에 없었다. 그래서 PCC 손에
    // `contacts.read`가 **아예 없었고**, 남은 도구가 내 기록 검색뿐이라 질문과
    // 무관한 기록 두 건이 섰다. 회수가 틀린 것이 아니라 고를 것이 없었다.
    //
    // 낱말을 하나 더 적는 수선은 다음 낱말에서 또 깨진다. 규칙이 모를 때는 읽기
    // 능력 전부를 손에 준다 — 읽기에는 되돌릴 것이 없고(`readCapabilities`),
    // 노출이 곧 실행이 아니다. 조합 판정은 위에서 이미 끝났으므로 이 확장이
    // 모든 질문을 조합으로 만들지는 않는다.
    let wantsWrite = !operations.isDisjoint(with: [.create, .send, .publish, .delete])
    if !wantsWrite, Self.externalDomains(in: domains).isEmpty {
      domains.formUnion(CapabilityDomain.allCases)
    }

    return IntentSketch(
      domains: domains,
      operations: operations,
      complexity: composite ? .composite : .single,
      ambiguity: Self.ambiguity(prose, lowered: lowered, operations: operations, now: now(), calendar: calendar),
      explicitURL: url)
  }

  // MARK: 규칙

  /// **내 기록을 뺀** 영역. 조합 판정에서 언제나 붙는 `memory`·`artifact`를
  /// 세면 모든 문장이 조합이 된다.
  private static func externalDomains(
    in domains: Set<CapabilityDomain>
  ) -> Set<CapabilityDomain> {
    domains.subtracting([.memory, .artifact])
  }

  private static func domains(in lowered: String) -> Set<CapabilityDomain> {
    var found: Set<CapabilityDomain> = []
    if says(lowered, IntentVocabulary.mailMarkers) { found.insert(.mail) }
    if says(lowered, IntentVocabulary.chatMarkers) { found.insert(.chat) }
    if says(lowered, IntentVocabulary.calendarMarkers) { found.insert(.calendar) }
    if says(lowered, IntentVocabulary.reminderMarkers) { found.insert(.reminders) }
    if says(lowered, IntentVocabulary.recordingMarkers) { found.insert(.recording) }
    if says(lowered, IntentVocabulary.shareMarkers) { found.insert(.share) }
    if says(lowered, IntentVocabulary.webMarkers) { found.insert(.web) }
    if says(lowered, IntentVocabulary.peopleMarkers) { found.insert(.people) }
    if says(lowered, IntentVocabulary.documentMarkers) { found.insert(.content) }
    return found
  }

  private static func operations(in lowered: String) -> Set<OperationHint> {
    var found: Set<OperationHint> = []
    if says(lowered, IntentVocabulary.lookupVerbs) {
      found.insert(.search)
      found.insert(.read)
    }
    if says(lowered, IntentVocabulary.sendVerbs) { found.insert(.send) }
    if says(lowered, IntentVocabulary.createVerbs) { found.insert(.create) }
    if says(lowered, IntentVocabulary.captureMarkers) { found.insert(.save) }
    if says(lowered, IntentVocabulary.recordingMarkers) { found.insert(.record) }
    if says(lowered, IntentVocabulary.shareMarkers) { found.insert(.publish) }
    if says(lowered, IntentVocabulary.deleteVerbs) { found.insert(.delete) }
    return found
  }

  /// 되물을 값이 있을 법한가. **판정만 한다** — 무엇을 되물을지는 능력의 계약이
  /// 정하고(`CapabilityContract`), 그 판정은 실행 직전에 일어난다.
  private static func ambiguity(
    _ text: String, lowered: String, operations: Set<OperationHint>, now: Date, calendar: Calendar
  ) -> IntentSketch.Ambiguity {
    if operations.contains(.create),
      RelativeDateParser.parse(text, now: now, calendar: calendar)?.hasClockTime != true
    {
      return .underspecified
    }
    if operations.contains(.publish), !says(lowered, IntentVocabulary.deicticMarkers) {
      return .underspecified
    }
    return .clear
  }

  private static func says(_ text: String, _ needles: [String]) -> Bool {
    needles.contains { text.contains($0) }
  }
}

/// 낱말 표 **하나**.
///
/// 이 표가 두 군데 있던 시절은 없다 — 그렇게 되기 전에 여기로 모았다. 결정론
/// 라우터와 스케치가 같은 신호를 보고, 한쪽만 고쳐 갈라지는 일을 막는다.
public enum IntentVocabulary {
  /// 저장하라는 **명시적** 말. 보관함은 외부 데이터와 이 말이 붙은 요청만 받는다
  /// (사용자 지시 2026-09-15) — 그래서 이 표가 곧 `memory.save`가 손에 들어오는
  /// 조건이고, 표에 없는 평범한 문장은 저장되지 않는다.
  public static let captureMarkers = [
    "기억해", "저장", "적어", "메모", "기록해", "remember", "save this", "note this",
    "write this down", "keep this",
  ]
  /// 보내기·전달. 이 낱말이 있으면 결정론 라우터는 실행을 만들지 않는다.
  public static let sendVerbs = [
    "보내줘", "보내 줘", "보내주세요", "전달해", "전달해줘", "회신", "답장",
    "send", "forward", "reply",
  ]
  /// 조회 동사. `알려`는 여기 **없다** — 그 낱말은 알림과 답변 양쪽에 쓰인다.
  public static let lookupVerbs = [
    "찾아", "검색", "보여", "정리", "요약", "확인", "뭐 있", "알아봐", "비교", "읽어",
    "find", "search", "show me", "summar", "list", "compare", "read",
  ]
  /// 알려 달라는 말. 기한이 함께 있을 때만 미리 알림이 된다.
  public static let notifyVerbs = ["알려줘", "알려 줘", "알려주세요", "알려줄래", "알려 주세요"]
  public static let createVerbs = [
    "만들", "잡아", "추가", "등록", "create", "add", "schedule", "remind me",
  ]
  public static let deleteVerbs = ["삭제", "지워", "취소해", "delete", "remove", "cancel"]
  public static let reminderMarkers = ["리마인", "remind", "미리 알림", "reminder", "할 일 추가"]
  public static let calendarMarkers = ["일정", "미팅", "약속", "calendar", "meeting"]
  public static let mailMarkers = ["gmail", "메일", "mail", "이메일"]
  public static let chatMarkers = ["slack", "슬랙", "메시지", "채널", "channel"]
  public static let recordingMarkers = ["녹음", "record"]
  public static let shareMarkers = ["공유 링크", "공유링크", "share link", "링크 만들"]
  /// 웹. **`웹`이라는 낱말만으로는 아무것도 하지 않는다** — 조회 동사가 함께
  /// 있어야 검색이 된다("웹에서 찾아줘").
  public static let webMarkers = [
    "웹에서", "웹 검색", "웹검색", "인터넷", "web search", "on the web", "구글에서",
  ]
  /// 사람을 가리키는 말. 이름 자체는 여기 없다 — 조사와 호격만 본다.
  public static let peopleMarkers = [
    "에게", "한테", "님께", "연락처", "contact", " to ",
  ]
  public static let documentMarkers = ["문서", "파일", "pdf", "document", "attachment", "첨부"]
  /// 지시어. 앞 차례가 가리킨 것을 말하는 문장이다.
  public static let deicticMarkers = ["이거", "그거", "이것", "그것", "방금", "this", "that"]
  /// 두 일을 잇는 말. 조합 요청의 가장 흔한 신호다.
  public static let conjunctions = [
    "찾아서", "읽고", "정리해서", "확인하고", "하고 나서", "그리고", "다음에",
    " then ", " and then ",
  ]

}
