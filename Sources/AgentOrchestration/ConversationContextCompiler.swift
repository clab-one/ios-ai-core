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

  public func compile(
    profile: DynamicTurnProfile,
    userMessage: String,
    recentTurns: [ConversationMessage] = [],
    evidence: [Evidence] = [],
    coverage: [CoverageRecord] = [],
    /// 이 대화가 **이미 표시한 결과**의 고정점(§4.4). `"그 메일"`·`"1번"`은 여기서
    /// 풀린다 — 이 구획이 없으면 모델이 식별자를 지어내거나 사용자에게 되묻는다.
    anchors: [String] = [],
    completed: String = "",
    now: Date = Date(),
    calendar: Calendar
  ) -> CompiledConversationContext {
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
    if !completed.isEmpty {
      lines.append("<<<completed>>>")
      lines.append(completed)
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
        ).forModelContext(limit: 300))
    }

    // **표시한 결과의 고정점.** `"그 메일"`이 무엇인지는 모델이 기억하는 것이
    // 아니라 우리가 적어 둔 이 목록이 정한다 — 적어 두지 않으면 식별자를
    // 지어내거나(그 식별자는 존재하지 않는다) 사용자에게 다시 묻는다(§4.4).
    if !anchors.isEmpty {
      lines.append("<<<anchors>>>")
      lines.append(anchors.joined(separator: "\n"))
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

    return CompiledConversationContext(
      instructions: profile.instructions,
      prompt: lines.joined(separator: "\n"),
      phase: profile.phase,
      capabilities: capabilities,
      carriesEvidence: carriesEvidence,
      calendar: calendar)
  }
}
