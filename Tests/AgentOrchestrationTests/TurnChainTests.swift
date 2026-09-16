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
    XCTAssertEqual(model.prompts.count, 1, "요약 툴이 한 번 돌아야 한다")
    XCTAssertTrue(
      model.prompts.first?.contains("이 페이지의 본문") == true,
      "앞 단계가 읽은 글이 요약 툴의 입력이 되지 않았다")

    // 전송은 승인 문에서 멈췄고, 그 문에 실린 본문이 **요약**이다.
    let approval = try XCTUnwrap(approvals.first, "되돌릴 수 없는 전송이 승인 없이 지나갔다")
    XCTAssertEqual(approval.request.capability, .mailSend)
    XCTAssertEqual(
      approval.preview.body, "요약 세 줄.",
      "요약이 메시지 본문으로 흐르지 않았다")
    XCTAssertEqual(approval.preview.recipient, "steve@example.com")
    XCTAssertTrue(mail.sent.isEmpty, "승인 전에 전송이 일어났다")
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
    XCTAssertEqual(
      last?.headline, TurnCopy.Key.needs["to"],
      "무엇이 필요한지 말하지 않았다")
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
        return .decided(resolved, Self.receipt)
      },
      finalizing: { _, _ in
        FinalizationStep(
          answer: .written(headline: "했어요", points: [], relevant: [], backend: .privateCloud),
          receipt: Self.receipt)
      })
  }

  private static let receipt = ModelInvocationReceipt(
    phase: .planning, purpose: AdmissionJob.conversationPlan.rawValue,
    requestedBackend: .privateCloud, resolvedBackend: .privateCloud,
    pccAttempted: true, pccCompleted: true, onDeviceAttempted: false,
    onDeviceCompleted: false, fallbackReason: nil, inputCharacters: 0,
    latencyMilliseconds: 0)
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
private final class ScriptedOnDeviceModel: OnDeviceTextModel, @unchecked Sendable {
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

  func deleteAll(accountID: String) throws {
    lock.lock()
    entries = entries.filter { $0.value.accountID != accountID }
    lock.unlock()
  }
}
