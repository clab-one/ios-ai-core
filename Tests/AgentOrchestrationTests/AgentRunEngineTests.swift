import AgentKernel
import FoundationModels
import XCTest

@testable import AgentOrchestration

/// L0 — native session 실행기의 **경계**만 본다.
///
/// 실제 모델 왕복은 시뮬레이터에 모델이 없어 여기서 증명할 수 없다(그 층은 실기
/// `LiveNativeSessionTests`). 이 자리에서 지킬 것은 하나다: **모델을 쓸 수 없을 때
/// 조용히 다른 길로 가지 않는다.**
@available(iOS 26.0, *)
final class AgentRunEngineTests: XCTestCase {
  func testUnavailableModelFailsInsteadOfSilentlyFallingBack() async throws {
    let model = SystemLanguageModel.default
    guard case .unavailable = model.availability else {
      throw XCTSkip("이 기기에는 기기 모델이 있다 — 이 시험은 없는 판을 본다")
    }
    AgentHost.configure(AgentHostIdentity(bundleIdentifier: "dev.example.agenttests"))
    let journal = SpyEngineJournal()
    let engine = AgentRunEngine(
      dispatcher: ActionDispatcher(ledger: ScenarioLedger(), currentAccountID: { "acct" }),
      journal: journal, model: model)

    do {
      _ = try await engine.run(Self.context, instructions: "시험")
      XCTFail("모델이 없는데 실행이 성공했다")
    } catch let failure as AgentRunEngine.Failure {
      guard case .modelUnavailable = failure else {
        return XCTFail("다른 실패로 위장했다: \(failure)")
      }
    }
    // 실패한 run도 journal에 남는다 — 남지 않으면 재시작 뒤 그 차례는 없던 일이 된다.
    XCTAssertEqual(journal.runs.last?.status, .failed)
  }

  private static let context = TurnContextSnapshot(
    requestID: UUID(), accountID: "acct", conversationID: "conv",
    input: "다음 일정 알려줘", recentMessages: [], submittedAt: ScenarioRunner.now,
    registeredCapabilities: [.calendarSearch])
}

private final class SpyEngineJournal: AgentRunJournal, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var runs: [AgentRunRecord] = []

  func saveSession(_ record: AgentSessionRecord) throws {}
  func session(id sessionID: String) throws -> AgentSessionRecord? { nil }
  func saveRun(_ record: AgentRunRecord) throws {
    lock.lock()
    runs.append(record)
    lock.unlock()
  }
  func run(id runID: String) throws -> AgentRunRecord? { nil }
  func loadUnfinishedRuns(accountID: String, limit: Int) throws -> [AgentRunRecord] { [] }
  func appendTranscript(_ entry: AgentTranscriptEntry) throws {}
  func transcript(forRun runID: String) throws -> [AgentTranscriptEntry] { [] }
  func saveToolInvocation(_ record: ToolInvocationRecord) throws {}
  func toolInvocations(forRun runID: String) throws -> [ToolInvocationRecord] { [] }
  func forgetRun(runID: String) throws {}
}
