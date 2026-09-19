import AgentKernel
import Foundation
import XCTest

@testable import AgentOrchestration

/// These tests exercise the real coordinator, validator, dispatcher and compiler.
/// The PCC closures and device tools are fakes; no live model quota is consumed.
@available(iOS 26.0, *)
@MainActor
final class MoriConversationRuntimeTests: XCTestCase {
  private final class Observation {
    var results: [ConversationTurnResult] = []
    var contexts: [CompiledConversationContext] = []
    var approval: ActionApprovalRequest?
    var supervisorCalls = 0
    var finalizerCalls = 0
    var snapshots: [TurnResponseSnapshot] = []
    var events: [TurnEvent] = []
  }

  private nonisolated static let account = "conversation-patch-tests"
  private nonisolated static let conversation = "primary"

  func testConversationOnlyHostUsesOnePCCSeatAndNoTools() async throws {
    let box = Observation()
    let dispatcher = ActionDispatcher(currentAccountID: { Self.account })
    let runtime = runtime(box, dispatcher: dispatcher, output: reply("무슨 일이 있었어요?"))
    await runtime.run(snapshot("오늘 좀 피곤하네", capabilities: []))
    let result = try terminal(box)
    XCTAssertEqual(result.phase, .completed)
    XCTAssertEqual(result.headline, "무슨 일이 있었어요?")
    XCTAssertEqual(result.telemetry.pccCalls, 1) // Fake seat accounting, not a live PCC call.
    XCTAssertEqual(box.supervisorCalls, 1)
    XCTAssertEqual(box.finalizerCalls, 0)
    XCTAssertTrue(result.steps.isEmpty)
  }

  func testRegisteredToolsDoNotForceConversationIntoAnAction() async throws {
    let box = Observation()
    let tool = CountingTool(.calendarCreate)
    let dispatcher = ActionDispatcher(currentAccountID: { Self.account })
    await dispatcher.register(tool)
    let runtime = runtime(box, dispatcher: dispatcher, output: reply("잠깐 쉬면서 정리해봐요."))
    await runtime.run(snapshot("오늘 피곤하네", capabilities: [.calendarCreate]))
    let calls = await tool.calls
    XCTAssertEqual(calls, 0)
    XCTAssertNil(box.approval)
    XCTAssertEqual(try terminal(box).phase, .completed)
    XCTAssertEqual(box.finalizerCalls, 0)
  }

  func testClarificationReusesTheFirstPCCSentence() async throws {
    let box = Observation()
    let dispatcher = ActionDispatcher(currentAccountID: { Self.account })
    let runtime = runtime(box, dispatcher: dispatcher, output: GeneratedTurnDecision(
      status: "clarify", steps: [], needs: "start", response: "몇 시로 옮길까요?"))
    await runtime.run(snapshot("그 회의 시간 바꿔줘", capabilities: []))
    let result = try terminal(box)
    XCTAssertEqual(result.phase, .awaitingUser)
    XCTAssertEqual(result.headline, "몇 시로 옮길까요?")
    XCTAssertEqual(box.supervisorCalls, 1)
    XCTAssertEqual(box.finalizerCalls, 0)
  }

  /// 모델이 대화 문장과 단계를 함께 냈다. **그 문장은 답이 되지 않는다.**
  /// 등록되지 않은 능력은 걸러지고, 답은 기존 근거 경로가 쓴다.
  func testRawMixedReplyAndToolOutputNeverSurfacesTheProse() async throws {
    let box = Observation()
    let tool = CountingTool(.calendarCreate)
    let dispatcher = ActionDispatcher(currentAccountID: { Self.account })
    await dispatcher.register(tool)
    let mixed = GeneratedTurnDecision(status: "reply", steps: [GeneratedActionStep(
      capability: "not.registered", text: "bad", target: "", when: "", subject: "")],
      needs: "", response: "처리했어요")
    let runtime = runtime(box, dispatcher: dispatcher, output: mixed)
    await runtime.run(snapshot("설명만 해줘", capabilities: [.calendarCreate]))
    let calls = await tool.calls
    XCTAssertEqual(calls, 0)
    XCTAssertNil(box.approval)
    let result = try terminal(box)
    XCTAssertNotEqual(result.headline, "처리했어요", "실행 없이 모델의 완료 문장이 답으로 섰다")
    XCTAssertTrue(result.steps.isEmpty)
    XCTAssertTrue(result.receipts.isEmpty)
  }

  func testOversizedUserInputInvokesNeitherModelSeat() async throws {
    let box = Observation()
    let dispatcher = ActionDispatcher(currentAccountID: { Self.account })
    let runtime = runtime(box, dispatcher: dispatcher, output: reply("unused"))
    await runtime.run(snapshot(
      String(repeating: "가", count: PCCContextBudget.standard.requestCharacters + 1), capabilities: []))
    XCTAssertEqual(try terminal(box).phase, .failed)
    XCTAssertEqual(box.supervisorCalls, 0)
    XCTAssertEqual(box.finalizerCalls, 0)
  }

