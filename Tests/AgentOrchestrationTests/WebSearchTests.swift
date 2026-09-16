import AgentKernel
import XCTest

@testable import AgentOrchestration

/// **검색 결과는 기기에서 좁혀진다.**
///
/// 여기서 증명하는 것은 검색 품질이 아니라 **경계**다:
///
/// 1. 결과 페이지에서 뽑는 것은 제목·주소·스니펫뿐이다(광고와 공급자 리다이렉트는
///    결과가 아니다).
/// 2. 그 줄의 `identifier`가 다음 단계의 인자다 — 이 자리가 비면 검색은 성공하고
///    읽기는 되물음으로 끝난다.
/// 3. 차례 전체를 돌려도 **SERP HTML도 페이지 전문도 PCC 문맥에 서지 않는다.**
///
/// 픽스처는 실측에서 온다(2026-09-17, `html.duckduckgo.com`·`lite.duckduckgo.com`).
/// 네트워크를 타지 않는 이유는 시험이 결정론이어야 하기 때문이다 — 살아 있는 SERP는
/// 하루 만에 다른 글자를 돌려준다.
@available(iOS 26.0, *)
@MainActor
final class WebSearchTests: XCTestCase {
  private static let now = Date(timeIntervalSince1970: 1_789_610_400)

  // MARK: 1) 결과 페이지에서 뽑는 것

  func testHTMLLayoutYieldsTitleURLAndSnippet() async throws {
    let engine = DuckDuckGoHTMLSearch(transport: Self.transport(Self.htmlFixture))
    let results = try await engine.search(query: "Apple Private Cloud Compute", limit: 5)

    XCTAssertEqual(results.count, 2, "광고를 결과로 셌거나 리다이렉트를 버렸다")
    XCTAssertEqual(results[0].url, "https://security.apple.com/blog/private-cloud-compute/")
    XCTAssertEqual(
      results[0].title, "Private Cloud Compute: A new frontier for AI privacy in the cloud")
    XCTAssertEqual(
      results[0].snippet,
      "Secure and private AI processing in the cloud poses a formidable new challenge.",
      "강조 태그가 남았거나 공백이 접히지 않았다")

    // 공급자 리다이렉트(`/l/?uddg=`)는 **벗긴다.** 그 주소를 그대로 읽으면 다음
    // 단계가 검색 엔진의 중계 페이지를 읽는다.
    XCTAssertEqual(results[1].url, "https://developer.apple.com/private-cloud-compute/")
    XCTAssertEqual(results[1].snippet, "Access Apple's server-side foundation models.")
  }

  /// 광고 줄의 스니펫이 **앞 결과에 붙지 않는다.** 붙으면 사용자가 보는 한 줄이
  /// 광고 문구가 된다.
  func testSponsoredRowsAreNotResults() async throws {
    let engine = DuckDuckGoHTMLSearch(transport: Self.transport(Self.htmlFixture))
    let results = try await engine.search(query: "pcc", limit: 5)

    for result in results {
      XCTAssertFalse(result.url.contains("duckduckgo.com"), "공급자 자기 주소가 결과로 섰다")
      XCTAssertFalse(result.snippet.contains("Buy now"), "광고 문구가 결과 줄에 붙었다")
      XCTAssertFalse(result.title.contains("Sponsored"), "광고 제목이 결과로 섰다")
    }
  }

