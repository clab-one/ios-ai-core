import AgentKernel
import XCTest

@testable import AgentOrchestration

/// L0 — **읽었으면 요약한다.**
///
/// 실기 2026-09-19: 위키백과 URL + `"요약해줘"`가 `web.read` 하나로 끝났고, 화면에
/// 선 것은 근거 세 줄로 쓴 모델 문장뿐이었다 — 요약문은 어디에도 없었다. 계획
/// 지시문을 늘리는 대신(예산이 깨진 전례가 있다) 런타임이 다음 단계를 잇는다.
@available(iOS 26.0, *)
@MainActor
final class SummaryInvariantTests: XCTestCase {
  func testReadWithoutSummarizeGetsSummarizeAppended() async throws {
    let run = try await Self.run(input: "https://example.com/article 요약해줘")
    XCTAssertEqual(
      run.steps.map(\.capability), [.webRead, .textSummarize],
      "읽기만 하고 끝났다 — 요약문이 화면에 설 수 없다")
    XCTAssertEqual(run.interventionReason, "dependency:text.summarize")
  }

  /// 요약을 말하지 않은 차례에 요약을 끼우지 않는다 — 시키지 않은 일이다.
  func testPlainReadStaysAReadTurn() async throws {
    let run = try await Self.run(input: "https://example.com/article 읽어줘")
    XCTAssertEqual(run.steps.map(\.capability), [.webRead])
  }

  /// 감독자가 **할 일 없음**을 냈다고 손에 들려 준 주소가 사라지지 않는다.
  ///
  /// 실기 2026-09-19: 같은 대화에서 앞 차례에 읽은 주소라는 문맥을 보고 계획이
  /// 도구 0개로 `complete`를 냈고, 차례는 조립으로 직행해 `"요약은 제공된 내용에
  /// 포함되어 있지 않습니다"`로 닫혔다 — 아무것도 읽지 않은 채였다.
  func testCompleteWithoutWorkStillReadsAndSummarizes() async throws {
    let run = try await Self.run(
      input: "https://example.com/article 요약해줘", plan: .complete)
    XCTAssertEqual(
      run.steps.map(\.capability), [.webRead, .textSummarize],
      "계획이 비어도 주소는 읽히고 요약은 선다")
  }

  /// 주소도 첨부도 없는 차례에서 `complete`는 그대로 끝난다 — 위 보정이 빈손
  /// 차례에 일을 만들어 내지 않는다.
  func testCompleteWithNothingToReadStaysEmpty() async throws {
    let run = try await Self.run(input: "고마워", plan: .complete)
    XCTAssertTrue(run.steps.isEmpty)
  }

  /// 감독자가 낸 계획의 두 모습.
  private enum Plan { case readsPage, complete }

  private struct Run {
    let steps: [ConversationTurnResult.Step]
    let interventionReason: String
  }

  private static func run(input: String, plan: Plan = .readsPage) async throws -> Run {
    AgentHost.configure(AgentHostIdentity(bundleIdentifier: "dev.example.agenttests"))
    let dispatcher = ActionDispatcher(ledger: ScenarioLedger(), currentAccountID: { "acct" })
    await dispatcher.register(
      FixtureTool(.webRead, required: [.init("url")]) { _ in
        [
          CapabilitySourceRow(
            title: "기사", body: String(repeating: "이 문서의 본문 문장이다. ", count: 20),
            identifier: "https://example.com/article")
        ]
      })
    await dispatcher.register(
      FixtureTool(.textSummarize, required: [.init("sourceText")]) { _ in
        [CapabilitySourceRow(title: "요약", body: "줄인 글이다.")]
      })
    var presented: ConversationTurnResult?
    let runtime = TurnRuntime(
      dispatcher: dispatcher,
      emit: { _ in },
      present: { presented = $0 },
      copy: .keysAsText,
      now: { ScenarioRunner.now },
      supervising: { _ in
        let decision: TurnDecision
        switch plan {
        case .readsPage:
          decision = TurnDecision(
            status: .working,
            plan: ActionPlan(
              steps: [
                PlannedStep(
                  capability: .webRead,
                  arguments: ["url": .text("https://example.com/article")])
              ], needs: nil))
        case .complete:
          decision = TurnDecision(status: .complete, plan: ActionPlan(steps: [], needs: nil))
        }
        return .decided(decision, ModelInvocationTrail(outcome: Self.receipt))
      },
      finalizing: { _, _ in
        FinalizationStep(
          answer: .written(headline: "정리했어요", points: [], relevant: [], backend: .privateCloud),
          trail: ModelInvocationTrail(outcome: Self.receipt))
      })
    await runtime.run(
      TurnContextSnapshot(
        requestID: UUID(), accountID: "acct", conversationID: "conv",
        input: input, recentMessages: [], submittedAt: ScenarioRunner.now,
        registeredCapabilities: [.webRead, .textSummarize]))
    let result = try XCTUnwrap(presented)
    return Run(
      steps: result.steps, interventionReason: result.telemetry.interventionReason)
  }

  private static let receipt = ModelInvocationReceipt(
    phase: .planning, purpose: AdmissionJob.conversationPlan.rawValue,
    requestedBackend: .privateCloud, resolvedBackend: .privateCloud,
    pccAttempted: true, pccCompleted: true, onDeviceAttempted: false,
    onDeviceCompleted: false, fallbackReason: nil, inputCharacters: 0,
    latencyMilliseconds: 0)
}
