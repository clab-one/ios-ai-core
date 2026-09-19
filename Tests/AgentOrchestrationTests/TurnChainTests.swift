import AgentKernel
import XCTest

@testable import AgentOrchestration

/// **앱 없이 도는가.**
///
/// 여기서 증명하는 것은 모델의 품질이 아니라 **조립**이다:
///
/// 1. PCC가 한 번에 낸 순서대로 툴이 돌고, 앞 단계의 산출이 다음 단계의 인자가 된다
///    (`web.read → text.summarize → mail.send`).
/// 2. 값이 모자라면 **먼저 묻는다** — 계획 대신 질문이 나간다.
/// 3. 되돌릴 수 없는 실행 앞에서 멈추고, 승인 문이 **보낼 본문 그대로**를 담는다.
///
/// 시뮬레이터에는 PCC도 기기 모델도 없다. 그래서 계획·답·기기 모델의 자리에는
/// 대역을 세운다 — 그 셋이 프로토콜인 이유가 이것이다.
@available(iOS 26.0, *)
@MainActor
final class TurnChainTests: XCTestCase {
  private static let now = Date(timeIntervalSince1970: 1_789_610_400)
  private static let page = String(repeating: "이 페이지의 본문. ", count: 40)

  override func setUp() {
    super.setUp()
    AgentHost.configure(
      AgentHostIdentity(bundleIdentifier: "dev.example.agenttests"))
  }

  // MARK: 1) 순차 조립

  func testSummaryFlowsFromTheReadIntoTheMessageBody() async throws {
    let mail = RecordingMailTool()
    let dispatcher = await makeDispatcher(tools: [WebReadTool(page: Self.page), mail])
    let model = ScriptedOnDeviceModel(reply: "요약 세 줄.")
    await dispatcher.register(SummarizeTool(model: model))

    var approvals: [ActionApprovalRequest] = []
    let runtime = makeRuntime(
      dispatcher: dispatcher,
      plan: [
        PlannedStep(
          capability: .webRead, arguments: ["url": .text("https://example.com/a")]),
        PlannedStep(
          capability: .textSummarize, arguments: [:], unresolved: ["sourceText"]),
        PlannedStep(
          capability: .mailSend, arguments: ["to": .text("steve@example.com")],
          unresolved: ["body"]),
      ],
      onEvent: { envelope in
        if case .awaitingApproval(let approval) = envelope.event {
          approvals.append(approval)
        }
      })

    await runtime.run(context(input: "이 페이지 요약해서 steve@example.com에게 보내줘"))

    // 요약 툴이 읽은 본문을 받았다 — 원문은 PCC를 지나지 않았다.
    XCTAssertFalse(model.prompts.isEmpty, "요약 툴이 돌지 않았다")
    XCTAssertTrue(
      model.prompts.contains { $0.contains("이 페이지의 본문") },
      "앞 단계가 읽은 글이 요약 툴의 입력이 되지 않았다")

    // 전송은 승인 문에서 멈췄고, 그 문에 실린 본문이 **기기가 줄인 글**이다.
    // 조각 하나짜리 문서의 요약은 요점 줄로 서므로(헤드라인은 문서 제목이 된다)
    // 보는 것은 **원문이 아니라 요약이 흘렀는가**다.
    let approval = try XCTUnwrap(approvals.first, "되돌릴 수 없는 전송이 승인 없이 지나갔다")
    XCTAssertEqual(approval.request.capability, .mailSend)
    XCTAssertFalse(approval.preview.body.isEmpty, "본문이 비어 있다")
    XCTAssertFalse(
      approval.preview.body.contains("이 페이지의 본문"),
      "원문이 그대로 본문으로 흘렀다: \(approval.preview.body)")
    XCTAssertEqual(approval.preview.recipient, "steve@example.com")
    XCTAssertTrue(mail.sent.isEmpty, "승인 전에 전송이 일어났다")
  }

