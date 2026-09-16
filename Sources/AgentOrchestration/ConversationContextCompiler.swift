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
  public static let recentTurnLimit = 3
  /// 한 차례 줄의 글자 상한.
  public static let recentTurnCharacterLimit = 200
  /// 문맥에 싣는 근거 조각 수의 상한. 압축기가 이미 줄였고 이것은 마지막 방벽이다.
  public static let evidenceLimit = 8
  /// 덜 읽은 곳을 말하는 한 줄의 상한.
  public static let coverageCharacterLimit = 300
  /// 끝난 일 구획의 상한. 넘으면 **오래된 줄부터** 버린다 — 방금 일어난 실패가
  /// 남아야 답이 그 사실을 말한다(§2.6·§10.1).
  public static let completedCharacterLimit = 600

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
    return "\(stamp) (\(timeZone.identifier))"
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
    completed: String = "",
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

    if !recentTurns.isEmpty {
      lines.append("<<<recent>>>")
      for message in recentTurns.suffix(Self.recentTurnLimit) {
        // 역할을 낱말로 붙인다. 역할 없이 이어 붙이면 조수의 앞 답이 사용자의
        // 지시처럼 읽힌다.
        let text =
          message.text.count > Self.recentTurnCharacterLimit
          ? String(message.text.prefix(Self.recentTurnCharacterLimit)) + "…"
          : message.text
        lines.append("\(message.role.rawValue): \(text)")
      }
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
      let records = incomplete.map { record in
        "\(record.capability.rawValue): \(record.state.rawValue) read=\(record.readCount)/\(record.discoveredCount)"
      }
      lines.append(
        UntrustedText(
          origin: "\(AgentHost.identity.citationScheme):coverage",
          records.joined(separator: "\n")
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
      lines.append("<<<end>>>")
    }

    lines.append("<<<request>>>")
    lines.append(userMessage)
    lines.append("<<<end>>>")

    let context = CompiledConversationContext(
      instructions: profile.instructions,
      prompt: lines.joined(separator: "\n"),
      phase: profile.phase,
      capabilities: capabilities,
      carriesEvidence: carriesEvidence,
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
