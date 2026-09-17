import AgentKernel
import XCTest

@testable import AgentOrchestration

/// **PCC로 무엇이 나가는가.**
///
/// 이 저장소의 정체는 "기기에서 줄이고, 결정에 필요한 최소 정보만 보낸다"이고,
/// 그 문장은 지금까지 주석과 상수로만 있었다 — 어떤 시험도 문맥의 크기나 내용을
/// 읽지 않았다. 상한이 강제되지 않으면 구획이 하나 늘 때마다 조용히 구멍이 난다.
///
/// 그래서 여기서 증명하는 것은 세 가지다:
///
/// 1. 답을 쓰는 단계의 문맥에는 **식별자가 하나도 없다** — 근거의 id도, 고정점도.
/// 2. 고정점은 **자리 이름만** 나간다. 값(계정·workspace·revision)은 기기에 남는다.
/// 3. 긴 지시는 **자르지 않고 거절한다.** 그리고 그 차례는 PCC를 부른 적이 없다.
@available(iOS 26.0, *)
@MainActor
final class PCCContextBoundaryTests: XCTestCase {
  private static let now = Date(timeIntervalSince1970: 1_789_610_400)
  private static let calendar: Calendar = {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .gmt
    return value
  }()

  private let compiler = ConversationContextCompiler()

  // **문맥에 서면 안 되는 값들.** 전부 배선이다 — 사용자가 읽을 사실이 아니다.
  private static let secretMessageID = "secret-message-id-18ca9f"
  private static let secretPrincipal = "secret-principal-roy@example.com"
  private static let secretWorkspace = "secret-workspace-T01"
  private static let secretRevision = "secret-revision-4471"
  private static let secretThread = "secret-thread-99dd"

  // MARK: 1) 답 단계에는 식별자가 없다

  func testFinalizingContextCarriesNoIdentifierAndNoAnchors() throws {
    let context = try compiler.compile(
      profile: .finalizing(target: .privateCloud),
      userMessage: "그 메일 뭐라고 왔어?",
      evidence: [Self.mailEvidence],
      anchoredSlots: ResolvableArgument.allCases,
      completed: "mail.read=ok",
      now: Self.now,
      calendar: Self.calendar)

    XCTAssertTrue(context.carriesEvidence, "근거가 실리지 않으면 이 시험이 아무것도 보지 않는다")
    XCTAssertTrue(context.prompt.contains("답장 일정은 목요일입니다."), "근거의 사실이 빠졌다")
    XCTAssertFalse(
      context.prompt.contains("<<<anchors>>>"),
      "도구가 닫힌 단계에 고정점이 섰다 — 다음 단계가 없는데 배선을 넘겼다")
    for secret in Self.secrets {
      XCTAssertFalse(context.prompt.contains(secret), "답 단계 문맥에 \(secret)이 실렸다")
    }
  }

  // MARK: 2) 고정점은 자리 이름만

  func testPlanningContextCarriesAnchorSlotNamesWithoutValues() throws {
    let context = try compiler.compile(
      profile: .supervising(
        phase: .reviewing, target: .privateCloud, scope: Self.scope, iteration: 1),
      userMessage: "그 메일에 답장해줘",
      evidence: [Self.mailEvidence],
      anchoredSlots: [.messageID, .threadID, .to],
      now: Self.now,
      calendar: Self.calendar)

    XCTAssertTrue(context.prompt.contains("<<<anchors>>>"), "계획 단계가 채울 자리를 알지 못한다")
    for slot in ["messageID", "threadID", "to"] {
      XCTAssertTrue(context.prompt.contains(slot), "\(slot) 자리가 문맥에 없다")
    }

    // **다음 단계의 인자는 계획 단계에만 실린다.** 이 비대칭이 설계다.
    XCTAssertTrue(
      context.prompt.contains(Self.secretMessageID), "계획 단계가 다음 단계의 인자를 잃었다")

    // 그러나 바인딩은 어느 단계에도 실리지 않는다 — 모델이 그 값으로 할 일이 없다.
    for secret in [Self.secretPrincipal, Self.secretWorkspace, Self.secretRevision,
      Self.secretThread]
    {
      XCTAssertFalse(context.prompt.contains(secret), "계획 단계 문맥에 \(secret)이 실렸다")
    }
  }

  // MARK: 3) 긴 지시는 자르지 않고 거절한다

  func testOversizedRequestThrowsInsteadOfTruncating() {
    let limit = PCCContextBudget.standard.requestCharacters
    for count in [limit + 1, 100_000] {
      let request = String(repeating: "가", count: count)
      XCTAssertThrowsError(
        try compiler.compile(
          profile: .finalizing(target: .privateCloud),
          userMessage: request, now: Self.now, calendar: Self.calendar),
        "\(count)자 지시가 문맥으로 조립됐다"
      ) { error in
        XCTAssertEqual(
          (error as? ContextCompilationError)?.reason,
          ContextCompilationError.requestTooLargeReason)
      }
    }
  }

