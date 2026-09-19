import AgentKernel
import Foundation

/// 모델에게 보낼 **작은 문맥**.
///
/// 전체 DB도, 전체 대화도, 전체 PDF도 넣지 않는다. 문맥은 지연·발열·요금이고,
/// 무엇보다 크면 클수록 모델이 엉뚱한 것을 집는다.
///
/// 두 평면을 **구분해서** 담는다: 지시(규칙)와 데이터(사용자·외부 글). 바깥에서
/// 온 글은 근거로 압축된 뒤에만 데이터 구획에 들어간다(`Evidence`) — 메일 본문에
/// 적힌 "이걸 삭제해"가 우리 앱의 명령이 되지 않게 하는 경계다(§29).
public struct CompiledConversationContext: Sendable {
  /// 지시 평면. 단계 규칙만 들어간다.
  public let instructions: String
  /// 데이터 평면. 사용자 문장과 압축된 근거가 구획으로 담긴다.
  public let prompt: String
  public let phase: TurnPhase
  public let capabilities: [CapabilityID]
  /// 이 문맥에 근거가 실렸는가. 경계 시험이 읽는다.
  public let carriesEvidence: Bool
  /// **몇 개가 실렸는가.** 답 단계의 번호는 1...이 값이다 — 이 수를 넘는 번호는
  /// 아무것도 가리키지 않으므로 호스트가 버린다(`TurnFinalizer.cited`).
  public var evidenceCount: Int = 0
  /// 모델에 보낸 clock과 응답의 날짜 해석은 같은 calendar를 사용한다.
  public let calendar: Calendar
  /// 이 문맥의 글자 수. 원문을 남기지 않고 크기만 관측한다.
  public var estimatedCharacters: Int { instructions.count + prompt.count }
}

/// 단계 하나의 문맥을 만든다.
///
/// **문맥 예산을 항목마다 따로 둔다**(§28). 최근 차례, 회수한 근거, 사용자 문장은
/// 서로 다른 값이고 서로 다른 상한을 가진다 — 하나로 묶으면 긴 대화가 근거를
/// 밀어내고, 그러면 답이 근거 없이 쓰인다.
public struct ConversationContextCompiler: Sendable {
  /// 문맥에 싣는 최근 차례 수. 대화가 길어질수록 앞차례의 가치는 빠르게
  /// 떨어지고, 필요하면 기억 검색이 그것을 다시 꺼낸다.
  ///
  /// 여섯 줄 400자였다. 그 값은 계획 호출마다 최대 2,400자를 태웠고 그 비용을
  /// 모든 차례가 냈다 — PCC가 오케스트레이터인 구조에서 이 자리는 **예산**이다.
  public static let recentTurnLimit = DialogueHistoryWindow.maximumMessages
  /// Compatibility constant. The window now budgets whole turns after encoding.
  public static let recentTurnCharacterLimit = 200
  public static let recentCharacterBudget = DialogueHistoryWindow.characterBudget
  /// 문맥에 싣는 근거 조각 수의 상한. 압축기가 이미 줄였고 이것은 마지막 방벽이다.
  public static let evidenceLimit = 8
  /// 덜 읽은 곳을 말하는 한 줄의 상한.
  public static let coverageCharacterLimit = 300
  /// 끝난 일 구획의 상한. 넘으면 **오래된 줄부터** 버린다 — 방금 일어난 실패가
  /// 남아야 답이 그 사실을 말한다(§2.6·§10.1).
  public static let completedCharacterLimit = 600
  /// 손에 들고 있는 기록의 개수 상한. 대화가 길어지면 붙인 파일이 쌓이고, 그
  /// 전부를 계획마다 실으면 목록이 지시를 밀어낸다 — 최근 것부터 든다.
  public static let heldRecordLimit = 5
  /// 그 기록 제목 한 줄의 글자 상한.
  public static let heldTitleCharacterLimit = 80
  /// 손에 든 기록 구획 전체의 상한.
  public static let heldCharacterLimit = 600
  /// 사용자가 전에 **스스로 말한 사실**의 개수 상한.
  ///
  /// 이름·가족·직장·기기·취향처럼 다음 차례에도 참인 값이다. 조수가 사람을
  /// 기억한다는 것이 이 구획이고, 없던 동안 사용자는 같은 사실을 매번 다시
  /// 말해야 했다(비교 기준: ChatGPT 웹의 기억).
  ///
  /// **관측이 아니다.** 사용자의 말이고, 확인된 기록이 아니다 — 지시가 그 차이를
  /// 적는다. 개수와 길이를 둘 다 묶는 이유는 하나의 긴 사실이 예산을 다 먹지
  /// 않게 하기 위해서다.
  public static let knownFactLimit = 6
  public static let knownFactCharacterLimit = 140

