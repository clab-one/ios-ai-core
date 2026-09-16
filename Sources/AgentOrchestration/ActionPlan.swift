import AgentKernel
import Foundation
import FoundationModels


/// 모델이 채우는 **좁고 typed한 칸**.
///
/// 모델에게 문장을 쓰게 하지 않는다. 능력 이름과 인자 몇 개만 채우게 하고, 그
/// 값을 코드가 검증해 `ActionRequest`로 옮긴다 — 오판이 저장소·EventKit·Gmail에
/// 닿기 전에 한 겹의 검사가 있다는 뜻이다.
///
/// `status`가 이 칸의 새 자리다. 감독자는 매 되돌이마다 **더 할 일이 있는가**를
/// 함께 말해야 한다(§11·§22) — 그 값이 없으면 loop를 멈출 근거가 "단계가 비었다"
/// 하나뿐이고, 그 하나는 모델이 실수로 빈 목록을 낸 경우와 구별되지 않는다.
///
/// 단계 상한은 넷이다. 셋이던 동안 `chat.search → chat.read → people.resolve →
/// mail.send`처럼 평범한 조합이 마지막 단계를 잃었다. 더 키우지 않는 이유는
/// 상한을 늘리는 대신 **되돌이로 나누는 것**이 이 구조의 답이기 때문이다(§30).
@available(iOS 26.0, *)
@Generable
public struct GeneratedTurnDecision {
  @Guide(
    description:
      "continue when more capabilities must run, complete when the evidence already answers the request",
    .anyOf(["continue", "complete"]))
  public let status: String
  @Guide(
    description:
      "every capability to run, in order, including the final send or create step",
    .maximumCount(5))
  public let steps: [GeneratedActionStep]
  @Guide(
    description:
      "value the user must still provide, empty when nothing is missing")
  public let needs: String

  public init(status: String, steps: [GeneratedActionStep], needs: String) {
    self.status = status
    self.steps = steps
    self.needs = needs
  }
}

@available(iOS 26.0, *)
@Generable
public struct GeneratedActionStep {
  @Guide(description: "exact capability name from the provided list")
  public let capability: String
  @Guide(description: "search text, title, or message body; empty when not needed")
  public let text: String
  @Guide(
    description:
      "person name, email address, or channel the user named; empty when not needed")
  public let target: String
  @Guide(description: "ISO 8601 date-time, empty when the user did not say one")
  public let when: String
  @Guide(description: "mail subject line, empty for anything that is not mail")
  public let subject: String

  public init(
    capability: String, text: String, target: String, when: String, subject: String
  ) {
    self.capability = capability
    self.text = text
    self.target = target
    self.when = when
    self.subject = subject
  }
}

/// 실행 한 단계. 아직 `ActionRequest`가 아니다 — 앞 단계의 결과에서 채워야 하는
/// 자리가 남아 있을 수 있다.
///
/// 그 자리를 모델이 채우게 하지 않는 이유는 하나다: 모델은 메일 id를 알 수 없고,
/// 모르는 값을 요구받으면 **지어낸다**. 식별자는 앞 단계의 수령증에서만 온다.
public struct PlannedStep: Sendable, Equatable {
  public let capability: CapabilityID
  public let arguments: [String: ActionValue]
  /// 앞 단계의 수령증에서 채워야 하는 자리 이름들.
  public let unresolved: [String]
  /// Assigned by the host from an observed source, never from model arguments.
  public let binding: ConnectorBindingID?

  public init(
    capability: CapabilityID, arguments: [String: ActionValue], unresolved: [String] = [],
    binding: ConnectorBindingID? = nil
  ) {
    self.capability = capability
    self.arguments = arguments
    self.unresolved = unresolved
    self.binding = binding
  }
}

/// 검증을 통과한 계획. **여기부터는 문자열이 아니라 능력이다.**
public struct ActionPlan: Sendable, Equatable {
  public let steps: [PlannedStep]
  /// 조사 후에도 필요한 사용자 값. 런타임은 쓰기를 보류하고 가능한 읽기를 먼저 수행한다.
  public let needs: String?

  public init(steps: [PlannedStep], needs: String?) {
    self.steps = steps
    self.needs = needs
  }

  public static let empty = ActionPlan(steps: [], needs: nil)
}

