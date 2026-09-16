import AgentKernel
import XCTest

@testable import AgentOrchestration

/// 한 시나리오가 **지켜야 하는 값들**.
///
/// 기능이 성공했는데 문맥이 두 배가 된 커밋은 회귀다. 그 회귀는 눈에 보이지
/// 않는다 — `@Guide` 한 줄, 스키마 문구 하나로 늘어나고 아무 시험도 깨지지 않는다.
/// 그래서 예산을 **시험 결과가 아니라 시험 조건으로** 든다.
struct ScenarioBudget {
  /// 물리 PCC 호출 수. 정상 차례의 기준은 둘이다 — 계획 하나, 답 하나.
  var pccCalls = 2
  /// 감독자에게 물은 횟수. 정상 차례에서 이 값이 1을 넘으면 기능 문제가 아니라
  /// 계획 스키마나 resolver가 잘못된 신호를 준 것이다.
  var supervisorIterations = 1
  /// 지금 측정된 **가장 큰 한 번의 문맥** 글자 수. 회귀의 기준선이다.
  ///
  /// 절대 상한이 아니라 기준선이다: 10% 넘으면 경고, 20% 넘으면 실패. 절대값만
  /// 두면 여유 안에서 조용히 자라고, 여유가 끝나는 날 한꺼번에 깨진다.
  var contextBaseline: Int
  /// PCC가 보는 근거 조각 수.
  var materials: Int
  /// 근거로 옮기기 전에 회수한 줄 수. 검색 다섯 줄을 읽으면 다섯이다.
  var retrievedRows: Int
  /// 기기 모델을 부른 횟수의 상한. 압축은 싸지만 무료는 아니다.
  var localExtractions = 8
  /// 실측 토큰 상한. **잰 차례에만** 본다(L2·L3) — L0에서는 재는 모델이 없고,
  /// 그 자리에 글자 수 환산을 넣으면 시험이 없는 값을 지키게 된다.
  var inputTokens: Int?

  static let warningRatio = 1.10
  static let failureRatio = 1.20
}

/// golden 시나리오 하나.
///
/// **능력을 전부 등록하지 않는다.** 시나리오가 요구하는 것만 모델 범위에 넣는다 —
/// 스키마 자체가 문맥을 먹고, 쓰지 않을 툴 열 개의 설명이 매 호출마다 실린다.
/// 이 원칙은 시험만의 것이 아니다: 제품에서도 차례마다 범위를 좁히는 쪽이 맞다.
struct GoldenScenario {
  let name: String
  let input: String
  /// 이 차례에 모델이 보는 능력 **전부**.
  let scope: [CapabilityID]
  /// 감독자 대역이 돌려줄 계획. L0에서는 이 값이 PCC의 자리를 대신한다.
  let plan: [PlannedStep]
  let tools: [any CapabilityHandler]
  let budget: ScenarioBudget
  /// 문맥에 있으면 **실패**인 글자들. 원문 표식·불투명 식별자·공급자 스니펫.
  var forbidden: [String] = []

  /// 코어가 이름을 가진 능력 전부. 범위 밖 능력이 문맥에 새는지 보는 데 쓴다.
  ///
  /// 코어에 `all` 목록이 없어 시험이 든다 — 그 목록을 제품 코드에 만들면 시험만
  /// 쓰는 값이 제품에 남는다.
  static let known: [CapabilityID] = [
    .memorySearch, .memorySave, .memoryRead,
    .contentIngest, .contentRead, .contentSummarize, .textSummarize,
    .recordingStart, .recordingStop, .recordingRead,
    .artifactFind, .artifactRead, .sharePublish, .shareRevoke,
    .calendarSearch, .calendarCreate, .calendarUpdate, .calendarDelete,
    .remindersSearch, .remindersCreate, .remindersUpdate, .remindersComplete,
    .remindersDelete,
    .peopleResolve, .contactsRead, .contactsCreate, .contactsUpdate,
    .mailSearch, .mailRead, .mailSend, .mailReply,
    .chatSearch, .chatRead, .chatSend, .chatReply,
    .webSearch, .webFetch, .webRead,
  ]

  var offScope: [CapabilityID] {
    Self.known.filter { !scope.contains($0) }
  }
}

/// 시나리오 한 번의 관찰. **PCC에 가기 직전의 문맥**이 여기 남는다.
@MainActor
struct ScenarioRun {
  let scenario: GoldenScenario
  var planningContexts: [String] = []
  var finalizingContexts: [String] = []
  var approvals: [ActionApprovalRequest] = []
  /// 계획·답 자리가 **대역인가.** L0에서는 참이다.
  ///
  /// 이 구분을 로그에 적는 이유: `pcc=2`를 본 사람은 이 층이 PCC를 두 번 부른다고
  /// 읽는다. L0의 그 값은 **자리가 두 번 열렸다**는 뜻이고 호출 비용은 0이다.
  var bandedSeats = true
  var result: ConversationTurnResult?