  /// **종료 이벤트는 실제 결과와 같은 말을 해야 한다.** 예전엔 `finish()`가
  /// phase와 무관하게 `.completed`를 냈다 — 이벤트 스트림만 보는 화면은 실패한
  /// 차례도 "완료"로 읽었다(코드 리뷰 2026-09-18 P2).
  func testOversizedUserInputEmitsFailedEventNotCompleted() async throws {
    let box = Observation()
    let dispatcher = ActionDispatcher(currentAccountID: { Self.account })
    let runtime = runtime(box, dispatcher: dispatcher, output: reply("unused"))
    await runtime.run(snapshot(
      String(repeating: "가", count: PCCContextBudget.standard.requestCharacters + 1), capabilities: []))
    XCTAssertEqual(try terminal(box).phase, .failed)
    XCTAssertTrue(
      box.events.contains { if case .failed = $0 { return true }; return false },
      "이벤트 스트림에 .failed가 없다: \(box.events)")
    XCTAssertFalse(
      box.events.contains { if case .completed = $0 { return true }; return false },
      "실패한 차례가 이벤트 스트림엔 .completed로 보였다: \(box.events)")
  }

  func testUserReportedContextSurvivesBeyondTheOld200CharacterCut() async throws {
    let box = Observation()
    let dispatcher = ActionDispatcher(currentAccountID: { Self.account })
    let runtime = runtime(box, dispatcher: dispatcher, output: reply("보내지 않을게요."))
    let text = String(repeating: "배경 설명 ", count: 50) + "절대로 보내지 마"
    await runtime.run(snapshot("아까 말한 것 기억해?", capabilities: [], recent: [
      message("old", account: Self.account, conversation: Self.conversation, text: text)
    ]))
    XCTAssertTrue(try XCTUnwrap(box.contexts.first).prompt.contains("절대로 보내지 마"))
    XCTAssertEqual(box.finalizerCalls, 0)
  }

  func testForeignAccountAndConversationHistoryNeverReachTheModel() async throws {
    let box = Observation()
    let dispatcher = ActionDispatcher(currentAccountID: { Self.account })
    let runtime = runtime(box, dispatcher: dispatcher, output: reply("안녕하세요."))
    await runtime.run(snapshot("안녕", capabilities: [], recent: [
      message("a", account: "other", conversation: Self.conversation, text: "FOREIGN_ACCOUNT"),
      message("b", account: Self.account, conversation: "other", text: "FOREIGN_CONVERSATION"),
      message("c", account: Self.account, conversation: Self.conversation, text: "LOCAL_CONTEXT")
    ]))
    let prompt = try XCTUnwrap(box.contexts.first).prompt
    XCTAssertFalse(prompt.contains("FOREIGN_ACCOUNT"))
    XCTAssertFalse(prompt.contains("FOREIGN_CONVERSATION"))
    XCTAssertTrue(prompt.contains("LOCAL_CONTEXT"))
  }

  func testWriteStillWaitsForApprovalAndResumesTheSameTurn() async throws {
    let box = Observation()
    let tool = CountingTool(.calendarCreate)
    let dispatcher = ActionDispatcher(currentAccountID: { Self.account })
    await dispatcher.register(tool)
    let output = GeneratedTurnDecision(status: "continue", steps: [GeneratedActionStep(
      capability: "calendar.create", text: "회의", target: "",
      when: "2026-09-19T15:00:00+09:00", subject: "")], needs: "")
    let runtime = runtime(box, dispatcher: dispatcher, output: output)
    let context = snapshot("내일 3시에 회의 만들어줘", capabilities: [.calendarCreate])
    await runtime.run(context)
    let before = await tool.calls
    XCTAssertEqual(before, 0)
    let approval = try XCTUnwrap(box.approval)
    XCTAssertEqual(approval.request.turnID, context.requestID)
    let outcome = await dispatcher.approve(approval.id)
    await runtime.resume(approval, outcome: outcome)
    let after = await tool.calls
    XCTAssertEqual(after, 1)
    XCTAssertEqual(box.supervisorCalls, 1)
    XCTAssertEqual(box.finalizerCalls, 1)
    XCTAssertEqual(try terminal(box).requestID, context.requestID)
  }