/// 감독자의 한 되돌이 결과. **계획과 종료 판정이 한 값**이다.
///
/// 둘을 따로 들면 "단계가 비었다"가 두 가지 뜻을 갖는다: 다 끝났다, 또는 모델이
/// 아무것도 고르지 못했다. 그 둘을 구별하지 못하는 loop는 끝나지 않거나 너무
/// 일찍 끝난다(§22).
public struct TurnDecision: Sendable, Equatable {
  public enum Status: String, Sendable {
    /// 더 부를 것이 있다.
    case working
    /// 근거가 요청을 닫았다. 이제 답을 쓴다.
    case complete

    public init(raw: String) {
      self =
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "complete"
        ? .complete : .working
    }
  }

  public let status: Status
  public let plan: ActionPlan

  public init(status: Status, plan: ActionPlan) {
    self.status = status
    self.plan = plan
  }

  /// 이 되돌이가 실행할 것이 있는가.
  public var hasWork: Bool { !plan.steps.isEmpty }

  public static let complete = TurnDecision(status: .complete, plan: .empty)
}

/// 앞 단계의 결과에서 채울 수 있는 자리.
///
/// 목록이 **닫혀 있다**는 점이 이 타입의 전부다. 여기 없는 자리는 앞 단계에서
/// 채워지지 않고, 그러면 사용자에게 되묻는다 — 받는 사람과 본문이 그렇다.
public enum ResolvableArgument: String, Sendable, CaseIterable {
  case to
  case messageID
  case channelID
  case threadTS
  case threadID
  case messageIDHeader
  case itemID
  case eventID
  case reminderID
  /// 읽을 주소. `web.search`의 결과에서만 온다 — 검색 뒤 읽기가 감독 되돌이의
  /// 가장 흔한 두 단계이고, 그 주소를 모델이 채우게 하면 지어낸다.
  case url
  /// 줄일 원문. **앞 단계가 읽은 것**에서 온다.
  ///
  /// 이 자리가 있어야 `web.read → text.summarize → mail.send`가 성립한다. 원문을
  /// 모델이 채우는 자리로 두면 PCC 문맥에 페이지 전문이 실리고(비용), 그 글이
  /// 기기를 떠난다(프라이버시) — 줄이는 일은 기기 모델이 한다.
  case sourceText
  /// 보낼 본문. **앞 단계가 만든 글**에서만 온다(`text.summarize`의 산출).
  ///
  /// 읽은 원문을 그대로 본문에 싣지 않는다. 사용자가 "요약해서 보내"라고 했을 때
  /// 보내야 하는 것은 요약이고, 원문 전체를 보내는 것은 다른 일이다.
  case body

  public static func isResolvable(_ key: String) -> Bool {
    ResolvableArgument(rawValue: key) != nil
  }
}

