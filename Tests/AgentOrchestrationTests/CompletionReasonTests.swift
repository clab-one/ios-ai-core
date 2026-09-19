import AgentKernel
import XCTest

@testable import AgentOrchestration

/// **L0: 왜 완료가 아닌지 말하는가.**
///
/// 실기 P01이 남긴 줄은 `phase=partial fallback=invariant:web.read`였다
/// (2026-09-17, iPad). 그 줄은 왜 부분으로 닫혔는지 말하지 않는다 — 런타임이 빠진
/// 읽기를 메운 **정상 경로의 표시**가 실패 사유의 칸을 차지했기 때문이다.
///
/// 그래서 세 칸으로 갈랐다: 보정(`interventionReason`)·완료를 깎은 사실
/// (`completionReason`)·모델 대역(`fallbackReason`). 이 층은 그 셋이 섞이지 않는지
/// 본다. 살아 있는 웹의 분산에 기대지 않고 **결정적으로** 만든다.
@available(iOS 26.0, *)
@MainActor
final class CompletionReasonTests: XCTestCase {

  /// 보정과 사유가 **같은 차례에 함께** 남는다. 한 칸이던 동안 뒤에 적은 쪽이 앞을
  /// 지웠고, 남은 것은 보정 표시였다.
  func testInterventionAndCompletionAreSeparateFields() async throws {
    let read = FixtureTool(
      .webRead, required: [.init("url")],
      coverage: { request in
        [
          CoverageRecord(
            binding: .publicWeb, capability: .webRead,
            queryFingerprint: ActionFingerprint.arguments(request.arguments),
            state: .partial, discoveredCount: 1, readCount: 1,
            paginationExhausted: true, truncated: true, reason: .truncation)
        ]
      }
    ) { _ in [CapabilitySourceRow(title: "PCC", body: "잘린 본문.")] }

    let run = await ScenarioRunner.run(
      GoldenScenario(
        name: "C01 truncated-read",
        input: "PCC 최신 소식 찾아서 알려줘",
        scope: [.webSearch, .webRead],
        // 계획에 읽기가 없다 — 런타임이 메운다(`dependency:web.read`).
        plan: [PlannedStep(capability: .webSearch, arguments: ["query": .text("PCC")])],
        tools: [
          WebSearchTool(
            broker: WebSearchBroker(engines: [
              StubSearchEngine(
                name: "stub",
                outcome: .success([
                  WebSearchResult(
                    title: "Private Cloud Compute", url: "https://example.com/pcc",
                    snippet: "검증 가능한 서버 추론")
                ]))
            ])),
          read,
        ],
        budget: ScenarioBudget(contextBaseline: 600, materials: 2, retrievedRows: 2)))

    let telemetry = try XCTUnwrap(run.result?.telemetry)
    XCTAssertEqual(run.executed, ["web.search", "web.read"], "빠진 읽기가 메워지지 않았다")
    XCTAssertEqual(
      telemetry.interventionReason, "dependency:web.read",
      "보정은 정상 경로이고 그 이름으로 남아야 한다")
    XCTAssertEqual(
      telemetry.completionReason, "coverage:web.read:truncation",
      "왜 온전하지 않은지 말하지 않았다")
    XCTAssertEqual(telemetry.fallbackReason, "", "모델은 대역으로 내려서지 않았다")
  }

  /// 읽기가 온전하면 **깎인 것이 없다.** 이 짝이 없으면 위 시험은 "항상 사유를
  /// 적는다"로도 통과한다.
  func testCompleteCoverageLeavesNoReason() async throws {
    let run = await ScenarioRunner.run(
      GoldenScenario(
        name: "C02 complete-read",
        input: "https://example.com/pcc 이 페이지 알려줘",
        scope: [.webRead],
        plan: [
          PlannedStep(
            capability: .webRead, arguments: ["url": .text("https://example.com/pcc")])
        ],
        tools: [
          FixtureTool(
            .webRead, required: [.init("url")],
            coverage: { request in
              [
                CoverageRecord(
                  binding: .publicWeb, capability: .webRead,
                  queryFingerprint: ActionFingerprint.arguments(request.arguments),
                  state: .complete, discoveredCount: 1, readCount: 1,
                  paginationExhausted: true)
              ]
            }
          ) { _ in [CapabilitySourceRow(title: "PCC", body: "온전한 본문.")] }
        ],
        budget: ScenarioBudget(contextBaseline: 600, materials: 1, retrievedRows: 1)))

    let telemetry = try XCTUnwrap(run.result?.telemetry)
    XCTAssertEqual(telemetry.completionReason, "", "깎인 것이 없는데 사유가 남았다")
    XCTAssertEqual(telemetry.interventionReason, "", "보정하지 않았는데 표시가 남았다")
  }

