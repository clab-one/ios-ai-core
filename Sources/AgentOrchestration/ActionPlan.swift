import AgentKernel
import Foundation
import FoundationModels


/// 모델이 채우는 **좁고 typed한 칸**.
///
/// PCC can answer, ask a contextual question, or propose capability calls.
/// DialogueResolution validates the output shape before execution validation.
/// Only ActionDispatcher can turn a valid proposal into an external effect.
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
      "reply for conversation, clarify for a missing user value, continue for tools, complete for an evidence-backed answer",
    .anyOf(["reply", "clarify", "continue", "complete"]))
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

  @Guide(description: "natural reply or one specific question for reply/clarify; empty for continue/complete")
  public let response: String

  public init(
    status: String, steps: [GeneratedActionStep], needs: String, response: String = ""
  ) {
    self.status = status
    self.steps = steps
    self.needs = needs
    self.response = response
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
  /// **창의 아래 끝이다.** 위 끝은 기기가 박는다(`WebSearchTool`의 `requestedAt`).
  ///
  /// `"최신"`을 시각 없는 말로 두면 이 자리가 비고, 빈 자리는 창을 세우지 않는다 —
  /// 그러면 `web.search`는 5년 전 문서를 "최신"으로 들고 온다. 그래서 새 지시문
  /// 블록을 더하는 대신 **이 한 줄을 바꿨다**: 문맥 구획은 계획 호출마다 실리고,
  /// 스키마 문구는 이미 실리고 있다.
  @Guide(
    description:
      "ISO 8601 start time; for web.search latest or recent, use a recent start; empty when no time constraint"
  )
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
  public let dialogue: DialogueResolution

  public init(status: Status, plan: ActionPlan, dialogue: DialogueResolution = .none) {
    self.status = status
    self.plan = plan
    self.dialogue = dialogue
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
  /// 읽을 사진. `photos.search`의 결과에서만 온다 — 보관함 식별자를 모델이
  /// 채우게 하면 지어내고, 그 값으로는 아무 사진도 열리지 않는다. 이 자리가
  /// 없던 동안 `"최근 사진 읽어 줘"`는 `photos.read`를 계획해 놓고 `photoID`를
  /// 되물었다(실기 2026-09-18, iPhone 15 Pro).
  case photoID
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

  /// 이 자리의 값이 **사람이 읽을 것이 아닌 손잡이**인가.
  ///
  /// 답을 쓰는 단계는 도구가 닫혀 있어 손잡이로 할 일이 없고, 받은 손잡이를
  /// 사실로 읽어 답에 적었다 — `"ID는 52C3E0B2-4A3A-…입니다."`(시뮬레이터 실측
  /// 2026-09-15 03:13). `Evidence.sourceID`는 그 실측 뒤에 막혔지만, 수령증의
  /// 딸린 값에서 사실 줄로 들어온 같은 값은 막히지 않았다.
  ///
  /// switch가 닫혀 있는 것이 이 값의 요점이다. 자리를 하나 더하면 **분류할
  /// 때까지 컴파일이 거부한다** — 분류하지 않은 자리가 조용히 통과하지 않는다.
  public var isOpaqueHandle: Bool {
    switch self {
    case .messageID, .channelID, .threadTS, .threadID, .messageIDHeader, .itemID,
      .eventID, .reminderID, .photoID:
      return true
    // 주소·주소창·사람이 쓴 글은 사용자가 말했거나 읽은 값이다. 답이 그것을
    // 되읽는 것은 누설이 아니라 §43이 요구하는 일이다.
    case .to, .url, .sourceText, .body:
      return false
    }
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
    let dialogue = DialogueResolution.resolve(
      status: generated.status, response: generated.response, needs: generated.needs,
      proposedStepCount: generated.steps.count)
    if dialogue != .none {
      // Never drop an invalid raw step and then accept the accompanying reply.
      return TurnDecision(status: .complete, plan: .empty, dialogue: dialogue)
    }
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
          PlannedStep(capability: .peopleResolve, arguments: ["query": .text(target)]))
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
    Self.trace(generated, steps: steps, needs: needs)
    return TurnDecision(status: resolved, plan: ActionPlan(steps: steps, needs: needs))
  }

  /// 실기에서 **계획을 볼 유일한 창**. 기기의 `os_log`는 Mac으로 중계되지 않고,
  /// 수령증은 실행한 것만 말한다 — 모델이 무엇을 골랐고 계약이 무엇을 받았는지는
  /// 이 줄에서만 보인다. 기본은 꺼짐이고 `MORI_PLAN_TRACE=1`로 켠다(시험 기기).
  private static let tracesPlans =
    ProcessInfo.processInfo.environment["MORI_PLAN_TRACE"] == "1"

  private static func trace(
    _ generated: GeneratedTurnDecision, steps: [PlannedStep], needs: String?
  ) {
    guard tracesPlans else { return }
    func short(_ value: String) -> String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.count <= 40 ? trimmed : String(trimmed.prefix(40)) + "…"
    }
    print(
      "MORI-PLAN status=\(generated.status) needs=\(short(generated.needs)) "
        + "response=\(generated.response.count) rawSteps=\(generated.steps.count)")
    for step in generated.steps {
      print(
        "MORI-PLAN raw \(step.capability) text=\(short(step.text)) "
          + "target=\(short(step.target)) when=\(short(step.when)) subject=\(short(step.subject))")
    }
    for step in steps {
      let arguments = step.arguments.keys.sorted().joined(separator: ",")
      print(
        "MORI-PLAN planned \(step.capability.rawValue) args=\(arguments) "
          + "unresolved=\(step.unresolved.sorted().joined(separator: ","))")
    }
    print("MORI-PLAN resolved needs=\(needs ?? "-") steps=\(steps.count)")
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
      if !text.isEmpty { arguments["body"] = .text(text) }
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
      // **자리 이름은 계약의 것이다**(`query`). `name`으로 담던 동안 연락처 조회는
      // 한 번도 돌지 않았다: 정규화가 모르는 이름을 버리고 `query` 없음으로
      // 거절했고, 차례는 `"어디에서 찾을까요?"`로 닫혔다(실기 2026-09-18,
      // iPhone 15 Pro: `"김철수 연락처 찾아줘"` → contacts.read 0회, pcc=2/2).
      if !target.isEmpty { arguments["query"] = .text(target) }
    case .photosRead:
      if !target.isEmpty { arguments["photoID"] = .text(target) }
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
      if !text.isEmpty { arguments["body"] = .text(text) }
    case .sharePublish, .shareRevoke:
      if !target.isEmpty { arguments["itemID"] = .text(target) }
    case .webRead, .webFetch, .contentIngest:
      // **주소는 문장에서 온다.** 이 자리가 없던 동안 `web.read`는 `default`로
      // 떨어져 URL이 `query`가 됐고, 계약은 `url` 없음으로 거절했다
      // (실기 2026-09-16: 툴이 하나도 돌지 않고 주소를 되물었다).
      if let url = Self.httpURL(target) ?? Self.httpURL(text) {
        arguments["url"] = .text(url)
      }
    case .textSummarize:
      // **줄일 원문은 앞 단계에서 온다**(`ResolvableArgument.sourceText`). 그래서
      // 이 칸에 모델이 쓰는 글은 원문이 아니라 **초점**이다 — `"가격만 정리해줘"`,
      // `"최신 변경사항만"`.
      //
      // 이 자리가 없던 동안 그 글은 `default`로 떨어져 `query`가 됐고, 계약에
      // 없는 자리이므로 정규화가 버렸다(`SummarizeTool.contracts`). 요약은 언제나
      // 초점 없이 돌았고, 사용자가 무엇을 물었는지는 요약기에 닿지 않았다.
      if !text.isEmpty { arguments["focus"] = .text(text) }
    case .textTranslate:
      // **옮길 원문은 앞 단계에서 온다**(`ResolvableArgument.sourceText`). 그래서
      // 이 칸에 모델이 쓰는 글은 원문이 아니라 **도착 언어**다. 비우면 툴이
      // 기기 설정 언어를 쓰고 그 사실을 수령증에 남긴다 — 여기서 언어를 지어내지
      // 않는다.
      if !text.isEmpty { arguments["targetLanguage"] = .text(text) }
    case .webSearch:
      if !text.isEmpty { arguments["query"] = .text(text) }
      // **모델이 말한 시각은 창의 아래 끝이다.** 위 끝은 오늘이고 그 값은 기기가
      // 박는다 — `"지난주부터 PCC 소식"`에서 모델이 줄 수 있는 것은 시작점뿐이다.
      if let when { arguments["after"] = .timestamp(when) }
    case .financeQuote:
      // **종목은 이름으로 온다.** `"hynix 가격"`의 `hynix`는 티커가 아니고,
      // 티커로 바꾸는 일은 공급자의 검색이 한다(`StocksTool`) — 모델이 티커를
      // 지어내면 다른 회사의 시세가 답이 된다.
      if !target.isEmpty { arguments["symbol"] = .text(target) }
      else if !text.isEmpty { arguments["symbol"] = .text(text) }
    case .weatherForecast:
      // **지역 이름은 `target`이 정석이지만 `text`에도 담긴다**(`.financeQuote`와
      // 같은 패턴). 이 케이스가 없던 동안 `default`가 `query` 키로 떨어졌고,
      // `WeatherTool.perform()`은 `place`를 읽으므로 이름이 달라 절대 채워지지
      // 않았다 — 실기 검증(2026-09-19, iPhone 15 Pro)에서 "서울 날씨 알려줘"가
      // 기기 GPS(강원)로 떨어지는 것으로 확인됐다. 비워 두면 툴이 기기 위치로
      // 폴백한다(의도된 동작, `WeatherTool.resolveCoordinate`).
      if !target.isEmpty { arguments["place"] = .text(target) }
      else if !text.isEmpty { arguments["place"] = .text(text) }
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
