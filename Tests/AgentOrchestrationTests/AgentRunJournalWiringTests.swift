import AgentKernel
import XCTest

@testable import AgentOrchestration

/// journal이 실제 차례 경로에 붙고, 실패해도 차례를 죽이지 않는가.
@available(iOS 26.0, *)
@MainActor
final class AgentRunJournalWiringTests: XCTestCase {
  func testReadTurnRecordsRunInvocationAndArguments() async throws {
    let spy = SpyJournal()
    let result = await Self.runReadTurn(journal: spy)

    XCTAssertEqual(result?.phase, .completed)
    XCTAssertGreaterThanOrEqual(spy.runs.count, 2)
    XCTAssertEqual(spy.runs.first?.status, .running)
    XCTAssertTrue(spy.runs.last?.status.isTerminal == true)
    let invocation = try XCTUnwrap(spy.invocations.last)
    XCTAssertEqual(invocation.state, .completed)
    XCTAssertFalse(invocation.arguments.isEmpty, "정규화된 인자가 비었다")
  }

  func testTranscriptHasUserThenAssistantAndNoReasoning() async throws {
    let spy = SpyJournal()
    _ = await Self.runReadTurn(journal: spy)

    XCTAssertEqual(spy.entries.map(\.role).first, .user)
    XCTAssertTrue(spy.entries.contains(where: { $0.role == .assistant }))
    XCTAssertFalse(
      spy.entries.contains(where: { $0.role.rawValue == "reasoning" }),
      "hidden reasoning이 journal에 남았다")
    XCTAssertNil(AgentTranscriptEntry.Role(rawValue: "reasoning"))
  }

  func testThrowingJournalDoesNotKillTheTurn() async {
    let result = await Self.runReadTurn(journal: ThrowingJournal())
    XCTAssertEqual(result?.phase, .completed, "journal 실패가 차례를 죽였다")
  }

  private static func runReadTurn(journal: any AgentRunJournal) async -> ConversationTurnResult? {
    AgentHost.configure(AgentHostIdentity(bundleIdentifier: "dev.example.agenttests"))
    let dispatcher = ActionDispatcher(
      ledger: ScenarioLedger(), currentAccountID: { "acct" })
    await dispatcher.register(
      FixtureTool(.memorySearch, required: [.init("query")]) { _ in
        [CapabilitySourceRow(title: "여권", body: "만료는 2027년 3월이다.")]
      })
    var presented: ConversationTurnResult?
    let runtime = TurnRuntime(
      dispatcher: dispatcher,
      emit: { _ in },
      present: { presented = $0 },
      copy: .keysAsText,
      now: { ScenarioRunner.now },
      supervising: { request in
        .decided(
          TurnDecision(
            status: .working,
            plan: ActionPlan(
              steps: [
                PlannedStep(
                  capability: .memorySearch, arguments: ["query": .text("여권")])
              ], needs: nil)),
          ModelInvocationTrail(
            outcome: ModelInvocationReceipt(
              phase: .planning, purpose: AdmissionJob.conversationPlan.rawValue,
              requestedBackend: .privateCloud, resolvedBackend: .privateCloud,
              pccAttempted: true, pccCompleted: true, onDeviceAttempted: false,
              onDeviceCompleted: false, fallbackReason: nil, inputCharacters: 0,
              latencyMilliseconds: 0)))
      },
      finalizing: { _, _ in
        FinalizationStep(
          answer: .written(
            headline: "만료는 2027년 3월입니다.", points: [], relevant: [],
            backend: .privateCloud),
          trail: ModelInvocationTrail(
            outcome: ModelInvocationReceipt(
              phase: .finalizing, purpose: AdmissionJob.conversationPlan.rawValue,
              requestedBackend: .privateCloud, resolvedBackend: .privateCloud,
              pccAttempted: true, pccCompleted: true, onDeviceAttempted: false,
              onDeviceCompleted: false, fallbackReason: nil, inputCharacters: 0,
              latencyMilliseconds: 0)))
      },
      journal: journal)
    await runtime.run(
      TurnContextSnapshot(
        requestID: UUID(), accountID: "acct", conversationID: "conv",
        input: "여권 만료 알려줘", recentMessages: [], submittedAt: ScenarioRunner.now,
        registeredCapabilities: [.memorySearch]))
    return presented
  }
}

private enum JournalTestError: Error { case boom }

private struct ThrowingJournal: AgentRunJournal {
  func saveSession(_ record: AgentSessionRecord) throws { throw JournalTestError.boom }
  func session(id sessionID: String) throws -> AgentSessionRecord? { throw JournalTestError.boom }
  func saveRun(_ record: AgentRunRecord) throws { throw JournalTestError.boom }
  func run(id runID: String) throws -> AgentRunRecord? { throw JournalTestError.boom }
  func loadUnfinishedRuns(accountID: String, limit: Int) throws -> [AgentRunRecord] {
    throw JournalTestError.boom
  }
  func appendTranscript(_ entry: AgentTranscriptEntry) throws { throw JournalTestError.boom }
  func transcript(forRun runID: String) throws -> [AgentTranscriptEntry] {
    throw JournalTestError.boom
  }
  func saveToolInvocation(_ record: ToolInvocationRecord) throws { throw JournalTestError.boom }
  func toolInvocations(forRun runID: String) throws -> [ToolInvocationRecord] {
    throw JournalTestError.boom
  }
  func forgetRun(runID: String) throws { throw JournalTestError.boom }
}

private final class SpyJournal: AgentRunJournal, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var runs: [AgentRunRecord] = []
  private(set) var entries: [AgentTranscriptEntry] = []
  private(set) var invocations: [ToolInvocationRecord] = []

  func saveSession(_ record: AgentSessionRecord) throws {}
  func session(id sessionID: String) throws -> AgentSessionRecord? { nil }
  func saveRun(_ record: AgentRunRecord) throws {
    lock.lock()
    defer { lock.unlock() }
    runs.append(record)
  }
  func run(id runID: String) throws -> AgentRunRecord? { nil }
  func loadUnfinishedRuns(accountID: String, limit: Int) throws -> [AgentRunRecord] { [] }
  func appendTranscript(_ entry: AgentTranscriptEntry) throws {
    lock.lock()
    defer { lock.unlock() }
    entries.append(entry)
  }
  func transcript(forRun runID: String) throws -> [AgentTranscriptEntry] { [] }
  func saveToolInvocation(_ record: ToolInvocationRecord) throws {
    lock.lock()
    defer { lock.unlock() }
    invocations.append(record)
  }
  func toolInvocations(forRun runID: String) throws -> [ToolInvocationRecord] { [] }
  func forgetRun(runID: String) throws {}
}