  /// 약속한 쓰기가 일어나지 않으면 **그 이름이 남는다.** 계획에 전송이 있는데
  /// 수령증이 없으면 그 차례는 완료가 아니다.
  func testUnkeptWriteNamesItself() async throws {
    let run = await ScenarioRunner.run(
      GoldenScenario(
        name: "C03 unkept-write",
        input: "지민에게 메일 보내줘",
        scope: [.mailSend],
        plan: [
          PlannedStep(
            capability: .mailSend,
            arguments: ["to": .text("jimin@example.com"), "body": .text("보낼 글")])
        ],
        // 손이 없다. 계획은 전송을 약속했고 수령증은 없다.
        tools: [],
        budget: ScenarioBudget(contextBaseline: 400, materials: 0, retrievedRows: 0)))

    let telemetry = try XCTUnwrap(run.result?.telemetry)
    XCTAssertTrue(
      telemetry.completionReason.contains("unkept:mail.send"),
      "약속한 전송이 빠진 사실이 남지 않았다: \(telemetry.completionReason)")
  }
  /// `docs/REMAINING_WORK.ko.md` P3 "도구 일부 실패 시 성공한 근거로 부분 답변".
  ///
  /// **한 읽기는 성공하고 한 읽기는 실패했다.** 성공한 근거는 버리지 않고 답의
  /// 재료로 쓰되, 실패한 범위는 완료로 위장하지 않는다 — 둘 다 성공한 척(완료)도,
  /// 성공한 것까지 버리는 것(완전 실패)도 틀린 답이다.
  func testPartialSuccessKeepsWorkingEvidenceAndNamesTheFailure() async throws {
    let ok = FixtureTool(.memoryRead, required: [.init("itemID")]) { _ in
      [CapabilitySourceRow(title: "회의록", body: "다음 회의는 목요일 오후 3시입니다.")]
    }
    let refused = FailingReadTool(refusing: "https://blocked.example.com")

    let run = await ScenarioRunner.run(
      GoldenScenario(
        name: "C04 partial-success",
        input: "저장된 회의록이랑 그 페이지 같이 확인해줘",
        scope: [.memoryRead, .webRead],
        plan: [
          PlannedStep(
            capability: .memoryRead, arguments: ["itemID": .text("doc-meeting-notes")]),
          PlannedStep(
            capability: .webRead,
            arguments: ["url": .text("https://blocked.example.com")]),
        ],
        tools: [ok, refused],
        budget: ScenarioBudget(contextBaseline: 500, materials: 1, retrievedRows: 1)))

    // 성공한 읽기는 실제로 실행됐다 — 실패한 형제 때문에 건너뛰지 않았다.
    XCTAssertEqual(run.executed.sorted(), ["memory.read", "web.read"])
    XCTAssertEqual(refused.attempted, ["https://blocked.example.com"])

    // 성공한 근거는 답의 재료로 실제로 실렸다 — 실패한 형제가 근거 전체를 비우지 않았다.
    XCTAssertTrue(
      run.finalizingContexts.contains { $0.contains("다음 회의는 목요일 오후 3시입니다") },
      "성공한 근거가 답 단계 문맥에 없다 — 실패한 도구가 성공한 근거까지 버렸다")

    // 실패는 완료로 위장되지 않는다.
    let telemetry = try XCTUnwrap(run.result?.telemetry)
    XCTAssertTrue(
      telemetry.completionReason.contains("web.read"),
      "실패한 읽기의 사유가 completionReason에 남지 않았다: \(telemetry.completionReason)")
    XCTAssertNotEqual(
      run.result?.phase, .completed,
      "도구 하나가 실패했는데 차례가 완전 완료로 닫혔다 — 실패를 감췄다")
  }