  /// **`compacting`은 짝이 있어야 한다.** 짝이 없으면 "줄이는 중" 표시를 걷어 낼
  /// 신호가 이벤트 스트림에 없다.
  func testCompactingIsFollowedByCompacted() async throws {
    let mail = RecordingMailTool()
    let dispatcher = await makeDispatcher(tools: [WebReadTool(page: Self.page), mail])
    let model = ScriptedOnDeviceModel(reply: "요약 세 줄.")
    await dispatcher.register(SummarizeTool(model: model))

    var events: [TurnEvent] = []
    let runtime = makeRuntime(
      dispatcher: dispatcher,
      plan: [
        PlannedStep(
          capability: .webRead, arguments: ["url": .text("https://example.com/a")]),
      ],
      onEvent: { events.append($0.event) })

    await runtime.run(context(input: "이 페이지 읽어줘"))

    let compactingIndex = events.firstIndex { if case .compacting = $0 { return true }; return false }
    let compactedIndex = events.firstIndex { if case .compacted = $0 { return true }; return false }
    let compacting = try XCTUnwrap(compactingIndex, "compacting이 나지 않았다: \(events)")
    let compacted = try XCTUnwrap(compactedIndex, "compacted가 나지 않았다: \(events)")
    XCTAssertLessThan(compacting, compacted, "compacted가 compacting보다 먼저거나 같은 자리에 섰다")
  }

  // MARK: 2) 먼저 묻기

  func testMissingRecipientAsksBeforeAnyToolRuns() async {
    let mail = RecordingMailTool()
    let dispatcher = await makeDispatcher(tools: [WebReadTool(page: Self.page), mail])

    var results: [ConversationTurnResult] = []
    let runtime = makeRuntime(
      dispatcher: dispatcher,
      // PCC가 값이 모자란다고 말했다: 단계 없이 `needs`만.
      decision: TurnDecision(status: .working, plan: ActionPlan(steps: [], needs: "to")),
      onResult: { results.append($0) })

    await runtime.run(context(input: "이 페이지 요약해서 메시지로 보내줘"))

    let last = results.last
    XCTAssertEqual(last?.phase, .awaitingUser, "모자란 값을 묻지 않고 차례를 닫았다")
    // **되물음의 문장은 모델이 쓴다**(`DynamicTurnProfile.asking`). 이 시험의 대역
    // 답 자리는 `"했어요"`를 돌려주므로 그 줄이 선다 — 문구 표의 열쇠는 모델을
    // 열지 못한 자리의 대역이고, 그 경로는 호스트 시험이 본다
    // (`AskedQuestionTurnTests`). 여기서 보는 것은 **묻고 멈췄는가**다.
    XCTAssertFalse(last?.headline.isEmpty ?? true, "되물음 줄이 비어 있다")
    XCTAssertTrue(mail.sent.isEmpty, "받는 사람을 모르는 채 전송을 시도했다")
  }

  // MARK: 3) 계획 한 번

  func testThePlanIsRequestedOnce() async {
    let dispatcher = await makeDispatcher(tools: [WebReadTool(page: Self.page)])
    var planCalls = 0
    let runtime = makeRuntime(
      dispatcher: dispatcher,
      plan: [
        PlannedStep(
          capability: .webRead, arguments: ["url": .text("https://example.com/a")])
      ],
      onPlan: { planCalls += 1 })

    await runtime.run(context(input: "이 페이지 읽어줘"))

    XCTAssertEqual(planCalls, 1, "실행 중에 PCC를 다시 불렀다")
  }


  // MARK: 1-b) 멈춤

  /// **사람이 멈추면 차례가 끝난다.**
  ///
  /// 실기 2026-09-18(iPhone 15 Pro): 화면의 중지를 누른 웹 검색 차례가 9.2초 뒤
  /// 답까지 썼다 — `cancelPending`이 승인 대기만 멈추고 도는 차례는 붙잡고
  /// 있지 않았다. 지금은 도는 일이 자기 task에 담겨 있고, 취소는 그 task를
  /// 취소한다.
  func testStopClosesARunningTurn() async throws {
    let gate = ToolGate()
    let dispatcher = await makeDispatcher(tools: [GatedTool(gate: gate)])
    var results: [ConversationTurnResult] = []
    var events: [TurnEvent] = []
    let runtime = makeRuntime(
      dispatcher: dispatcher,
      plan: [PlannedStep(capability: .webRead, arguments: ["url": .text("https://e.com/a")])],
      onEvent: { events.append($0.event) },
      onResult: { results.append($0) })

    let work = Task { await runtime.run(context(input: "천천히 읽어줘")) }
    await gate.entered()
    await runtime.cancelPending()
    await gate.open()
    await work.value

    XCTAssertEqual(results.last?.phase, .cancelled, "멈춘 차례가 닫히지 않았다")
    XCTAssertFalse(results.last?.isSynthesizedAnswer ?? true, "멈춘 차례가 답을 썼다")
    // 이벤트만 보는 화면도 **완료가 아니라 중단**을 알아야 한다.
    XCTAssertTrue(
      events.contains { if case .interrupted = $0 { return true }; return false },
      "이벤트 스트림에 .interrupted가 없다: \(events)")
    XCTAssertFalse(
      events.contains { if case .completed = $0 { return true }; return false },
      "중단된 차례가 이벤트 스트림엔 .completed로 보였다: \(events)")
  }
  // MARK: 조립

