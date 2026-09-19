import AgentKernel
import XCTest

@testable import AgentOrchestration

/// L0 — **단계별 문맥 크기를 실측으로 남긴다**
/// (`docs/AGENT_RUNTIME_DESIGN.ko.md` §ContextBroker).
///
/// 설계는 단계마다 목표치를 적었지만, 지금까지 계측에 있던 값은 모든 호출의
/// 합(`inputCharacters`)뿐이었다 — 어느 단계가 큰지 말하지 못하는 숫자로는
/// 줄일 자리를 고를 수 없다.
@available(iOS 26.0, *)
@MainActor
final class ContextMeasurementTests: XCTestCase {
  func testPlanningAndFinalizingSizesAreRecordedSeparately() async throws {
    let result = await Self.runSupervisedTurn()
    let presented = try XCTUnwrap(result)
    let sizes = presented.telemetry.contextCharactersByPhase
    let planning = try XCTUnwrap(sizes[TurnPhase.planning.rawValue], "계획 단계 크기가 없다")
    let finalizing = try XCTUnwrap(sizes[TurnPhase.finalizing.rawValue], "답 단계 크기가 없다")
    XCTAssertGreaterThan(planning, 0)
    XCTAssertGreaterThan(finalizing, 0)
    // 두 단계는 서로 다른 문맥이다. 한 칸에 덮어쓰던 예전 계측으로 되돌아가지 않는다.
    XCTAssertNotEqual(planning, finalizing, "두 단계가 같은 칸을 덮어쓰고 있다")
    XCTAssertLessThanOrEqual(
      finalizing, PCCContextBudget.standard.assembledCharacters,
      "조립된 문맥이 예산을 넘었는데 호출이 나갔다")
    XCTAssertEqual(
      presented.telemetry.escalationReason, "unmatched",
      "모델까지 올라간 차례가 이유를 남기지 않았다")
  }

  private static func runSupervisedTurn() async -> ConversationTurnResult? {
    AgentHost.configure(AgentHostIdentity(bundleIdentifier: "dev.example.agenttests"))
    let dispatcher = ActionDispatcher(ledger: ScenarioLedger(), currentAccountID: { "acct" })
    await dispatcher.register(
      FixtureTool(.memorySearch, required: [.init("query")]) { _ in
        [CapabilitySourceRow(title: "여권", body: "만료는 2027년 3월이다.", identifier: "doc-1")]
      })
    var presented: ConversationTurnResult?
    let runtime = TurnRuntime(
      dispatcher: dispatcher,
      emit: { _ in },
      present: { presented = $0 },
      copy: .keysAsText,
      now: { ScenarioRunner.now },
      supervising: { _ in
        .decided(
          TurnDecision(
            status: .working,
            plan: ActionPlan(
              steps: [PlannedStep(capability: .memorySearch, arguments: ["query": .text("여권")])],
              needs: nil)),
          ModelInvocationTrail(outcome: Self.receipt(.planning)))
      },
      finalizing: { _, _ in
        FinalizationStep(
          answer: .written(
            headline: "만료는 2027년 3월입니다.", points: [], relevant: [], backend: .privateCloud),
          trail: ModelInvocationTrail(outcome: Self.receipt(.finalizing)))
      })
    await runtime.run(
      TurnContextSnapshot(
        requestID: UUID(), accountID: "acct", conversationID: "conv",
        input: "여권 만료 알려줘", recentMessages: [], submittedAt: ScenarioRunner.now,
        registeredCapabilities: [.memorySearch]))
    return presented
  }

  private static func receipt(_ phase: TurnPhase) -> ModelInvocationReceipt {
    ModelInvocationReceipt(
      phase: phase, purpose: AdmissionJob.conversationPlan.rawValue,
      requestedBackend: .privateCloud, resolvedBackend: .privateCloud,
      pccAttempted: true, pccCompleted: true, onDeviceAttempted: false,
      onDeviceCompleted: false, fallbackReason: nil, inputCharacters: 0,
      latencyMilliseconds: 0)
  }
}