  /// 가벼운 레이아웃은 마크업이 다르다 — 단일 인용부호 class와 `<td>` 스니펫.
  func testLiteLayoutParsesDifferentMarkup() async throws {
    let engine = DuckDuckGoLiteSearch(transport: Self.transport(Self.liteFixture))
    let results = try await engine.search(query: "pcc", limit: 5)

    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results[0].url, "https://security.apple.com/blog/expanding-pcc/")
    XCTAssertEqual(results[0].title, "Expanding Private Cloud Compute")
    XCTAssertEqual(
      results[0].snippet, "Alongside the next generation of Apple Intelligence.")
  }

  func testLimitBoundsTheRowsWeKeep() async throws {
    let engine = DuckDuckGoHTMLSearch(transport: Self.transport(Self.htmlFixture))
    let results = try await engine.search(query: "pcc", limit: 1)
    XCTAssertEqual(results.count, 1)
  }

  // MARK: 2) 막힌 것과 없는 것

  func testBrokerMovesToTheNextEngineWhenChallenged() async throws {
    let broker = WebSearchBroker(engines: [
      StubEngine(name: "first", outcome: .failure(WebSearchError.challenged)),
      StubEngine(name: "second", outcome: .success([Self.result])),
    ])
    let results = try await broker.search(query: "pcc", limit: 5)
    XCTAssertEqual(results, [Self.result])
  }

  /// **"없다"는 관찰된 사실이고 "못 물었다"는 실패다.** 한 칸으로 접으면 아무도
  /// 답하지 못한 차례가 "찾지 못했어요"라고 거짓을 말한다.
  func testBrokerSeparatesEmptyResultsFromNoAnswer() async throws {
    let answered = WebSearchBroker(engines: [
      StubEngine(name: "first", outcome: .success([])),
      StubEngine(name: "second", outcome: .success([])),
    ])
    let empty = try await answered.search(query: "pcc", limit: 5)
    XCTAssertEqual(empty, [])

    let silent = WebSearchBroker(engines: [
      StubEngine(name: "first", outcome: .failure(WebSearchError.challenged)),
      StubEngine(name: "second", outcome: .failure(WebSearchError.rejected(status: 503))),
    ])
    do {
      _ = try await silent.search(query: "pcc", limit: 5)
      XCTFail("아무도 답하지 못했는데 0건을 사실로 돌려줬다")
    } catch {
      XCTAssertEqual(error as? WebSearchError, .rejected(status: 503))
    }
  }

  // MARK: 3) 줄의 자리

  /// `identifier`에 주소가 서야 `ResolvableArgument.url`이 풀린다. 런타임이 주소를
  /// 찾는 자리는 이 하나다(`TurnRuntime.resolve`).
  func testSearchRowCarriesTheURLAsTheNextStepArgument() async throws {
    let tool = WebSearchTool(
      broker: WebSearchBroker(engines: [
        DuckDuckGoHTMLSearch(transport: Self.transport(Self.htmlFixture))
      ]))
    let receipt = try await tool.perform(
      ActionRequest(
        capability: .webSearch, arguments: ["query": .text("pcc")],
        origin: .modelPlan, accountID: "acct"))

    let rows = CapabilitySourceRow.rows(in: receipt.details)
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows[0].identifier, "https://security.apple.com/blog/private-cloud-compute/")
    XCTAssertEqual(rows[0].subtitle, results0Snippet)
    XCTAssertTrue(
      rows[0].body.isEmpty,
      "스니펫이 본문 자리에 들어갔다 — 읽기가 실패한 차례가 스니펫을 요약해 페이지를 읽은 척한다")
    XCTAssertEqual(receipt.coverage.first?.discoveredCount, 2)
    XCTAssertEqual(receipt.coverage.first?.readCount, 0, "검색이 읽었다고 적혔다")
  }

  private let results0Snippet =
    "Secure and private AI processing in the cloud poses a formidable new challenge."

  // MARK: 4) 차례 전체

  /// **한 번의 계획으로 세 단계.** 검색 결과를 PCC에 다시 보여 주고 "무엇을 열까"를
  /// 묻지 않는다 — 주소를 고르는 일은 기기에서 끝난다.
  func testSearchReadSummarizeChainKeepsRawTextOnDevice() async throws {
    let dispatcher = ActionDispatcher(
      ledger: SilentLedger(), currentAccountID: { "acct" })
    let page = String(repeating: "이 페이지의 본문 문장. ", count: 60)
    let model = ScriptedSummarizer(summary: "PCC는 서버로 확장됐다.")
    for tool in [
      WebSearchTool(
        broker: WebSearchBroker(engines: [
          DuckDuckGoHTMLSearch(transport: Self.transport(Self.htmlFixture))
        ])) as any CapabilityHandler,
      PageReadTool(page: page),
      SummarizeTool(model: model),
    ] {
      await dispatcher.register(tool)
    }

    var presented: ConversationTurnResult?
    var planningCalls = 0
    var finalizingPrompts: [String] = []
    let runtime = TurnRuntime(
      dispatcher: dispatcher,
      emit: { _ in },
      present: { presented = $0 },
      copy: .keysAsText,
      now: { Self.now },
      supervising: { _ in
        planningCalls += 1
        return .decided(
          TurnDecision(
            status: .complete,
            plan: ActionPlan(
              steps: [
                PlannedStep(
                  capability: .webSearch,
                  arguments: ["query": .text("Apple Private Cloud Compute")]),
                PlannedStep(capability: .webRead, arguments: [:], unresolved: ["url"]),
                PlannedStep(
                  capability: .textSummarize, arguments: [:], unresolved: ["sourceText"]),
              ], needs: nil)),
          ModelInvocationTrail(outcome: Self.receipt))
      },
      finalizing: { context, _ in
        finalizingPrompts.append(context.prompt)
        return FinalizationStep(
          answer: .written(
            headline: "PCC는 서버로 확장됐어요", points: [], relevant: [1],
            backend: .privateCloud),
          trail: ModelInvocationTrail(outcome: Self.receipt))
      })

    await runtime.run(
      TurnContextSnapshot(
        requestID: UUID(), accountID: "acct", conversationID: "conv",
        input: "애플 PCC 최신 변경사항 알려줘", recentMessages: [], submittedAt: Self.now,
        registeredCapabilities: [.webSearch, .webRead, .textSummarize]))

    // **PCC는 두 번이다**: 계획 한 번, 답 한 번. 중간에 되묻지 않는다.
    XCTAssertEqual(planningCalls, 1, "실행 중에 PCC를 다시 불렀다")
    XCTAssertEqual(finalizingPrompts.count, 1)
    XCTAssertEqual(presented?.phase, .completed, "차례가 닫히지 않았다")
    XCTAssertEqual(
      presented?.steps.map(\.capability.rawValue),
      ["web.search", "web.read", "text.summarize"],
      "한 번의 계획으로 세 단계가 돌지 않았다")

    // 주소가 검색 결과에서 읽기로, 읽은 원문이 기기 요약기로 넘어갔다.
    let summarized = try XCTUnwrap(model.received.first)
    XCTAssertEqual(model.received.count, 1)
    XCTAssertTrue(
      summarized.contains("이 페이지의 본문 문장."), "원문이 기기 요약기까지 오지 않았다")

    let prompt = try XCTUnwrap(finalizingPrompts.first)
    XCTAssertTrue(prompt.contains("PCC는 서버로 확장됐다"), "기기 요약이 근거로 서지 않았다")
    XCTAssertFalse(prompt.contains("result__a"), "SERP HTML이 PCC 문맥에 실렸다")
    XCTAssertFalse(prompt.contains("result__snippet"), "SERP HTML이 PCC 문맥에 실렸다")
    XCTAssertFalse(prompt.contains(page), "페이지 전문이 PCC 문맥에 실렸다")
    XCTAssertLessThanOrEqual(
      prompt.count, PCCContextBudget.standard.totalCharacters, "문맥이 예산을 넘었다")
  }

  // MARK: 5) 요약의 초점

  /// **줄일 원문은 앞 단계에서 오고, 모델이 쓰는 글은 초점이다.**
  ///
  /// 그 글이 `query`로 떨어지면 계약이 버리고(`SummarizeTool.contracts`), 요약은
  /// 초점 없이 돈다 — `"최신 변경사항만"`이 요약기에 닿지 않는다.
  func testSummarizeStepCarriesTheFocusFromThePlan() throws {
    CapabilityContract.register([
      CapabilityContract(
        .textSummarize,
        required: [CapabilityContract.Argument("sourceText")],
        optional: [CapabilityContract.Argument("focus")])
    ])
    let decision = ActionPlanValidator.validate(
      GeneratedTurnDecision(
        status: "complete",
        steps: [
          GeneratedActionStep(
            capability: "text.summarize", text: "최신 변경사항만", target: "", when: "",
            subject: "")
        ],
        needs: ""),
      allowed: [.textSummarize], conversationID: "conv", accountID: "acct",
      calendar: Calendar(identifier: .gregorian))

    let step = try XCTUnwrap(decision.plan.steps.first)
    XCTAssertEqual(step.arguments["focus"]?.textValue, "최신 변경사항만")
    XCTAssertTrue(
      step.unresolved.contains("sourceText"), "원문이 앞 단계에서 채워지는 자리가 아니게 됐다")
  }

  // MARK: 조립

  private static let result = WebSearchResult(
    title: "t", url: "https://example.com/a", snippet: "s")

  private static func transport(_ html: String) -> WebSearchTransport {
    { _ in Data(html.utf8) }
  }

  private static let receipt = ModelInvocationReceipt(
    phase: .planning, purpose: AdmissionJob.conversationPlan.rawValue,
    requestedBackend: .privateCloud, resolvedBackend: .privateCloud,
    pccAttempted: true, pccCompleted: true, onDeviceAttempted: false,
    onDeviceCompleted: false, fallbackReason: nil, inputCharacters: 0,
    latencyMilliseconds: 0)

  /// 실측 마크업(2026-09-17 `html.duckduckgo.com`)을 줄인 것. 광고 한 줄과
  /// 리다이렉트 한 줄을 섞어 뒀다.
  private static let htmlFixture = """
    <div class="result results_links_deep web-result">
      <h2 class="result__title">
        <a rel="nofollow" class="result__a" href="https://security.apple.com/blog/private-cloud-compute/">Private Cloud Compute: A new frontier for AI privacy in the cloud</a>
      </h2>
      <a class="result__url" href="https://security.apple.com/blog/private-cloud-compute/">
        security.apple.com/blog/private-cloud-compute/
      </a>
      <a class="result__snippet" href="https://security.apple.com/blog/private-cloud-compute/">Secure and <b>private</b> AI processing in the <b>cloud</b> poses a formidable new challenge.</a>
    </div>
    <div class="result result--ad">
      <h2 class="result__title">
        <a rel="nofollow" class="result__a" href="//duckduckgo.com/y.js?ad_domain=example.com">Sponsored thing</a>
      </h2>
      <a class="result__snippet" href="//duckduckgo.com/y.js">Buy now</a>
    </div>
    <div class="result results_links_deep web-result">
      <h2 class="result__title">
        <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdeveloper.apple.com%2Fprivate%2Dcloud%2Dcompute%2F&amp;rut=8f1">Private Cloud Compute - Apple Developer</a>
      </h2>
      <a class="result__snippet" href="https://developer.apple.com/private-cloud-compute/">Access <b>Apple&#x27;s</b> server-side foundation models.</a>
    </div>
    """

  /// 실측 마크업(2026-09-17 `lite.duckduckgo.com`). class가 단일 인용부호다.
  private static let liteFixture = """
    <table>
      <tr>
        <td>
          <a rel="nofollow" href="https://security.apple.com/blog/expanding-pcc/" class='result-link'>Expanding Private Cloud Compute</a>
        </td>
      </tr>
      <tr>
        <td>&nbsp;&nbsp;&nbsp;</td>
        <td class='result-snippet'>
          Alongside the next generation of <b>Apple</b> Intelligence.
        </td>
      </tr>
    </table>
    """
}