  /// `docs/REMAINING_WORK.ko.md` P3 "최종 모델 응답 실패 시 실제 receipt 보존".
  ///
  /// **도구는 성공했고 답 생성만 실패했다.** 이미 확정된 효과의 receipt가 그
  /// 실패 하나로 사라지면, 안전한 재시도(같은 도구를 다시 부르지 않는 재시도)를
  /// 세울 근거 자체가 없다 — 이 시험은 그 전제(receipt 보존)만 결정적으로 본다.
  ///
  /// **`.mailSend`를 쓰는 이유**: `ActionLedger`는 `capability.isRemoteWrite`
  /// (= `authority == .leavesTheDevice`)인 능력만 거친다(`ActionDispatcher.execute`
  /// 실제 구현 확인) — 기기를 떠나지 않는 `.remindersCreate` 같은 로컬 쓰기는
  /// 원장 자체를 지나지 않는다. 그래서 이 시험은 실제로 기기를 떠나는
  /// `.mailSend`로 확인한다.
  ///
  /// **범위를 좁힌 이유**: "생성만 재시도"는 `TurnRuntime`이 같은 `requestID`로
  /// 답 단계만 다시 여는 API를 요구하는데, 그런 API 자체가 아직 없다(선행 요구:
  /// 세션 실행과 영속 transcript 정본 구현). `ScenarioLedger`는 생산
  /// `SQLiteActionLedger`와 같이 `effectIdentity`(내용 기반, 차례 무관)를 열쇠로
  /// 쓰므로 — `idempotencyKey`(`"\(requestID)#\(identity)"`, 차례 범위)를 쓰면
  /// 리뷰 2026-09-18에서 지적한 대로 재시도 증명이 생산 원장과 어긋난다 — 이
  /// 시험이 증명하는 것은 재시도 API가 서기 **전에 이미 참이어야 하는 전제**,
  /// 즉 생성이 실패해도 원장의 receipt는 지워지지 않는다는 사실이 실제 생산
  /// 원장의 열쇠 계약으로도 성립한다는 것이다.
  func testFinalizingFailureDoesNotEraseTheCompletedToolReceipt() async throws {
    let send = FixtureTool(
      .mailSend, required: [.init("to"), .init("body")], optional: [.init("subject")]
    ) { _ in [] }
    let ledger = ScenarioLedger()

    let run = await ScenarioRunner.run(
      GoldenScenario(
        name: "C05 finalizing-failure-keeps-receipt",
        input: "지민에게 메일 보내줘",
        scope: [.mailSend],
        plan: [
          PlannedStep(
            capability: .mailSend,
            arguments: ["to": .text("jimin@example.com"), "body": .text("보낼 글")])
        ],
        tools: [send],
        budget: ScenarioBudget(contextBaseline: 300, materials: 0, retrievedRows: 0),
        expectedPhase: .partial),
      ledger: ledger,
      finalizingOverride: { _, _ in
        FinalizationStep(
          answer: .unavailable(reason: "생성 실패(시험)"),
          trail: ModelInvocationTrail(
            outcome: ModelInvocationReceipt(
              phase: .finalizing, purpose: AdmissionJob.conversationAnswer.rawValue,
              requestedBackend: .privateCloud, resolvedBackend: .privateCloud,
              pccAttempted: true, pccCompleted: false, onDeviceAttempted: false,
              onDeviceCompleted: false, fallbackReason: nil, inputCharacters: 0,
              latencyMilliseconds: 0)))
      })

    // 효과는 실제로 일어났다 — 답 생성 실패가 도구 실행을 막지 않았다.
    XCTAssertEqual(run.executed, ["mail.send"])
    // 도구는 끝났지만 답을 못 썼다 — 완료도 완전 실패도 아닌 partial이 맞다
    // (효과는 확정됐는데 그 효과를 사람에게 알릴 말이 없는 상태).
    XCTAssertEqual(
      run.result?.phase, .partial,
      "생성 실패인데 이미 확정된 효과가 있다 — completed도 failed도 이 상태를 정확히 말하지 않는다")

    // **핵심 단정.** 확정된 효과의 receipt는 원장에 그대로 남는다 — 답을
    // 못 쓴 것이 "메일을 안 보냈다"는 뜻이 되지 않는다.
    let request = try XCTUnwrap(send.requests.first, "메일 도구가 불리지 않았다")
    let entry = try ledger.entry(idempotencyKey: request.effectIdentity)
    XCTAssertEqual(
      entry?.state, .completed,
      "답 생성이 실패하자 이미 끝난 도구의 원장 항목까지 사라지거나 미완료로 남았다")
  }
}

/// 한 주소만 거절하는 읽기 손. 그 거절은 **바깥의 사정**이다(`web.read.rejected`).
/// `SearchCandidateTests.RefusingReadTool`과 같은 모양이지만 파일 경계를 넘는
/// private 참조를 만들지 않으려고 이 파일에 독립적으로 둔다.
private final class FailingReadTool: CapabilityHandler, @unchecked Sendable {
  private let refused: String
  private let lock = NSLock()
  private var received: [String] = []

  init(refusing url: String) {
    refused = url
  }

  var attempted: [String] {
    lock.lock()
    defer { lock.unlock() }
    return received
  }

  var capabilities: Set<CapabilityID> { [.webRead] }
  var contracts: [CapabilityContract] {
    [CapabilityContract(.webRead, required: [CapabilityContract.Argument("url")])]
  }

  func perform(_ request: ActionRequest) async throws -> ActionReceipt {
    let url = request.arguments["url"]?.textValue ?? ""
    lock.lock()
    received.append(url)
    lock.unlock()
    guard url != refused else { throw ActionError.failed(reason: "web.read.rejected") }
    return ActionReceipt(
      requestID: request.id, capability: .webRead, summary: "web.read.result",
      details: CapabilitySourceRow.detail([
        CapabilitySourceRow(title: "페이지", body: "공개된 본문입니다.", identifier: url)
      ]))
  }
}