@available(iOS 26.0, *)
public enum ActionPlanValidator {
  /// 모델 산출을 실행 가능한 결정으로 옮긴다.
  ///
  /// 목록 밖 능력과 잘못된 실행 단계를 버리고, 관찰에서 채울 참조는 보존한다.
  /// 남은 누락값과 유효한 단계를 함께 넘긴다. 누락이 있을 때 실행할 읽기는
  /// 런타임이 고르고 쓰기는 보류한다.
  ///
  /// `allowed`는 이 되돌이의 `CapabilityScope`다. 범위 밖의 이름은 조용히 버린다 —
  /// 모델이 범위 밖을 골랐다는 사실은 실행할 이유가 아니라 버릴 이유다.
  public static func validate(
    _ generated: GeneratedTurnDecision,
    allowed: [CapabilityID],
    conversationID: String?,
    accountID: String,
    calendar: Calendar
  ) -> TurnDecision {
    let status = TurnDecision.Status(raw: generated.status)
    let allowedSet = Set(allowed.map(\.rawValue))
    var steps: [PlannedStep] = []
    var missing: [String] = generated.needs.trimmingCharacters(
      in: .whitespacesAndNewlines
    ).isEmpty ? [] : [generated.needs]

    for step in generated.steps {
      let name = step.capability.trimmingCharacters(in: .whitespacesAndNewlines)
      guard allowedSet.contains(name) else { continue }
      let capability = CapabilityID(name)
      let target = step.target.trimmingCharacters(in: .whitespacesAndNewlines)

      // 이름으로 보내라는 요청은 **연락처 조회를 먼저 세운다.** 모델이 주소를
      // 지어낼 수 있는 자리가 바로 여기고, 조회를 한 단계로 세우면 그 조회의
      // 실패가 화면에 보인다("그 이름으로 한 사람을 찾지 못했어요").
      //
      // **이미 조회가 계획에 있으면 끼워 넣지 않는다.** 두 번 서면 뒤엣것이
      // 조사 붙은 이름(`"지민에게"`)으로 실패하고, `.to` 해석은 같은 능력의
      // 마지막 시도를 보므로 앞의 성공이 무효가 된다 — 그래서 전송이 인자를
      // 못 채우고 죽었다(실기 2026-09-16 시나리오 2).
      let alreadyResolving = steps.contains { $0.capability == .peopleResolve }
      if Self.needsContactResolution(capability, target: target),
        !alreadyResolving,
        allowedSet.contains(CapabilityID.peopleResolve.rawValue)
      {
        steps.append(
          PlannedStep(capability: .peopleResolve, arguments: ["name": .text(target)]))
      }

      let arguments = Self.arguments(for: capability, step: step, calendar: calendar)
      switch CapabilityContract.normalize(arguments, for: capability) {
      case .success(let normalized):
        steps.append(PlannedStep(capability: capability, arguments: normalized))
      case .failure(let violation):
        guard case .missing(let keys) = violation else {
          missing.append(violation.reason)
          continue
        }
        let resolvable = keys.filter { ResolvableArgument.isResolvable($0) }
        guard resolvable.count == keys.count else {
          // 앞 단계에서 올 수 없는 자리가 비어 있다 — 사용자만 줄 수 있다.
          missing.append(keys.sorted().first ?? violation.reason)
          continue
        }
        steps.append(
          PlannedStep(
            capability: capability, arguments: arguments.filter { !keys.contains($0.key) },
            unresolved: resolvable.sorted()))
      }
    }

    let needs = missing.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    // **고를 것이 있으면 아직 끝난 것이 아니다.** 모델이 `complete`를 말하면서
    // 단계를 함께 내는 경우가 있고, 그때 단계를 버리면 사용자가 시킨 일이 반만
    // 일어난다. 실행이 남아 있다는 관찰이 모델의 말보다 앞선다.
    let resolved: TurnDecision.Status = steps.isEmpty ? status : .working
    return TurnDecision(status: resolved, plan: ActionPlan(steps: steps, needs: needs))
  }

  /// 이름만 준 전송인가. 주소(`@`)를 줬다면 조회는 필요 없다.
  private static func needsContactResolution(
    _ capability: CapabilityID, target: String
  ) -> Bool {
    guard capability == .mailSend || capability == .mailReply else { return false }
    guard !target.isEmpty else { return false }
    return !target.contains("@")
  }