  func testRequestAtTheLimitStillCompiles() throws {
    let limit = PCCContextBudget.standard.requestCharacters
    let context = try compiler.compile(
      profile: .finalizing(target: .privateCloud),
      userMessage: String(repeating: "가", count: limit),
      now: Self.now, calendar: Self.calendar)
    XCTAssertTrue(context.prompt.contains("<<<request>>>"))
  }

  /// **PCC 문이 열리지 않았다**가 진짜 판정 기준이다. 문맥 크기 검사만으로는
  /// 상위 경로가 그 문맥 없이 모델을 부르는 길이 남는다.
  func testOversizedInputNeverInvokesSupervisorOrFinalizer() async {
    let calls = ModelCallCounter()
    var presented: ConversationTurnResult?
    let runtime = await makeRuntime(calls: calls) { presented = $0 }

    let paste = String(repeating: "가", count: PCCContextBudget.standard.requestCharacters)
    await runtime.run(Self.snapshot(input: paste + "\n이 내용을 수정하지 말고 김철수에게 보내줘"))

    XCTAssertEqual(calls.supervising, 0, "예산을 넘긴 지시로 계획을 물었다")
    XCTAssertEqual(calls.finalizing, 0, "예산을 넘긴 지시로 답을 물었다")
    XCTAssertEqual(presented?.phase, .failed)
    // 문맥 초과는 **모델 대역이 아니다.** 부른 적이 없으므로 대역도 없다 —
    // 그 사실은 완료를 깎은 사유에 남는다(`completionReason`).
    XCTAssertEqual(
      presented?.telemetry.completionReason, ContextCompilationError.requestTooLargeReason)
    XCTAssertEqual(presented?.telemetry.fallbackReason, "", "부르지 않은 호출의 대역 사유가 있다")
    XCTAssertEqual(presented?.telemetry.pccCalls, 0)
  }

  /// 상한 안의 지시는 **반드시 통과한다.** 이 짝이 없으면 "전부 거절"도 위 시험을
  /// 지난다.
  func testRequestWithinTheLimitOpensThePCCDoor() async {
    let calls = ModelCallCounter()
    let runtime = await makeRuntime(calls: calls) { _ in }

    await runtime.run(Self.snapshot(input: "어제 받은 메일 찾아줘"))

    XCTAssertEqual(calls.supervising, 1, "정상 길이의 지시가 계획까지 가지 못했다")
  }

  // MARK: 4) 조립 결과는 언제나 예산 안

  func testNoCompiledContextExceedsTheBudget() throws {
    let budget = PCCContextBudget.standard
    let profiles: [DynamicTurnProfile] = [
      .supervising(phase: .planning, target: .privateCloud, scope: Self.scope, iteration: 0),
      .supervising(phase: .reviewing, target: .privateCloud, scope: Self.scope, iteration: 1),
      .finalizing(target: .privateCloud),
      .conversing(target: .privateCloud),
    ]
    let requests = [0, budget.requestCharacters - 1, budget.requestCharacters]

    for profile in profiles {
      for length in requests {
        for evidence in [[], Self.flood(evidence: 1_000)] {
          for recent in [[], Self.flood(messages: 1_000)] {
            let context = try compiler.compile(
              profile: profile,
              userMessage: String(repeating: "가", count: length),
              recentTurns: recent,
              evidence: evidence,
              coverage: Self.flood(coverage: 200),
              anchoredSlots: ResolvableArgument.allCases,
              completed: Self.flood(completed: 400),
              now: Self.now,
              calendar: Self.calendar)
            XCTAssertLessThanOrEqual(
              context.estimatedCharacters, budget.totalCharacters,
              """
              \(profile.phase.rawValue) 문맥이 예산을 넘었다 \
              (request=\(length) evidence=\(evidence.count) recent=\(recent.count))
              """)
          }
        }
      }
    }
  }

  /// 끝난 일 구획은 상한 안으로 줄지만 **방금 일어난 실패는 남는다.** 보낸 메일이
  /// 실패한 사실이 잘려 나가면 답이 그 사실을 말할 수 없다(§2.6·§10.1).
  func testCompletedDigestKeepsTheNewestLines() throws {
    let digest =
      (1...400).map { "memory.save=ok\($0)" }.joined(separator: "\n")
      + "\nmail.send=notAuthorized:mail"
    let context = try compiler.compile(
      profile: .supervising(
        phase: .reviewing, target: .privateCloud, scope: Self.scope, iteration: 1),
      userMessage: "보냈어?",
      completed: digest,
      now: Self.now,
      calendar: Self.calendar)

    XCTAssertTrue(
      context.prompt.contains("mail.send=notAuthorized:mail"), "가장 최근의 실패가 잘렸다")
    XCTAssertFalse(context.prompt.contains("memory.save=ok1\n"), "오래된 줄이 남았다")
  }

