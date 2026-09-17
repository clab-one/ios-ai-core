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
}