  private func context(input: String) -> TurnContextSnapshot {
    TurnContextSnapshot(
      requestID: UUID(), accountID: "acct", conversationID: "conv", input: input,
      recentMessages: [], submittedAt: Self.now,
      registeredCapabilities: [.webRead, .textSummarize, .mailSend])
  }

  private func makeDispatcher(tools: [any CapabilityHandler]) async -> ActionDispatcher {
    let dispatcher = ActionDispatcher(
      ledger: MemoryActionLedger(), currentAccountID: { "acct" })
    for tool in tools { await dispatcher.register(tool) }
    return dispatcher
  }

  private func makeRuntime(
    dispatcher: ActionDispatcher,
    plan: [PlannedStep] = [],
    decision: TurnDecision? = nil,
    onEvent: @escaping @MainActor (TurnEventEnvelope) -> Void = { _ in },
    onResult: @escaping @MainActor (ConversationTurnResult) -> Void = { _ in },
    onPlan: @escaping @MainActor () -> Void = {}
  ) -> TurnRuntime {
    let resolved = decision ?? TurnDecision(
      status: plan.isEmpty ? .complete : .working,
      plan: ActionPlan(steps: plan, needs: nil))
    return TurnRuntime(
      dispatcher: dispatcher,
      emit: onEvent,
      present: onResult,
      copy: .keysAsText,
      now: { Self.now },
      supervising: { _ in
        onPlan()
        return .decided(resolved, ModelInvocationTrail(outcome: Self.receipt))
      },
      finalizing: { _, _ in
        FinalizationStep(
          answer: .written(headline: "했어요", points: [], relevant: [], backend: .privateCloud),
          trail: ModelInvocationTrail(outcome: Self.receipt))
      })
  }

  private static let receipt = ModelInvocationReceipt(
    phase: .planning, purpose: AdmissionJob.conversationPlan.rawValue,
    requestedBackend: .privateCloud, resolvedBackend: .privateCloud,
    pccAttempted: true, pccCompleted: true, onDeviceAttempted: false,
    onDeviceCompleted: false, fallbackReason: nil, inputCharacters: 0,
    latencyMilliseconds: 0)
}

/// 시험이 여는 문. 툴이 이 문 앞에 서 있는 동안 차례는 **도는 중**이다.
private actor ToolGate {
  private var arrived: CheckedContinuation<Void, Never>?
  private var released: CheckedContinuation<Void, Never>?
  private var hasArrived = false
  private var isOpen = false

  /// 툴이 문 앞에 섰다.
  func arrive() {
    hasArrived = true
    arrived?.resume()
    arrived = nil
  }

  /// 툴이 문 앞에 서기를 기다린다.
  func entered() async {
    guard !hasArrived else { return }
    await withCheckedContinuation { arrived = $0 }
  }

  /// 문을 연다.
  func open() {
    isOpen = true
    released?.resume()
    released = nil
  }

  /// 툴이 문이 열리기를 기다린다.
  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { released = $0 }
  }
}

/// 문이 열릴 때까지 돌아오지 않는 읽기 툴.
private struct GatedTool: CapabilityHandler {
  let gate: ToolGate

  var capabilities: Set<CapabilityID> { [.webRead] }

  func perform(_ request: ActionRequest) async throws -> ActionReceipt {
    await gate.arrive()
    await gate.wait()
    return ActionReceipt(
      requestID: request.id, capability: .webRead, summary: "읽었어요",
      details: CapabilitySourceRow.detail([
        CapabilitySourceRow(
          title: "예시", subtitle: "e.com", body: "본문",
          identifier: request.arguments["url"]?.textValue ?? "")
      ]))
  }
}

// MARK: - 대역

/// 페이지 하나를 읽은 척한다. 본문을 줄에 담는 것이 요점이다 — 그 본문이 요약
/// 툴의 재료가 된다.
private struct WebReadTool: CapabilityHandler {
  let page: String

