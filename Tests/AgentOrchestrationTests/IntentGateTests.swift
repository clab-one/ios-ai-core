import AgentKernel
import XCTest

@testable import AgentOrchestration

/// L0 — **결정론으로 끝나는 차례는 모델을 부르지 않는다**
/// (`docs/AGENT_RUNTIME_DESIGN.ko.md` §책임 경계, `REMAINING_WORK.ko.md` P0
/// "Intent Gate와 결정론 실행 경로").
///
/// 이 문의 위험은 둘이다: 잡아야 할 것을 놓치는 것(비용은 PCC 한 번)과, **잡으면
/// 안 되는 것을 잡는 것**(비용은 사용자가 시킨 일을 안 하는 것). 아래 시험은
/// 두 번째를 더 많이 본다.
final class IntentGateTests: XCTestCase {
  private static let scope = CapabilityScope(capabilities: [.calendarSearch, .calendarCreate])
  private static var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
    return value
  }
  private static let now = Date(timeIntervalSince1970: 1_789_000_000)

  private func route(_ input: String, scope: CapabilityScope = IntentGateTests.scope)
    -> IntentGate.Route?
  {
    IntentGate.route(
      input: input, scope: scope, now: Self.now, calendar: Self.calendar)
  }

  func testTodaysScheduleBecomesAReadOnlyCalendarStep() throws {
    let routed = try XCTUnwrap(route("오늘 일정 뭐 있어?"))
    XCTAssertEqual(routed.steps.map(\.capability), [.calendarSearch])
    XCTAssertEqual(routed.reason, "calendar.today")
    let step = try XCTUnwrap(routed.steps.first)
    XCTAssertEqual(step.capability.executionClass, .readOnly, "이 문은 읽기 전용만 통과시킨다")
    // 인자는 기기 시각에서 온다 — 문장에서 긁어낸 문자열이 아니다.
    XCTAssertNotNil(step.arguments["start"]?.dateValue)
    XCTAssertNotNil(step.arguments["end"]?.dateValue)
    XCTAssertNil(step.arguments["query"], "문장을 질의로 흘리면 이 문은 파서가 된다")
  }

  func testNextEventAsksForASingleUpcomingRow() throws {
    let routed = try XCTUnwrap(route("다음 일정 뭐야"))
    XCTAssertEqual(routed.reason, "calendar.next")
    XCTAssertEqual(routed.steps.first?.arguments["limit"]?.numberValue, 1)
  }

  /// **같은 명사, 다른 일.** 만들어 달라는 요청은 이 문을 지나면 안 된다.
  func testWriteRequestsNeverPassTheGate() {
    for input in [
      "내일 일정 만들어줘", "오늘 일정에 회의 추가해줘", "내일 일정 취소해줘",
      "오늘 일정 정리해서 메일 보내줘", "schedule a meeting tomorrow",
    ] {
      XCTAssertNil(route(input), "쓰기 요청이 결정론 읽기로 잡혔다: \(input)")
    }
  }

  /// 모르는 조건이 붙은 문장은 통과시키지 않는다 — 오판의 비용을 계획 경로로 넘긴다.
  func testLongerRequestsFallThroughToPlanning() {
    XCTAssertNil(route("오늘 일정 중에 회의만 빼고 정리해서 알려줘 그리고 내일 것도 같이"))
  }

  /// 손이 없는 능력으로 길을 만들지 않는다.
  func testGateNeedsTheCapabilityToBeRegistered() {
    XCTAssertNil(route("오늘 일정 뭐 있어?", scope: CapabilityScope(capabilities: [.memoryRead])))
  }

  /// **승격에는 이유가 있다.** 문이 잡지 못한 차례는 왜 올라갔는지를 값으로 든다.
  func testDeclinedTurnsCarryAnEscalationReason() {
    let cases: [(String, String)] = [
      ("내일 일정 만들어줘", "writeVerb"),
      ("안녕", "unmatched"),
      ("다음 달 일정", "windowUnknown"),
      ("오늘 일정 중에 회의만 빼고 정리해서 알려줘 그리고 내일 것도", "tooLong"),
    ]
    for (input, expected) in cases {
      let decision = IntentGate.decide(
        input: input, scope: Self.scope, now: Self.now, calendar: Self.calendar)
      XCTAssertEqual(decision, .escalate(reason: expected), "입력: \(input)")
    }
  }

  /// 주 경계는 달력이 정한다 — 이 문이 "월요일 시작"을 단정하지 않는다.
  func testThisWeekUsesTheCalendarsOwnWeekBoundary() throws {
    let routed = try XCTUnwrap(route("이번 주 일정"))
    XCTAssertEqual(routed.reason, "calendar.thisWeek")
    let step = try XCTUnwrap(routed.steps.first)
    let start = try XCTUnwrap(step.arguments["start"]?.dateValue)
    let end = try XCTUnwrap(step.arguments["end"]?.dateValue)
    let week = try XCTUnwrap(Self.calendar.dateInterval(of: .weekOfYear, for: Self.now))
    XCTAssertEqual(start, week.start)
    XCTAssertEqual(end, week.end)
  }

  /// **종단: 이 차례에 모델은 한 번도 불리지 않는다.** 계획도, 답도.
  @available(iOS 26.0, *)
  @MainActor
  func testGatedTurnCallsNoModelAtAll() async {
    AgentHost.configure(AgentHostIdentity(bundleIdentifier: "dev.example.agenttests"))
    let dispatcher = ActionDispatcher(ledger: ScenarioLedger(), currentAccountID: { "acct" })
    await dispatcher.register(
      FixtureTool(.calendarSearch, required: []) { _ in
        [CapabilitySourceRow(title: "치과", subtitle: "오후 3시", body: "", identifier: "evt-1")]
      })
    var presented: ConversationTurnResult?
    var planningCalls = 0
    var finalizingCalls = 0
    let runtime = TurnRuntime(
      dispatcher: dispatcher,
      emit: { _ in },
      present: { presented = $0 },
      copy: .keysAsText,
      now: { ScenarioRunner.now },
      supervising: { _ in
        planningCalls += 1
        return .failed(
          disposition: .surfaceFailure, reason: "unexpected",
          ModelInvocationTrail(outcome: Self.modelReceipt))
      },
      finalizing: { _, _ in
        finalizingCalls += 1
        return FinalizationStep(
          answer: .unavailable(reason: "unexpected"),
          trail: ModelInvocationTrail(outcome: Self.modelReceipt))
      })
    await runtime.run(
      TurnContextSnapshot(
        requestID: UUID(), accountID: "acct", conversationID: "conv",
        input: "오늘 일정 뭐 있어?", recentMessages: [], submittedAt: ScenarioRunner.now,
        registeredCapabilities: [.calendarSearch]))

    XCTAssertEqual(planningCalls, 0, "결정론으로 끝나는 차례가 계획을 물었다")
    XCTAssertEqual(finalizingCalls, 0, "결정론으로 끝나는 차례가 답을 모델에게 맡겼다")
    XCTAssertEqual(presented?.steps.map(\.capability), [.calendarSearch])
    XCTAssertEqual(presented?.telemetry.pccCalls, 0, "PCC 호출이 계측에 남았다")
    XCTAssertEqual(presented?.telemetry.profile, "deterministic")
    XCTAssertTrue(
      presented?.telemetry.contextCharactersByPhase.isEmpty ?? false,
      "모델 문맥을 조립한 흔적이 남았다 — 결정론 차례는 문맥을 만들지도 않는다")
    XCTAssertEqual(presented?.telemetry.interventionReason, "gate:calendar.today")
  }

  private static let modelReceipt = ModelInvocationReceipt(
    phase: .planning, purpose: AdmissionJob.conversationPlan.rawValue,
    requestedBackend: .privateCloud, resolvedBackend: .privateCloud,
    pccAttempted: true, pccCompleted: true, onDeviceAttempted: false,
    onDeviceCompleted: false, fallbackReason: nil, inputCharacters: 0,
    latencyMilliseconds: 0)
}