  // MARK: 5) 수령증의 딸린 값도 식별자를 흘리지 않는다

  /// `Evidence.sourceID`를 막은 것으로는 이 길이 닫히지 않는다. 수령증의
  /// `details`가 사실 줄로 옮겨지면 같은 값이 답의 문맥에 그대로 선다.
  func testActionEvidenceDropsExecutionHandles() throws {
    let cases: [(CapabilityID, String, String)] = [
      // 계약이 등록되지 않은 능력 — **모르는 열쇠는 막는다.**
      (.memorySave, "itemID", "기록했어요"),
      // 계약이 선언한 인자이지만 다음 단계의 손잡이다(`isOpaqueHandle`).
      (.mailRead, "messageID", "mail.read.result"),
    ]

    for (capability, key, summary) in cases {
      let secret = "secret-handle-52C3E0B2-\(key)"
      let evidence = EvidenceCompiler.action(
        ActionReceipt(
          requestID: UUID(), capability: capability, externalID: secret,
          summary: summary, details: [key: .text(secret)]))
      let context = try compiler.compile(
        profile: .finalizing(target: .privateCloud),
        userMessage: "기억해뒀어?",
        evidence: [evidence],
        now: Self.now, calendar: Self.calendar)

      XCTAssertTrue(context.prompt.contains(summary), "\(capability)의 관찰된 결과가 사라졌다")
      XCTAssertFalse(context.prompt.contains(secret), "\(capability)의 \(key) 값이 실렸다")
      XCTAssertFalse(context.prompt.contains(key), "\(capability)의 \(key) 자리 이름이 실렸다")
    }
  }

  /// 짝이 되는 시험. 이것이 없으면 "딸린 값을 전부 버린다"도 위 시험을 지나고,
  /// 그러면 답이 **한 일의 값**을 말할 수 없다(§43).
  func testActionEvidenceKeepsContractDeclaredFacts() throws {
    let evidence = EvidenceCompiler.action(
      ActionReceipt(
        requestID: UUID(), capability: .mailSend, externalID: Self.secretMessageID,
        summary: "mail.send.done",
        details: [
          "to": .text("chulsoo@example.com"), "subject": .text("목요일 회의"),
          // 어댑터가 지어낸 자리는 계약에 없다.
          "cursor": .text("secret-cursor-991"),
        ]))
    let context = try compiler.compile(
      profile: .finalizing(target: .privateCloud),
      userMessage: "보냈어?",
      evidence: [evidence],
      now: Self.now, calendar: Self.calendar)

    XCTAssertTrue(context.prompt.contains("chulsoo@example.com"), "누구에게 보냈는지가 사라졌다")
    XCTAssertTrue(context.prompt.contains("목요일 회의"), "무엇을 보냈는지가 사라졌다")
    XCTAssertFalse(context.prompt.contains("secret-cursor-991"), "계약 밖의 자리가 실렸다")
    XCTAssertFalse(context.prompt.contains(Self.secretMessageID), "보낸 메일의 id가 실렸다")
  }

  // MARK: 범위가 곧 비용이다

  /// **차례마다 능력을 전부 보여 주지 않는다.**
  ///
  /// 쓰지 않을 툴의 이름과 설명이 매 계획 호출에 실린다. 그 비용은 기능 시험에
  /// 잡히지 않는다 — 스물여덟 개를 보여 줘도 계획은 맞게 나오고, 값만 커진다.
  func testNarrowScopeCostsLessThanEverything() throws {
    func planningContext(_ registered: [CapabilityID]) throws -> String {
      try compiler.compile(
        profile: .supervising(
          phase: .planning, target: .privateCloud,
          scope: CapabilityScope.compile(registered: Set(registered)), iteration: 0),
        userMessage: "애플 PCC 최신 변경사항 알려줘",
        now: Self.now, calendar: Self.calendar
      ).prompt
    }

    let narrow = try planningContext([.webSearch, .webRead, .textSummarize])
    let everything = try planningContext(GoldenScenario.known)
    print("📐 scope: narrow=\(narrow.count) everything=\(everything.count)")

    XCTAssertLessThan(
      narrow.count, everything.count, "범위를 좁혀도 계획 문맥이 줄지 않는다")
    // 좁힌 범위의 문맥에는 **범위 밖 이름이 없다.**
    for capability in [CapabilityID.mailSend, .chatSend, .calendarCreate] {
      XCTAssertFalse(
        narrow.contains(capability.rawValue),
        "범위 밖 능력이 계획 문맥에 섰다 — \(capability.rawValue)")
    }
  }