  var capabilities: Set<CapabilityID> { [.webRead] }

  func perform(_ request: ActionRequest) async throws -> ActionReceipt {
    ActionReceipt(
      requestID: request.id, capability: .webRead,
      summary: "읽었어요",
      details: CapabilitySourceRow.detail([
        CapabilitySourceRow(
          title: "예시 페이지", subtitle: "example.com", body: page,
          identifier: request.arguments["url"]?.textValue ?? "")
      ]),
      sources: [
        SourceReference(
          accountID: request.accountID, binding: .publicWeb, kind: .webPage,
          id: request.arguments["url"]?.textValue ?? "")
      ])
  }
}

/// 보낸 것을 적어 두는 전송 툴. **승인 없이 실행되면 그 사실이 보인다.**
private final class RecordingMailTool: CapabilityHandler, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [[String: ActionValue]] = []

  var sent: [[String: ActionValue]] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  var capabilities: Set<CapabilityID> { [.mailSend] }

  func perform(_ request: ActionRequest) async throws -> ActionReceipt {
    lock.lock()
    recorded.append(request.arguments)
    lock.unlock()
    return ActionReceipt(
      requestID: request.id, capability: .mailSend, externalID: "m-1",
      summary: "보냈어요")
  }
}

/// 기기 모델의 대역. 무엇을 받았는지 적어 둔다 — 원문이 요약 툴까지 왔는지가
/// 이 시험의 관찰 지점이다.
private final class ScriptedOnDeviceModel: OnDeviceTextModel, SummaryModel, @unchecked Sendable {
  private let reply: String
  private let lock = NSLock()
  private var received: [String] = []

  init(reply: String) { self.reply = reply }

  var prompts: [String] {
    lock.lock()
    defer { lock.unlock() }
    return received
  }

  var isAvailable: Bool { true }

  func respond(
    instructions: String, prompt: String, purpose: AdmissionJob, maximumTokens: Int
  ) async throws -> String {
    lock.lock()
    received.append(prompt)
    lock.unlock()
    return reply
  }

  func answer(
    schema: SummarySchema, instructions: String, prompt: String, maximumResponseTokens: Int
  ) async throws -> Data {
    lock.lock()
    received.append(prompt)
    lock.unlock()
    return ScriptedSummaryPayload.data(schema: schema, headline: reply)
  }
}

/// 메모리 원장. 원격 쓰기는 원장 없이는 실행되지 않으므로 시험에도 하나가 필요하다.
private final class MemoryActionLedger: ActionLedger, @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [String: ActionLedgerEntry] = [:]

  func replay(_ request: ActionRequest) throws -> ActionLedgerReplay? {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = entries[request.idempotencyKey] else { return nil }
    return entry.state == .completed ? .alreadyCompleted(entry) : .inFlight(entry)
  }

  func claim(_ request: ActionRequest, at date: Date) throws -> ActionLedgerClaim {
    lock.lock()
    defer { lock.unlock() }
    if let entry = entries[request.idempotencyKey] {
      switch entry.state {
      case .completed: return .alreadyCompleted(entry)
      case .pending: return .inFlight(entry)
      case .failed: break
      }
    }
    entries[request.idempotencyKey] = ActionLedgerEntry(
      idempotencyKey: request.idempotencyKey, accountID: request.accountID,
      capability: request.capability, state: .pending, createdAt: date)
    return .granted(idempotencyKey: request.idempotencyKey)
  }

  func settle(
    idempotencyKey: String, state: ActionLedgerEntry.State, externalID: String?,
    summary: String, at date: Date
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = entries[idempotencyKey] else { return }
    entries[idempotencyKey] = ActionLedgerEntry(
      idempotencyKey: idempotencyKey, accountID: entry.accountID,
      capability: entry.capability, state: state, externalID: externalID,
      summary: summary, createdAt: entry.createdAt, settledAt: date)
  }

  func entry(idempotencyKey: String) throws -> ActionLedgerEntry? {
    lock.lock()
    defer { lock.unlock() }
    return entries[idempotencyKey]
  }

  func forget(idempotencyKey: String) throws {
    lock.lock()
    entries[idempotencyKey] = nil
    lock.unlock()
  }

  func deleteAll(accountID: String) throws {
    lock.lock()
    entries = entries.filter { $0.value.accountID != accountID }
    lock.unlock()
  }
}