// MARK: - 대역

private struct StubEngine: WebSearchEngine {
  let name: String
  let outcome: Result<[WebSearchResult], any Error>

  func search(query: String, limit: Int) async throws -> [WebSearchResult] {
    try outcome.get()
  }
}

/// 주소 하나를 읽은 척한다. **본문을 줄에 담는 것이 요점이다** — 그 본문이
/// `sourceText`가 된다.
private struct PageReadTool: CapabilityHandler {
  let page: String

  var capabilities: Set<CapabilityID> { [.webRead] }

  func perform(_ request: ActionRequest) async throws -> ActionReceipt {
    guard let url = request.arguments["url"]?.textValue, !url.isEmpty else {
      throw ActionError.invalidArguments(reason: "url")
    }
    return ActionReceipt(
      requestID: request.id, capability: .webRead,
      summary: "web.read.result",
      details: CapabilitySourceRow.detail([
        CapabilitySourceRow(title: "Expanding PCC", subtitle: url, body: page, identifier: url)
      ]))
  }
}

/// 기기 요약기의 대역. **무엇을 받았는지 적어 둔다** — 원문이 여기까지 왔는지가
/// 관찰 지점이다.
private final class ScriptedSummarizer: OnDeviceTextModel, @unchecked Sendable {
  private let lock = NSLock()
  private let summary: String
  private var prompts: [String] = []

  init(summary: String) {
    self.summary = summary
  }

  var received: [String] {
    lock.lock()
    defer { lock.unlock() }
    return prompts
  }

  var isAvailable: Bool { true }

  func respond(
    instructions: String, prompt: String, purpose: AdmissionJob, maximumTokens: Int
  ) async throws -> String {
    lock.lock()
    prompts.append(prompt)
    lock.unlock()
    return summary
  }
}

private struct SilentLedger: ActionLedger {
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