  var telemetry: TurnTelemetry { result?.telemetry ?? TurnTelemetry() }
  var contexts: [String] { planningContexts + finalizingContexts }
  var largestContext: Int { contexts.map(\.count).max() ?? 0 }

  /// 모든 golden이 함께 지키는 것. 시나리오별 단정은 여기에 더해서 쓴다.
  func assertBounds(file: StaticString = #filePath, line: UInt = #line) throws {
    let budget = scenario.budget
    let result = try XCTUnwrap(result, "\(scenario.name): 차례가 결과를 내지 않았다", file: file, line: line)

    // 매 실행에 한 줄. **예산은 보이지 않으면 지켜지지 않는다** — 통과한 시나리오의
    // 비용도 보여야 기준선을 언제 다시 잴지 알 수 있다.
    print(
      """
      📐 \(scenario.name): context=\(largestContext)(기준선 \(budget.contextBaseline)) \
      \(bandedSeats ? "seats(대역)" : "pcc")=\(telemetry.pccCalls) \
      iterations=\(telemetry.supervisorIterations) \
      materials=\(telemetry.materialCount) rows=\(telemetry.retrievedRows) \
      local=\(telemetry.localExtractions)
      """)

    XCTAssertEqual(
      result.phase, .completed, "\(scenario.name): 차례가 닫히지 않았다", file: file, line: line)
    XCTAssertLessThanOrEqual(
      telemetry.pccCalls, budget.pccCalls,
      "\(scenario.name): PCC 호출이 예산을 넘었다", file: file, line: line)
    XCTAssertLessThanOrEqual(
      telemetry.supervisorIterations, budget.supervisorIterations,
      "\(scenario.name): 재계획이 일어났다 — 계획 스키마나 resolver를 본다",
      file: file, line: line)
    XCTAssertLessThanOrEqual(
      telemetry.materialCount, budget.materials,
      "\(scenario.name): 근거 조각이 예산을 넘었다", file: file, line: line)
    XCTAssertLessThanOrEqual(
      telemetry.retrievedRows, budget.retrievedRows,
      "\(scenario.name): 회수한 줄이 예산을 넘었다", file: file, line: line)
    XCTAssertLessThanOrEqual(
      telemetry.localExtractions, budget.localExtractions,
      "\(scenario.name): 기기 모델 호출이 예산을 넘었다", file: file, line: line)

    // **문맥은 예산 안에서만 자란다.**
    let failure = Int(Double(budget.contextBaseline) * ScenarioBudget.failureRatio)
    let warning = Int(Double(budget.contextBaseline) * ScenarioBudget.warningRatio)
    XCTAssertLessThanOrEqual(
      largestContext, failure,
      """
      \(scenario.name): 문맥이 기준선의 20%를 넘겼다 \
      (\(largestContext) > \(failure), 기준선 \(budget.contextBaseline))
      """, file: file, line: line)
    if largestContext > warning {
      print(
        """
        ⚠️ CONTEXT-DRIFT \(scenario.name): \(largestContext)자 \
        (기준선 \(budget.contextBaseline), 경고선 \(warning))
        """)
    }

    // **실측 토큰은 잰 차례에만 본다.** 재지 못한 값은 nil이고, nil은 0이 아니다.
    if let limit = budget.inputTokens, let measured = telemetry.maximumInputTokens {
      XCTAssertLessThanOrEqual(
        measured, limit, "\(scenario.name): 한 호출의 입력 토큰이 예산을 넘었다",
        file: file, line: line)
    }

    for marker in scenario.forbidden {
      for context in contexts {
        XCTAssertFalse(
          context.contains(marker),
          "\(scenario.name): 원문/식별자가 PCC 문맥에 실렸다 — \(marker)",
          file: file, line: line)
      }
    }

    // **범위 밖 능력은 이름조차 실리지 않는다.** 쓰지 않을 툴의 스키마가 매 호출
    // 문맥을 먹는 것이 이 검사가 막는 일이다.
    for capability in scenario.offScope {
      for context in contexts {
        XCTAssertFalse(
          context.contains(capability.rawValue),
          "\(scenario.name): 범위 밖 능력이 문맥에 섰다 — \(capability.rawValue)",
          file: file, line: line)
      }
    }
  }

  /// 실행된 단계의 순서. 계획한 대로 돌았는가를 본다.
  var executed: [String] {
    (result?.steps ?? []).filter { !$0.pending }.map(\.capability.rawValue)
  }
}

/// 시나리오를 **실제 런타임으로** 돌린다.
///
/// 대역은 셋뿐이다: 계획(감독자), 답(최종), 그리고 툴. 그 사이의 resolver·계약·
/// 근거 압축·문맥 조립은 전부 제품 코드다 — 대역을 더 세우면 시험이 시험을 검증한다.
@MainActor
enum ScenarioRunner {
  static let now = Date(timeIntervalSince1970: 1_789_610_400)