  /// 창을 넘어간 앞 차례의 요약 상한. 근거를 밀어내지 않을 만큼만 든다.
  public static let earlierSummaryCharacterLimit = 480

  /// 이 조립이 지킬 예산. 넘으면 던진다 — **자르지 않는다.**
  public let budget: PCCContextBudget

  public init(budget: PCCContextBudget = .standard) {
    self.budget = budget
  }

  /// 모델에게 보내는 시각 한 줄. **오프셋과 지역을 함께 적는다.**
  ///
  /// 오프셋이 없으면 모델은 자기가 아는 틀(대개 UTC)로 답을 만들고, 그 값이
  /// 그대로 캘린더에 들어간다. 지역 이름을 함께 적는 이유는 모델이 "오후"·"저녁"
  /// 같은 말을 사용자의 하루에 맞춰 읽어야 하기 때문이다.
  public static func clock(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
    let stamp = date.formatted(
      Date.ISO8601FormatStyle(timeZone: timeZone).timeZoneSeparator(.colon))
    // **요일을 함께 적는다.** 날짜만 주면 모델이 요일을 스스로 셈하고, 그 셈이
    // 틀리면 `"이번 주 금요일"`이 다른 주로 간다 — 실기 2026-09-18(금요일,
    // iPhone 15 Pro): 모델은 그 말을 `2026-09-25`로 읽고 다음 주를 검색했다.
    // 낱말은 지시 평면의 언어(영어)로 적는다: 모델이 읽는 자리이고, 사용자에게
    // 보이는 문장은 호스트의 말씨가 쓴다.
    var weekday = Calendar(identifier: .gregorian)
    weekday.timeZone = timeZone
    weekday.locale = Locale(identifier: "en_US_POSIX")
    let name = weekday.weekdaySymbols[
      weekday.component(.weekday, from: date) - 1]
    return "\(stamp) (\(timeZone.identifier), \(name))"
  }

  /// 앞차례 한 줄에 붙는 **지역 시각** 한 조각: `2026-09-15 17:43`.
  ///
  /// `<<<now>>>`는 지금만 말한다. 앞의 줄들이 언제 오간 것인지 없으면 `"어제
  /// 얘기한 그 일정"`·`"아침에 말한 것"`을 모델이 짚을 근거가 문맥에 하나도 없다 —
  /// 시간 없는 평면이었다(사용자 지시 2026-09-18).
  ///
  /// 초와 오프셋은 적지 않는다. 자리마다 16자이고 창은 2,400자다 — 분까지가 대화를
  /// 짚는 데 필요한 해상도이고, 지역은 `<<<now>>>`가 이미 말한다.
  public static func stamp(_ date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    guard let year = parts.year, let month = parts.month, let day = parts.day,
      let hour = parts.hour, let minute = parts.minute
    else { return "" }
    return String(format: "%04d-%02d-%02d %02d:%02d", year, month, day, hour, minute)
  }