  /// 실기 2026-09-18(iPhone 15 Pro, 실제 PCC): 같은 입력 8회 중 1회가
  /// `status=complete` + 1 step에 `"…기억할게요."` 문장을 함께 냈다. 그 모양을
  /// 실패로 닫는 동안 저장은 돌지 않았고 화면에는 `"하지 못했어요"`가 섰다.
  /// **문장은 버리고 단계는 기존 승인 경로로 실행한다.**
  func testPlanCarryingProseExecutesWithoutSurfacingTheProse() async throws {
    let box = Observation()
    let tool = CountingTool(.calendarCreate)
    let dispatcher = ActionDispatcher(currentAccountID: { Self.account })
    await dispatcher.register(tool)
    let prose = "일정을 만들어 둘게요."
    let output = GeneratedTurnDecision(status: "complete", steps: [GeneratedActionStep(
      capability: "calendar.create", text: "회의", target: "",
      when: "2026-09-19T15:00:00+09:00", subject: "")], needs: "", response: prose)
    let runtime = runtime(box, dispatcher: dispatcher, output: output)
    await runtime.run(snapshot("내일 3시에 회의 만들어줘", capabilities: [.calendarCreate]))
    let approval = try XCTUnwrap(box.approval, "쓰기가 승인 앞에서 멈추지 않았다")
    let outcome = await dispatcher.approve(approval.id)
    await runtime.resume(approval, outcome: outcome)
    let calls = await tool.calls
    XCTAssertEqual(calls, 1, "모델이 문장을 덧붙인 탓에 계획이 실행되지 않았다")
    let result = try terminal(box)
    XCTAssertEqual(result.phase, .completed)
    XCTAssertNotEqual(result.headline, prose, "실행 결과가 아니라 모델의 예고 문장이 답으로 섰다")
    XCTAssertTrue(result.receipts.contains { $0.capability == .calendarCreate })
  }

  func testPCCUnavailableDoesNotStartALocalSummaryFallback() async throws {
    let box = Observation()
    let local = CountingTool(.textSummarize)
    let dispatcher = ActionDispatcher(currentAccountID: { Self.account })
    await dispatcher.register(local)
    let runtime = runtime(box, dispatcher: dispatcher, output: reply("unused"), failure: "pcc.unsupported")
    await runtime.run(snapshot("안녕", capabilities: [.textSummarize]))
    let calls = await local.calls
    XCTAssertEqual(calls, 0)
    XCTAssertEqual(box.finalizerCalls, 0)
    XCTAssertEqual(try terminal(box).phase, .failed)
  }

  func testSafetyRefusalKeepsReadReceiptWithoutAnotherGeneration() async throws {
    let box = Observation()
    let local = CountingTool(.textSummarize)
    let dispatcher = ActionDispatcher(currentAccountID: { Self.account })
    await dispatcher.register(MemoryTool(index: FixtureMemory()))
    await dispatcher.register(local)
    let runtime = runtime(box, dispatcher: dispatcher, output: reply("unused"), failure: "guardrail")
    await runtime.run(snapshot("이 문서 설명해줘", capabilities: [.memoryRead, .textSummarize]),
                      attachedItemIDs: ["fixture-document"])
    let result = try terminal(box)
    let calls = await local.calls
    XCTAssertEqual(calls, 0)
    XCTAssertEqual(box.finalizerCalls, 0)
    XCTAssertTrue(result.receipts.contains { $0.capability == .memoryRead })
    XCTAssertFalse(result.steps.contains { $0.capability == .textSummarize })
    XCTAssertEqual(result.telemetry.fallbackReason, "guardrail")
  }

  func testCumulativeSnapshotsCarryTurnAndAccountScope() async throws {
    let box = Observation()
    let dispatcher = ActionDispatcher(currentAccountID: { Self.account })
    let runtime = runtime(box, dispatcher: dispatcher, output: reply("안녕하세요."), stream: true)
    let context = snapshot("안녕", capabilities: [])
    await runtime.run(context)
    XCTAssertEqual(box.snapshots.map(\.text), ["안", "안녕하세요."])
    XCTAssertTrue(box.snapshots.allSatisfy {
      $0.requestID == context.requestID && $0.accountID == Self.account
        && $0.conversationID == Self.conversation
    })
    XCTAssertEqual(box.snapshots.map(\.sequence), [1, 2])
    XCTAssertEqual(try terminal(box).headline, "안녕하세요.")
  }

  func testNewInstructionsAndBoundedHistoryStayWithinBudget() throws {
    let voice = "In Korean use 해요체. Match the user's requested depth."
    let profiles: [DynamicTurnProfile] = [
      .supervising(phase: .planning, target: .privateCloud, scope: .empty),
      .supervising(phase: .reviewing, target: .privateCloud, scope: .empty),
      .conversing(target: .privateCloud), .finalizing(target: .privateCloud)
    ]
    for profile in profiles {
      let compiled = try ConversationContextCompiler().compile(
        profile: profile, userMessage: "앞 내용을 설명해줘",
        recentTurns: [message("a", account: Self.account, conversation: Self.conversation,
                             text: String(repeating: "상황 ", count: 200))],
        voice: voice, calendar: .current)
      XCTAssertLessThanOrEqual(compiled.instructions.count, PCCContextBudget.standard.instructionCharacters)
      XCTAssertLessThanOrEqual(compiled.estimatedCharacters, PCCContextBudget.standard.totalCharacters)
    }
  }