  /// 모델의 좁은 칸을 능력의 인자 이름으로 옮긴다. **능력마다 다른 이름**을 쓰는
  /// 이유는 어댑터가 그 이름을 요구하기 때문이다(`CapabilityContract`).
  private static func arguments(
    for capability: CapabilityID, step: GeneratedActionStep, calendar: Calendar
  ) -> [String: ActionValue] {
    let text = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let target = step.target.trimmingCharacters(in: .whitespacesAndNewlines)
    let subject = step.subject.trimmingCharacters(in: .whitespacesAndNewlines)
    let when = Self.date(step.when, timeZone: calendar.timeZone)
    var arguments: [String: ActionValue] = [:]

    switch capability {
    case .memorySearch, .artifactFind, .mailSearch, .chatSearch, .remindersSearch:
      if !text.isEmpty { arguments["query"] = .text(text) }
    case .memorySave:
      if !text.isEmpty { arguments["text"] = .text(text) }
    case .memoryRead, .artifactRead, .contentRead, .contentSummarize, .recordingRead:
      // 식별자는 `target`이 정석이지만 모델은 파일 이름·기록 제목을 `text`에
      // 담기도 한다. 둘 다 받는다 — 받지 않으면 계약이 `itemID` 없음으로 거절하고,
      // 화면은 "어느 기록을 말하는 걸까요?"를 띄운다(실기 2026-09-16 PDF·MD 시나리오).
      if !target.isEmpty { arguments["itemID"] = .text(target) }
      else if !text.isEmpty { arguments["itemID"] = .text(text) }
    case .calendarSearch:
      if let when {
        let start = calendar.startOfDay(for: when)
        arguments["start"] = .timestamp(start)
        arguments["end"] = .timestamp(
          calendar.date(byAdding: .day, value: 1, to: start) ?? start)
      }
      if !text.isEmpty { arguments["query"] = .text(text) }
    case .calendarCreate:
      if !text.isEmpty { arguments["title"] = .text(text) }
      if let when { arguments["start"] = .timestamp(when) }
    case .calendarUpdate, .calendarDelete:
      if !target.isEmpty { arguments["eventID"] = .text(target) }
      if !text.isEmpty, capability == .calendarUpdate { arguments["title"] = .text(text) }
      if let when, capability == .calendarUpdate { arguments["start"] = .timestamp(when) }
    case .remindersCreate:
      if !text.isEmpty { arguments["title"] = .text(text) }
      if let when {
        arguments["due"] = .timestamp(when)
        arguments["hasClockTime"] = .flag(true)
      }
    case .remindersComplete, .remindersDelete, .remindersUpdate:
      if !target.isEmpty { arguments["reminderID"] = .text(target) }
      if !text.isEmpty { arguments["title"] = .text(text) }
    case .peopleResolve, .contactsRead:
      if !target.isEmpty { arguments["name"] = .text(target) }
      else if !text.isEmpty { arguments["name"] = .text(text) }
    case .mailRead:
      if !target.isEmpty { arguments["messageID"] = .text(target) }
    case .mailSend, .mailReply:
      // 주소를 준 경우에만 담는다. 이름만 줬다면 연락처 조회가 앞에 서고
      // (`needsContactResolution`), 이 자리는 그 결과로 채워진다.
      if target.contains("@") { arguments["to"] = .text(target) }
      if !text.isEmpty { arguments["body"] = .text(text) }
      if !subject.isEmpty { arguments["subject"] = .text(subject) }
    case .chatRead:
      if !target.isEmpty { arguments["channelID"] = .text(target) }
    case .chatSend, .chatReply:
      if !target.isEmpty { arguments["channelID"] = .text(target) }
      if !text.isEmpty { arguments["text"] = .text(text) }
    case .sharePublish, .shareRevoke:
      if !target.isEmpty { arguments["itemID"] = .text(target) }
    case .webRead, .webFetch, .contentIngest:
      // **주소는 문장에서 온다.** 이 자리가 없던 동안 `web.read`는 `default`로
      // 떨어져 URL이 `query`가 됐고, 계약은 `url` 없음으로 거절했다
      // (실기 2026-09-16: 툴이 하나도 돌지 않고 주소를 되물었다).
      if let url = Self.httpURL(target) ?? Self.httpURL(text) {
        arguments["url"] = .text(url)
      }
    case .webSearch:
      if !text.isEmpty { arguments["query"] = .text(text) }
    default:
      if !text.isEmpty { arguments["query"] = .text(text) }
    }
    return arguments
  }

  /// 문자열 하나에서 **명시된 http(s) 주소**만 꺼낸다.
  ///
  /// 모델은 주소를 문장에 섞어 담는다(`"이 페이지 https://… 요약"`). 도메인 언급을
  /// 주소로 승격하지 않는 것이 요점이다 — `apple.com`을 말한 문장이 페이지 읽기로
  /// 바뀌면 사용자가 요청하지 않은 네트워크 호출이 된다(`LinkText.firstExplicitURL`).
  private static func httpURL(_ raw: String) -> String? {
    guard !raw.isEmpty, let url = LinkText.firstExplicitURL(in: raw),
      url.scheme == "http" || url.scheme == "https"
    else { return nil }
    return url.absoluteString
  }

  /// 모델이 낸 시각 문자열 하나.
  ///
  /// 오프셋 없는 시각은 제출 시 캡처한 현지 시각이다.
  /// 오프셋이 적혀 있으면 그 오프셋을 우선한다.
  private static func date(_ raw: String, timeZone: TimeZone) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if Self.carriesOffset(trimmed), let parsed = try? Date(trimmed, strategy: .iso8601) {
      return parsed
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    for format in [
      "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
    ] {
      formatter.dateFormat = format
      if let parsed = formatter.date(from: trimmed) { return parsed }
    }
    // 지원하는 다른 ISO 형식도 같은 timezone으로 해석한다.
    return try? Date(trimmed, strategy: Date.ISO8601FormatStyle(timeZone: timeZone))
  }

  /// 이 문자열이 **자기 오프셋을 들고 있는가.** `Z`이거나 `+09:00`·`-0500`이다.
  private static func carriesOffset(_ text: String) -> Bool {
    if text.hasSuffix("Z") || text.hasSuffix("z") { return true }
    return text.range(
      of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
  }
}