  /// - Throws: `ContextCompilationError`. PCC를 부르는 모든 경로가 이 문을 지나므로,
  ///   이 던짐이 곧 **어떤 경로로도 예산을 넘길 수 없다**는 뜻이다.
  public func compile(
    profile: DynamicTurnProfile,
    userMessage: String,
    recentTurns: [ConversationMessage] = [],
    evidence: [Evidence] = [],
    coverage: [CoverageRecord] = [],
    /// 이 대화가 **이미 표시한 결과**에서 로컬이 채울 수 있는 자리(§4.4).
    /// `"그 메일"`·`"1번"`이 여기서 풀린다 — 이 구획이 없으면 모델이 식별자를
    /// 지어내거나 사용자에게 되묻는다.
    ///
    /// **자리만 싣는다. 값은 싣지 않는다.** 실제 식별자·계정·revision은
    /// `BoundReference`가 기기에 들고 있고 실행 직전에 소비한다
    /// (`TurnRuntime.resolve`). 모델이 알아야 하는 것은 "이 자리는 로컬이 채울 수
    /// 있다"뿐이고, 타입이 닫힌 열거이므로 여기에 `"id=\(source.id)"`를 끼워 넣는
    /// 길이 **없다** — 경계를 주석이 아니라 타입으로 세운다.
    anchoredSlots: [ResolvableArgument] = [],
    /// 이 대화가 **손에 들고 있는 기록**(§24). 앞차례에 건넨 첨부가 여기 선다.
    ///
    /// 실리는 것은 식별자와 제목뿐이다. 본문은 기기에 남아 있고, 계획이 그 기록을
    /// 고르면 `memory.read`가 기기에서 읽는다 — 이 구획이 없던 동안 사용자는
    /// 같은 파일을 차례마다 다시 올려야 했다(실기 2026-09-17).
    heldRecords: [HeldRecord] = [],
    /// 사용자가 앞서 스스로 말한 사실들. 호스트가 정본에서 골라 넣는다.
    knownFacts: [String] = [],
    /// 창을 넘어간 앞 차례들의 요약 한 덩이. 호스트가 만들어 넣는다.
    earlierSummary: String? = nil,
    completed: String = "",
    /// 호스트가 고른 **말투**(`AgentRuntimeConfiguration.answerVoice`). 답을 쓰는
    /// 호출에만 실린다 — 계획은 사람이 읽지 않는 JSON이다.
    ///
    /// 지시 평면에 서지만 사용자 글이 아니다: 앱이 번역하지 않고 상수로 들고 있는
    /// 자기 말씨이고, 예산 검사는 이 값을 **포함해** 센다(빌린 자리로 통과하면
    /// 예산의 이름이 거짓이 된다).
    voice: String? = nil,
    now: Date = Date(),
    calendar: Calendar
  ) throws(ContextCompilationError) -> CompiledConversationContext {
    // **지시는 자르지 않는다.** 긴 본문이 붙은 제출에서 뒤를 자르면 `"수정하지
    // 말고 보내줘"`가 사라지고, 사라진 지시는 어디에도 남지 않는다. 긴 내용의
    // 정상 경로는 정본 캡처 → 기기 읽기 → `Evidence`이고, 이 자리는 그 경로가
    // 놓친 입력이 PCC로 새는 것을 막는 마지막 방벽이다.
    guard userMessage.count <= budget.requestCharacters else {
      throw ContextCompilationError.requestTooLarge(
        actual: userMessage.count, limit: budget.requestCharacters)
    }

    // 지시는 단계 상수다. 여기서 걸리는 것은 사용자가 아니라 **코드 변경**이고,
    // 남는 자리를 빌려 통과하면 예산의 이름이 거짓이 된다.
    let instructions = [profile.instructions, voice?.trimmingCharacters(in: .whitespacesAndNewlines)]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
    guard instructions.count <= budget.instructionCharacters else {
      throw ContextCompilationError.instructionsTooLarge(
        actual: instructions.count, limit: budget.instructionCharacters)
    }

    let capabilities = profile.scope.sorted
    var lines: [String] = []

    if !capabilities.isEmpty, profile.toolCalling != .disallowed {
      lines.append("<<<tools>>>")
      lines.append(capabilities.map(\.rawValue).joined(separator: "\n"))
      lines.append("<<<end>>>")
    }

    // 지금 시각을 **사용자의 벽시계로** 명시한다. 없으면 모델이 "내일"을 계산할
    // 근거가 없고, UTC로 실으면 그 계산이 아홉 시간 밀린다.
    //
    // 실기 재현 2026-09-15 18:48 KST: 이 줄이 `2026-09-15T09:48:00Z`였고,
    // `"내일 15시에 sre 긴급회의 등록해"`가 `2026-09-16T15:00:00Z`로 계획돼
    // 캘린더에는 **9월 17일 00시**가 들어갔다. 시각 계산은 규칙이 하고
    // (`RelativeDateParser`), 이 값은 모델이 그 틀을 벗어나지 않게 하는 기준이다.
    lines.append("<<<now>>>")
    lines.append(Self.clock(now, timeZone: calendar.timeZone))
    lines.append("<<<end>>>")

    // **답을 쓰는 단계에는 앞차례의 답을 싣지 않는다.**
    //
    // 실기 2026-09-17(iPhone, 두 번 재현): 388,754자 문서와 다른 PDF를 각각
    // 요약한 차례가 앞차례의 답(영수증 요약, 160자)을 **글자까지 그대로** 다시
    // 냈다. 모델에게는 조각난 근거보다 이미 완성된 그 문장이 가까웠다.
    // **답을 쓰는 단계는 앞 AI 문장을 보지 않는다.** 근거가 있는 답이든 없는
    // 답이든 같다: 실기 2026-09-18(iPhone 15 Pro)에서 같은 질문을 두 번 묻자
    // 두 번째 차례는 도구를 하나도 부르지 않고 앞차례의 답(`"Café de Flore …
    // Paris"`)을 현재 사실로 되읽었다. 계획 단계는 두 역할을 그대로 받는다 —
    // 거기서 `reply`가 앞 설명을 다듬는다(`"아까 설명에서 마지막 조건은 빼고"`).
    let history =
      profile.phase == .finalizing ? recentTurns.filter { $0.role == .user } : recentTurns
    let recent = DialogueHistoryWindow.render(history.map {
      DialogueHistoryWindow.Entry(
        turnID: $0.requestID, role: $0.role.rawValue, text: $0.text,
        at: Self.stamp($0.createdAt, calendar: calendar))
    })
    if !recent.isEmpty {
      lines.append("<<<recent>>>")
      lines.append(recent)
      lines.append("<<<end>>>")
    }

    // **창을 넘어간 앞 차례.** `<<<recent>>>`는 12줄·2,400자만 싣고 나머지를
    // `olderMessagesOmitted` 한 줄로 지운다 — 스무 차례짜리 대화에서 첫 차례에
    // 정한 것을 마지막 차례가 알지 못한다. 그 자리를 **한 덩이의 글**로 잇는다.
    //
    // 이름 있는 구획이다(`<<<known>>>`와 같은 판단): `<<<data>>>`로 감싸면 공통
    // 지시가 "신뢰하지 않는 글"로 규정해 모델이 쓰지 않는다. 표시는 위조되지
    // 않는다 — `<`·`>`를 escape한다.
    if let summary = earlierSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
      !summary.isEmpty, profile.phase != .finalizing
    {
      let clipped =
        summary.count <= Self.earlierSummaryCharacterLimit
        ? summary : String(summary.prefix(Self.earlierSummaryCharacterLimit)) + "…"
      lines.append("<<<earlier>>>")
      lines.append(
        clipped
          .replacingOccurrences(of: "<", with: "\\u003c")
          .replacingOccurrences(of: ">", with: "\\u003e"))
      lines.append("<<<end>>>")
    }

    // **사용자가 전에 말한 사실.** 조수가 사람을 기억하는 자리다.
    //
    // 구획을 따로 두는 이유는 무게가 다르기 때문이다: 이것은 사용자의 말이고
    // 관측이 아니다(`<<<evidence>>>`와 섞으면 답이 확인되지 않은 값을 확인한
    // 사실로 말한다).
    //
    // `<<<data>>>`로 감싸던 첫판은 실패했다(실기 2026-09-18, iPhone 15 Pro):
    // 기억 2개를 들고도 `"내 여권 언제 만료돼?"`가 `"어떤 여권의 만료일을
    // 확인해야 하나요?"`로 닫혔다. 공통 지시가 `<<<data>>>`를 **신뢰하지 않는
    // 글**이라고 적어 두었으므로, 사용자 자신의 말이 그 구획에 들어가면 모델은
    // 그것을 쓰지 않는다. 구획은 이름을 가져야 하고, 그 이름이 지시에 있다.
    //
    // 구획 표시는 **위조되지 않는다**: 사용자의 말에서 `<`·`>`를 escape해
    // `<<<end>>>`를 글 안에서 만들 수 없게 한다(`DialogueHistoryWindow`와 같은 보호).
    let facts = knownFacts
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .prefix(Self.knownFactLimit)
      .map { fact -> String in
        let clipped =
          fact.count <= Self.knownFactCharacterLimit
          ? fact : String(fact.prefix(Self.knownFactCharacterLimit)) + "…"
        return clipped
          .replacingOccurrences(of: "<", with: "\\u003c")
          .replacingOccurrences(of: ">", with: "\\u003e")
      }
    if !facts.isEmpty {
      lines.append("<<<known>>>")
      lines.append(facts.joined(separator: "\n"))
      lines.append("<<<end>>>")
    }

    // **무엇이 이미 끝났는가.** 이 구획이 없으면 재계획은 이미 보낸 메일을 또
    // 계획한다(§12). 담는 것은 능력 이름과 결과 코드뿐이다.
    let recentlyCompleted = Self.clipped(completed)
    if !recentlyCompleted.isEmpty {
      lines.append("<<<completed>>>")
      lines.append(recentlyCompleted)
      lines.append("<<<end>>>")
    }

    // **덜 읽은 곳만 말한다.** 예전에는 모든 관찰의 진단(found/read/exhausted/
    // truncated/reason)을 최대 4,000자까지 실었다. 그 값으로 모델이 바꾸는 판단은
    // "덜 읽었으니 더 읽어라" 하나이고, 그 하나는 한 줄이면 된다 — 나머지는
    // 계획 호출마다 태우는 비용이었다.
    let incomplete = coverage.filter { $0.state != .complete || $0.truncated }
    if !incomplete.isEmpty {
      // **진단 문법을 문맥에 싣지 않는다.** `memory.read: unavailable read=0/0`을
      // 그대로 실었더니 모델이 그 줄을 **답으로 옮겨 적었다**(실기 2026-09-17,
      // iPhone: 답 자리에 그 한 줄이 섰다). 모델이 이 구획으로 바꾸는 판단은
      // "덜 읽었으니 더 읽어라" 하나이므로, 그 하나만 사람의 말 없이 적는다.
      let records = incomplete.map { record in
        record.readCount == 0 && record.discoveredCount == 0
          ? "a source could not be read"
          : "a source was read only in part (\(record.readCount) of \(record.discoveredCount))"
      }
      lines.append(
        UntrustedText(
          origin: "\(AgentHost.identity.citationScheme):coverage",
          Set(records).sorted().joined(separator: "\n")
        ).forModelContext(limit: Self.coverageCharacterLimit))
    }

    // **표시한 결과의 고정점.** `"그 메일"`이 무엇인지는 모델이 기억하는 것이
    // 아니라 우리가 적어 둔 이 목록이 정한다 — 적어 두지 않으면 식별자를
    // 지어내거나(그 식별자는 존재하지 않는다) 사용자에게 다시 묻는다(§4.4).
    //
    // **도구가 닫힌 단계에는 서지 않는다.** 고정점은 다음 단계의 인자를 어디서
    // 채울지에 대한 배선이고, 다음 단계가 없는 단계에는 쓸모가 없다. 근거에서
    // 식별자를 빼 놓고(`includeIdentifier`) 이 구획으로 다시 넣던 구조가 그
    // 모순이었다.
    if !anchoredSlots.isEmpty, profile.toolCalling != .disallowed {
      lines.append("<<<anchors>>>")
      lines.append(anchoredSlots.map(\.rawValue).joined(separator: "\n"))
      lines.append("<<<end>>>")
    }

    // **손에 들고 있는 기록.** 앞차례에 건넨 첨부가 여기 선다. 계획이 이 중
    // 하나를 고르면 `memory.read`가 기기에서 읽는다 — 사용자가 같은 파일을 다시
    // 올릴 이유가 사라진다(실기 2026-09-17: 다음 차례가 "값이 하나 더 필요해요"로
    // 닫혔다).
    //
    // 제목은 **사용자가 붙인 이름**이므로 데이터 평면이다. 식별자는 우리가 만든
    // 값이고 다음 단계의 인자이므로 도구가 열린 단계에만 선다.
    if !heldRecords.isEmpty, profile.toolCalling != .disallowed {
      let records = heldRecords.prefix(Self.heldRecordLimit).map { record in
        let title =
          record.title.count > Self.heldTitleCharacterLimit
          ? String(record.title.prefix(Self.heldTitleCharacterLimit)) + "…"
          : record.title
        return "id: \(record.itemID)\ntitle: \(title)"
      }
      lines.append("<<<held>>>")
      lines.append(
        UntrustedText(
          origin: "\(AgentHost.identity.citationScheme):held",
          records.joined(separator: "\n")
        ).forModelContext(limit: Self.heldCharacterLimit))
      lines.append("<<<end>>>")
    }

    // **근거는 정책이 허락할 때만 실린다.** 첫 계획은 아직 아무것도 회수하지
    // 않았고, 회수하지 않은 것을 문맥에 실을 자리를 두면 그 자리에 원문이 샌다.
    let carriesEvidence =
      profile.contextPolicy == .requestAndEvidence && !evidence.isEmpty
    if carriesEvidence {
      lines.append("<<<evidence>>>")
      // 답을 쓰는 단계는 다음 단계가 없다 — 식별자를 줄 이유도 없다.
      let identifiers = profile.phase != .finalizing
      for (offset, record) in evidence.prefix(Self.evidenceLimit).enumerated() {
        // **번호는 답 단계에만 붙는다.** 그 단계가 "이 중 무엇이 의도와 맞는가"를
        // 판정하고(`GeneratedFinalAnswer.relevant`), 그 판정의 열쇠가 이 번호다.
        // 계획 단계의 열쇠는 식별자이므로 번호를 붙일 이유가 없다.
        //
        // 번호는 데이터 구획 **밖에** 선다 — 우리가 센 값이고, 바깥에서 온 글이
        // 아니다(`Evidence.forModelContext`가 자기 구획을 감싼다).
        let body = record.forModelContext(includeIdentifier: identifiers)
        lines.append(identifiers ? body : "[\(offset + 1)]\n\(body)")
      }
      // 실기에서 **답이 무엇을 보았는지** 볼 유일한 창. `reminders.search`가 2건을
      // 돌려준 차례가 `"할 일이 보이지 않아요"`로 닫혔고(실기 2026-09-18), 그
      // 차이는 근거 구획 안에서만 보인다.
      if ProcessInfo.processInfo.environment["MORI_PLAN_TRACE"] == "1" {
        for (offset, record) in evidence.prefix(Self.evidenceLimit).enumerated() {
          let body = record.forModelContext(includeIdentifier: false)
            .replacingOccurrences(of: "\n", with: " ⏎ ")
          print("MORI-EVIDENCE [\(offset + 1)] \(body.prefix(300))")
        }
      }
      lines.append("<<<end>>>")
    }

    // **조립 구획도 자기 예산으로 검사한다.** 봉투 하나만 검사하면 한 구획이
    // 자란 것을 다른 구획의 여유가 가려 준다 — 그러면 `assembledCharacters`는
    // 이름만 남는다. `<<<request>>>`는 이 검사 뒤에 선다.
    let assembled = lines.reduce(0) { $0 + $1.count } + max(lines.count - 1, 0)
    guard assembled <= budget.assembledCharacters else {
      throw ContextCompilationError.assembledTooLarge(
        actual: assembled, limit: budget.assembledCharacters)
    }

    lines.append("<<<request>>>")
    lines.append(userMessage)
    lines.append("<<<end>>>")

    let context = CompiledConversationContext(
      instructions: instructions,
      prompt: lines.joined(separator: "\n"),
      phase: profile.phase,
      capabilities: capabilities,
      carriesEvidence: carriesEvidence,
      evidenceCount: carriesEvidence ? min(evidence.count, Self.evidenceLimit) : 0,
      calendar: calendar)

    // 구획마다 상한이 있어도 **합에 상한이 없으면** 구획이 하나 늘 때 조용히
    // 새 구멍이 난다. 예산은 구획 상한의 합이므로(`PCCContextBudget.assembled`)
    // 예산 없이 더한 구획은 이 자리에서 드러난다.
    guard context.estimatedCharacters <= budget.totalCharacters else {
      throw ContextCompilationError.contextTooLarge(
        actual: context.estimatedCharacters, limit: budget.totalCharacters)
    }
    return context
  }

  /// 끝난 일 구획을 상한 안으로. **새 줄을 남기고 오래된 줄을 버린다** — 방금
  /// 일어난 실패가 잘려 나가면 답이 그 실패를 말하지 못한다.
  private static func clipped(_ completed: String) -> String {
    guard completed.count > completedCharacterLimit else { return completed }
    var kept: [String] = []
    var total = 0
    for line in completed.split(separator: "\n").reversed() {
      let cost = line.count + (kept.isEmpty ? 0 : 1)
      guard total + cost <= completedCharacterLimit else { break }
      total += cost
      kept.append(String(line))
    }
    return kept.reversed().joined(separator: "\n")
  }
}