  private func runtime(
    _ box: Observation, dispatcher: ActionDispatcher, output: GeneratedTurnDecision,
    failure: String? = nil, stream: Bool = false
  ) -> TurnRuntime {
    TurnRuntime(
      dispatcher: dispatcher,
      emit: { envelope in
        box.events.append(envelope.event)
        if case .awaitingApproval(let approval) = envelope.event { box.approval = approval }
      },
      present: { box.results.append($0) },
      supervising: { request in
        box.supervisorCalls += 1
        box.contexts.append(request.context)
        if let failure {
          return .failed(disposition: .surfaceFailure, reason: failure,
                         ModelInvocationTrail(outcome: Self.receipt(request.profile.phase, succeeded: false)))
        }
        if stream {
          await ModelResponseStream.publish("안")
          await ModelResponseStream.publish(output.response)
        }
        return .decided(ActionPlanValidator.validate(
          output, allowed: request.context.capabilities, conversationID: request.conversationID,
          accountID: request.accountID, calendar: request.context.calendar),
          ModelInvocationTrail(outcome: Self.receipt(request.profile.phase)))
      },
      finalizing: { context, profile in
        box.finalizerCalls += 1
        box.contexts.append(context)
        return FinalizationStep(
          answer: .written(headline: "확인한 결과예요.", points: [], relevant: [1], backend: .privateCloud),
          trail: ModelInvocationTrail(outcome: Self.receipt(profile.phase)))
      },
      responseStreamingEnabled: { stream },
      onResponseSnapshot: { box.snapshots.append($0) },
      isAccountCurrent: { $0.accountID == Self.account && $0.accountEpoch == AssistantAccountEpoch.current })
  }

  private func reply(_ text: String) -> GeneratedTurnDecision {
    GeneratedTurnDecision(status: "reply", steps: [], needs: "", response: text)
  }

  private func snapshot(
    _ input: String, capabilities: Set<CapabilityID>, recent: [ConversationMessage] = []
  ) -> TurnContextSnapshot {
    TurnContextSnapshot(requestID: UUID(), accountID: Self.account, conversationID: Self.conversation,
                        input: input, recentMessages: recent, registeredCapabilities: capabilities)
  }

  private func message(_ request: String, account: String, conversation: String, text: String) -> ConversationMessage {
    ConversationMessage(id: "message-\(request)", accountID: account, conversationID: conversation,
                        sequence: 1, requestID: request, role: .user, text: text)
  }

  private func terminal(_ box: Observation) throws -> ConversationTurnResult {
    try XCTUnwrap(box.results.last { $0.phase != .working })
  }

  private static func receipt(_ phase: TurnPhase, succeeded: Bool = true) -> ModelInvocationReceipt {
    ModelInvocationReceipt(
      phase: phase, purpose: "test-double", requestedBackend: .privateCloud,
      resolvedBackend: .privateCloud, pccAttempted: true, pccCompleted: succeeded,
      onDeviceAttempted: false, onDeviceCompleted: false, fallbackReason: nil,
      inputCharacters: 10, latencyMilliseconds: 1)
  }
}

private actor CountingTool: CapabilityHandler {
  private(set) var calls = 0
  private nonisolated let capability: CapabilityID
  init(_ capability: CapabilityID) { self.capability = capability }
  nonisolated var capabilities: Set<CapabilityID> { [capability] }
  nonisolated var contracts: [CapabilityContract] {
    if capability == .calendarCreate {
      return [CapabilityContract(capability, required: [.init("title"), .init("start", .timestamp)])]
    }
    return [CapabilityContract(capability, required: [.init("sourceText")])]
  }
  func perform(_ request: ActionRequest) async throws -> ActionReceipt {
    calls += 1
    return ActionReceipt(requestID: request.id, capability: request.capability,
                         externalID: "fixture-result", summary: "일정을 만들었어요")
  }
}

private struct FixtureMemory: SemanticMemoryIndex {
  func search(_ query: String, accountID: String, limit: Int, cursor: String?) async throws
    -> [MemoryHit]
  { [] }
  func read(id: String, accountID: String) async throws -> MemoryDocument? {
    MemoryDocument(id: id, title: "안내문", body: "모임은 내일 오후 세 시입니다.")
  }
  func save(text: String, title: String?, accountID: String, conversationID: String?)
    async throws -> String
  { "fixture-document" }
}