  static func run(_ scenario: GoldenScenario) async -> ScenarioRun {
    AgentHost.configure(AgentHostIdentity(bundleIdentifier: "dev.example.agenttests"))

    let dispatcher = ActionDispatcher(
      ledger: ScenarioLedger(), currentAccountID: { "acct" })
    for tool in scenario.tools { await dispatcher.register(tool) }

    let box = RunBox(scenario: scenario)
    let runtime = TurnRuntime(
      dispatcher: dispatcher,
      emit: { envelope in
        if case .awaitingApproval(let approval) = envelope.event {
          box.run.approvals.append(approval)
        }
      },
      present: { result in box.run.result = result },
      copy: .keysAsText,
      now: { now },
      supervising: { request in
        box.run.planningContexts.append(request.context.prompt)
        return .decided(
          TurnDecision(
            status: scenario.plan.isEmpty ? .complete : .working,
            plan: ActionPlan(steps: scenario.plan, needs: nil)),
          ModelInvocationTrail(outcome: Self.receipt(.planning)))
      },
      finalizing: { context, _ in
        box.run.finalizingContexts.append(context.prompt)
        return FinalizationStep(
          answer: .written(
            headline: "답", points: [], relevant: [], backend: .privateCloud),
          trail: ModelInvocationTrail(outcome: Self.receipt(.finalizing)))
      })

    await runtime.run(
      TurnContextSnapshot(
        requestID: UUID(), accountID: "acct", conversationID: "conv",
        input: scenario.input, recentMessages: [], submittedAt: now,
        registeredCapabilities: Set(scenario.scope)))
    return box.run
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

/// 검색 한 번의 대역. **결과도 실패도 미리 적어 둔다** — 없는 것과 막힌 것을
/// 가르는 경로가 여기서 갈린다.
struct StubSearchEngine: WebSearchEngine {
  let name: String
  let outcome: Result<[WebSearchResult], any Error>

  func search(
    query: String, limit: Int, window: WebSearchWindow?
  ) async throws -> [WebSearchResult] {
    try outcome.get()
  }
}

/// 관찰을 모으는 상자. 대역들이 같은 값을 채우므로 참조 타입이 필요하다.
@MainActor
private final class RunBox {
  var run: ScenarioRun

  init(scenario: GoldenScenario) {
    run = ScenarioRun(scenario: scenario)
  }
}

// MARK: - 대역

/// 시나리오가 미리 적어 둔 결과를 돌려주는 손.
///
/// **무엇을 받았는지 적어 둔다.** 앞 단계의 산출이 다음 단계의 인자가 되는지는
/// 이 기록으로만 볼 수 있다(`requests`).
final class FixtureTool: CapabilityHandler, @unchecked Sendable {
  let capabilities: Set<CapabilityID>
  let contracts: [CapabilityContract]
  private let lock = NSLock()
  private let answer: @Sendable (ActionRequest) -> [CapabilitySourceRow]
  private var received: [ActionRequest] = []

  /// 계약을 **값의 종류까지** 든다. 종류를 적지 않으면 정규화가 `.timestamp`를
  /// `malformed`로 거절하고, 시나리오는 툴이 아니라 계약에서 멈춘다.
  init(
    _ capability: CapabilityID,
    required: [CapabilityContract.Argument] = [],
    optional: [CapabilityContract.Argument] = [],
    rows: @escaping @Sendable (ActionRequest) -> [CapabilitySourceRow]
  ) {
    capabilities = [capability]
    contracts = [
      CapabilityContract(capability, required: required, optional: optional)
    ]
    answer = rows
  }

  var requests: [ActionRequest] {
    lock.lock()
    defer { lock.unlock() }
    return received
  }

  func perform(_ request: ActionRequest) async throws -> ActionReceipt {
    lock.lock()
    received.append(request)
    lock.unlock()
    let rows = answer(request)
    return ActionReceipt(
      requestID: request.id, capability: request.capability,
      summary: "\(request.capability.rawValue).result",
      details: rows.isEmpty ? [:] : CapabilitySourceRow.detail(rows))
  }
}

/// 원장. 원격 쓰기는 원장 없이 실행되지 않으므로 시험에도 하나가 필요하다.
final class ScenarioLedger: ActionLedger, @unchecked Sendable {
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

/// 기기 모델의 대역. 받은 원문을 적어 둔다 — 원문이 여기까지 왔는지가 관찰 지점이다.
final class ScenarioOnDeviceModel: OnDeviceTextModel, @unchecked Sendable {
  private let lock = NSLock()
  private let reply: String
  private var seen: [String] = []

  init(reply: String) {
    self.reply = reply
  }

  var received: [String] {
    lock.lock()
    defer { lock.unlock() }
    return seen
  }

  var isAvailable: Bool { true }

  func respond(
    instructions: String, prompt: String, purpose: AdmissionJob, maximumTokens: Int
  ) async throws -> String {
    lock.lock()
    seen.append(prompt)
    lock.unlock()
    return reply
  }
}