  // MARK: 조립

  private static let secrets = [
    secretMessageID, secretPrincipal, secretWorkspace, secretRevision, secretThread,
  ]

  private static let scope = CapabilityScope.compile(
    registered: [.mailSearch, .mailRead, .mailSend, .peopleResolve, .memorySearch])

  /// 메일 한 통의 근거. **바인딩까지 붙여 둔다** — 그 값이 프롬프트로 새는지가
  /// 이 시험의 관찰 지점이다.
  private static var mailEvidence: Evidence {
    var evidence = Evidence(
      source: .mail,
      sourceID: secretMessageID,
      title: "목요일 회의 일정",
      facts: ["답장 일정은 목요일입니다."],
      timestamp: "2026-09-15 09:12")
    evidence.sourceReference = SourceReference(
      accountID: "acct",
      binding: .connector(
        ConnectorBindingID(
          provider: .google, principalID: secretPrincipal, workspaceID: secretWorkspace)),
      kind: .mailMessage,
      id: secretMessageID,
      containerID: secretThread,
      revision: secretRevision)
    return evidence
  }

  private static func flood(evidence count: Int) -> [Evidence] {
    (0..<count).map { index in
      Evidence(
        source: .chat,
        sourceID: "id-\(index)-\(String(repeating: "x", count: 400))",
        title: String(repeating: "제", count: 800),
        facts: (0..<8).map { _ in String(repeating: "사", count: 900) },
        summary: String(repeating: "요", count: 900),
        timestamp: String(repeating: "시", count: 200))
    }
  }

  private static func flood(messages count: Int) -> [ConversationMessage] {
    (0..<count).map { index in
      ConversationMessage(
        accountID: "acct", conversationID: "conv", sequence: index,
        requestID: "req-\(index)",
        role: index.isMultiple(of: 2) ? .user : .assistant,
        text: String(repeating: "말", count: 5_000))
    }
  }

  private static func flood(coverage count: Int) -> [CoverageRecord] {
    (0..<count).map { index in
      CoverageRecord(
        binding: .accountLocal(accountID: "acct", domain: "memory"),
        capability: .memorySearch,
        queryFingerprint: "fp-\(index)",
        state: .partial,
        discoveredCount: 999, readCount: 1,
        paginationExhausted: false, truncated: true, reason: .pagination)
    }
  }

  private static func flood(completed count: Int) -> String {
    (0..<count).map { "memory.search=ok-\($0)" }.joined(separator: "\n")
  }

  private static func snapshot(input: String) -> TurnContextSnapshot {
    TurnContextSnapshot(
      requestID: UUID(), accountID: "acct", conversationID: "conv", input: input,
      recentMessages: [], submittedAt: now,
      registeredCapabilities: [.mailSearch, .mailRead])
  }

  private func makeRuntime(
    calls: ModelCallCounter,
    present: @escaping @MainActor (ConversationTurnResult) -> Void
  ) async -> TurnRuntime {
    let dispatcher = ActionDispatcher(
      ledger: NoopActionLedger(), currentAccountID: { "acct" })
    return TurnRuntime(
      dispatcher: dispatcher,
      emit: { _ in },
      present: present,
      supervising: { _ in
        calls.supervising += 1
        return .decided(
          TurnDecision(status: .complete, plan: ActionPlan(steps: [], needs: nil)),
          ModelInvocationTrail(outcome: Self.receipt))
      },
      finalizing: { _, _ in
        calls.finalizing += 1
        return FinalizationStep(
          answer: .written(
            headline: "했어요", points: [], relevant: [], backend: .privateCloud),
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

// MARK: - 대역

/// PCC 자리를 몇 번 열었는가. **횟수가 판정**이므로 값을 따로 든다.
@MainActor
private final class ModelCallCounter {
  var supervising = 0
  var finalizing = 0
}

/// 원장 없이는 디스패처를 세울 수 없다. 이 시험은 실행까지 가지 않으므로 빈 값이다.
private struct NoopActionLedger: ActionLedger {
  func replay(_ request: ActionRequest) throws -> ActionLedgerReplay? { nil }
  func claim(_ request: ActionRequest, at date: Date) throws -> ActionLedgerClaim {
    .granted(idempotencyKey: request.idempotencyKey)
  }
  func settle(
    idempotencyKey: String, state: ActionLedgerEntry.State, externalID: String?,
    summary: String, at date: Date
  ) throws {}
  func entry(idempotencyKey: String) throws -> ActionLedgerEntry? { nil }
  func deleteAll(accountID: String) throws {}
}
