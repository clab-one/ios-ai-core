import AgentKernel
import XCTest

@testable import AgentOrchestration

/// **golden 8.** 코어가 지금 실제로 할 수 있는 일들을, PCC를 부르지 않고 끝까지 돈다.
///
/// 여기서 대역인 것은 셋뿐이다: 계획(PCC #1), 답(PCC #2), 그리고 툴. 그 사이의
/// resolver·계약·근거 압축·문맥 조립은 전부 제품 코드다. 그래서 이 층은 **기능**과
/// **비용**을 함께 본다:
///
/// 1. 계획한 대로 돌았는가(순서·바인딩).
/// 2. 원문과 손잡이가 PCC 문맥에 **없는가.**
/// 3. 문맥이 기준선 안에 있는가 — 기능이 성공했는데 문맥이 두 배가 된 커밋은 회귀다.
///
/// 기준선은 실측값이다(2026-09-17). 다시 재야 할 때는 실행 로그의 `📐` 줄을 본다.
@available(iOS 26.0, *)
@MainActor
final class GoldenScenarioTests: XCTestCase {
  /// 읽은 페이지의 **깊은 곳**에 둔 표식. 앞부분만 자르는 구현은 이 글자를 남기지
  /// 않지만, 원문을 그대로 올리는 구현은 남긴다.
  private static let pageMarker = "PAGE-DEEP-MARKER"
  private static let page =
    String(repeating: "이 페이지의 본문 문장. ", count: 120) + pageMarker
  /// 공급자가 쓴 한 줄. **우리가 읽지 않은 문장이다.**
  private static let snippet = "SNIPPET-WE-NEVER-READ"
  /// 불투명 손잡이. 사람이 읽을 것이 아니고 답의 재료도 아니다.
  private static let itemID = "ITEM-OPAQUE-7F3A"

  // MARK: G01 — 웹 최신 정보

  func testG01WebLatest() async throws {
    let model = ScenarioOnDeviceModel(reply: "PCC가 서버로 확장됐다.")
    let read = FixtureTool(.webRead, required: [.init("url")]) { request in
      [
        CapabilitySourceRow(
          title: "PCC", body: Self.page,
          identifier: request.arguments["url"]?.textValue ?? "")
      ]
    }
    let run = await ScenarioRunner.run(
      GoldenScenario(
        name: "G01 web-latest",
        input: "애플 PCC 최신 변경사항 알려줘",
        scope: [.webSearch, .webRead, .textSummarize],
        plan: [
          PlannedStep(capability: .webSearch, arguments: ["query": .text("PCC 최신")]),
          PlannedStep(capability: .webRead, arguments: [:], unresolved: ["url"]),
          PlannedStep(
            capability: .textSummarize, arguments: [:], unresolved: ["sourceText"]),
        ],
        tools: [
          WebSearchTool(
            broker: WebSearchBroker(engines: [
              StubSearchEngine(
                name: "stub",
                outcome: .success([
                  WebSearchResult(
                    title: "PCC", url: "https://example.com/pcc", snippet: Self.snippet)
                ]))
            ])),
          read,
          SummarizeTool(model: model),
        ],
        budget: ScenarioBudget(contextBaseline: 377, materials: 2, retrievedRows: 3),
        forbidden: [Self.pageMarker, Self.snippet]))

    try run.assertBounds()
    XCTAssertEqual(
      run.executed, ["web.search", "web.read", "text.summarize"], "계획한 순서로 돌지 않았다")
    XCTAssertEqual(
      read.requests.first?.arguments["url"]?.textValue, "https://example.com/pcc",
      "검색 결과의 주소가 읽기로 넘어가지 않았다")
    // 원문은 기기 요약기까지만 갔다.
    XCTAssertEqual(model.received.count, 1)
    XCTAssertTrue(
      model.received.first?.contains(Self.pageMarker) == true, "원문이 기기 모델에 닿지 않았다")
  }

  // MARK: G02 — 주소 직접 읽기

  func testG02ReadURL() async throws {
    let model = ScenarioOnDeviceModel(reply: "이 글의 요지.")
    let run = await ScenarioRunner.run(
      GoldenScenario(
        name: "G02 read-url",
        input: "https://example.com/pcc 이거 요약해줘",
        scope: [.webRead, .textSummarize],
        plan: [
          PlannedStep(
            capability: .webRead,
            arguments: ["url": .text("https://example.com/pcc")]),
          PlannedStep(
            capability: .textSummarize, arguments: [:], unresolved: ["sourceText"]),
        ],
        tools: [
          FixtureTool(.webRead, required: [.init("url")]) { _ in
            [CapabilitySourceRow(title: "PCC", body: Self.page)]
          },
          SummarizeTool(model: model),
        ],
        budget: ScenarioBudget(contextBaseline: 409, materials: 2, retrievedRows: 2),
        forbidden: [Self.pageMarker]))

    try run.assertBounds()
    XCTAssertEqual(run.executed, ["web.read", "text.summarize"])
  }

  // MARK: G03 — 긴 페이지

  /// **50KB가 들어와도 PCC 문맥은 자라지 않는다.**
  ///
  /// 이 시나리오의 요점은 요약 품질이 아니라 **분리**다: 원문의 크기가 PCC 비용에
  /// 비례하면 긴 페이지 하나가 차례 하나의 예산을 먹는다.
  func testG03LongPageDoesNotGrowTheContext() async throws {
    let long = String(repeating: "긴 문서의 문장이 이어진다. ", count: 2_000) + Self.pageMarker
    XCTAssertGreaterThan(long.count, 25_000, "픽스처가 충분히 길지 않다")

    let model = ScenarioOnDeviceModel(reply: "긴 글의 요지 한 줄.")
    let run = await ScenarioRunner.run(
      GoldenScenario(
        name: "G03 long-page",
        input: "이 문서 핵심만 알려줘",
        scope: [.webRead, .textSummarize],
        plan: [
          PlannedStep(
            capability: .webRead, arguments: ["url": .text("https://example.com/long")]),
          PlannedStep(
            capability: .textSummarize, arguments: [:], unresolved: ["sourceText"]),
        ],
        tools: [
          FixtureTool(.webRead, required: [.init("url")]) { _ in
            [CapabilitySourceRow(title: "긴 문서", body: long)]
          },
          SummarizeTool(model: model),
        ],
        budget: ScenarioBudget(contextBaseline: 362, materials: 2, retrievedRows: 2),
        forbidden: [Self.pageMarker]))

    try run.assertBounds()
    // 원문 대비 압축률. 이 값이 1에 가까워지면 압축이 꺼진 것이다.
    XCTAssertLessThan(
      Double(run.largestContext) / Double(long.count), 0.1,
      "PCC 문맥이 원문 크기를 따라갔다")
  }

  // MARK: G04 — 기억 조회

  func testG04MemoryLookup() async throws {
    let read = FixtureTool(.memoryRead, required: [.init("itemID")]) { _ in
      [CapabilitySourceRow(title: "여권", body: "여권 만료는 2027년 3월이다.")]
    }
    let run = await ScenarioRunner.run(
      GoldenScenario(
        name: "G04 memory-lookup",
        input: "내 여권 언제 만료되는지 저장해둔 거 찾아줘",
        scope: [.memorySearch, .memoryRead],
        plan: [
          PlannedStep(capability: .memorySearch, arguments: ["query": .text("여권")]),
          PlannedStep(capability: .memoryRead, arguments: [:], unresolved: ["itemID"]),
        ],
        tools: [
          FixtureTool(.memorySearch, required: [.init("query")]) { _ in
            [CapabilitySourceRow(title: "여권 메모", identifier: Self.itemID)]
          },
          read,
        ],
        budget: ScenarioBudget(contextBaseline: 329, materials: 2, retrievedRows: 2),
        // **손잡이는 답의 재료가 아니다.** 이 값이 문맥에 서면 모델이 그것을 사실로
        // 읽고 답에 적는다(실기 2026-09-15: `"ID는 52C3E0B2-…입니다"`).
        forbidden: [Self.itemID]))

    try run.assertBounds()
    XCTAssertEqual(run.executed, ["memory.search", "memory.read"])
    XCTAssertEqual(
      read.requests.first?.arguments["itemID"]?.textValue, Self.itemID,
      "찾은 기록의 손잡이가 읽기로 넘어가지 않았다")
  }

  // MARK: G05 — 기억과 웹 비교

  /// **대표 benchmark.** 한 차례가 사적 기록과 공개 웹을 함께 들고 온다.
  ///
  /// 이 하나가 검색·읽기·요약·근거 병합·범위 제한을 동시에 본다. 그리고 비용의
  /// 기준선도 여기서 가장 높다 — 출처가 둘이면 근거도 둘이다.
  func testG05MemoryVersusWeb() async throws {
    let model = ScenarioOnDeviceModel(reply: "웹은 서버 확장을 말하고, 메모는 기기 처리만 적혀 있다.")
    let run = await ScenarioRunner.run(
      GoldenScenario(
        name: "G05 memory-vs-web",
        input: "저장해둔 PCC 메모와 오늘 웹의 최신 내용을 비교해",
        scope: [.memorySearch, .memoryRead, .webSearch, .webRead, .textSummarize],
        plan: [
          PlannedStep(capability: .memorySearch, arguments: ["query": .text("PCC")]),
          PlannedStep(capability: .memoryRead, arguments: [:], unresolved: ["itemID"]),
          PlannedStep(capability: .webSearch, arguments: ["query": .text("PCC 최신")]),
          PlannedStep(capability: .webRead, arguments: [:], unresolved: ["url"]),
          PlannedStep(
            capability: .textSummarize, arguments: [:], unresolved: ["sourceText"]),
        ],
        tools: [
          FixtureTool(.memorySearch, required: [.init("query")]) { _ in
            [CapabilitySourceRow(title: "PCC 메모", identifier: Self.itemID)]
          },
          FixtureTool(.memoryRead, required: [.init("itemID")]) { _ in
            [CapabilitySourceRow(title: "PCC 메모", body: "PCC는 기기에서만 처리한다고 적어 뒀다.")]
          },
          WebSearchTool(
            broker: WebSearchBroker(engines: [
              StubSearchEngine(
                name: "stub",
                outcome: .success([
                  WebSearchResult(
                    title: "PCC", url: "https://example.com/pcc", snippet: Self.snippet)
                ]))
            ])),
          FixtureTool(.webRead, required: [.init("url")]) { _ in
            [CapabilitySourceRow(title: "PCC", body: Self.page)]
          },
          SummarizeTool(model: model),
        ],
        budget: ScenarioBudget(contextBaseline: 587, materials: 4, retrievedRows: 5),
        forbidden: [Self.pageMarker, Self.snippet, Self.itemID]))

    try run.assertBounds()
    XCTAssertEqual(
      run.executed,
      ["memory.search", "memory.read", "web.search", "web.read", "text.summarize"],
      "다섯 단계가 한 번의 계획으로 돌지 않았다")
    // 사적 기록과 공개 웹이 **함께** 근거에 섰다.
    let context = try XCTUnwrap(run.finalizingContexts.first)
    XCTAssertTrue(context.contains("기기에서만 처리한다"), "사적 기록이 근거에서 빠졌다")
    XCTAssertTrue(context.contains("웹은 서버 확장을 말하고"), "웹 요약이 근거에서 빠졌다")
  }

  // MARK: G06 — 일정 조회

  func testG06CalendarQuery() async throws {
    let run = await ScenarioRunner.run(
      GoldenScenario(
        name: "G06 calendar-query",
        input: "내일 일정 뭐 있어?",
        scope: [.calendarSearch],
        plan: [
          PlannedStep(
            capability: .calendarSearch,
            arguments: ["start": .timestamp(ScenarioRunner.now)])
        ],
        tools: [
          FixtureTool(
            .calendarSearch,
            optional: [
              .init("query"), .init("start", .timestamp), .init("end", .timestamp),
            ]
          ) { _ in
            [
              CapabilitySourceRow(
                title: "팀 회의", subtitle: "오후 3시", identifier: "EVENT-1")
            ]
          }
        ],
        budget: ScenarioBudget(contextBaseline: 237, materials: 1, retrievedRows: 1)))

    try run.assertBounds()
    XCTAssertEqual(run.executed, ["calendar.search"])
  }

  // MARK: G07 — 미리 알림 만들기

  func testG07CreateReminder() async throws {
    let create = FixtureTool(
      .remindersCreate, required: [.init("title")],
      optional: [.init("due", .timestamp), .init("hasClockTime", .flag)]
    ) { _ in [] }
    let run = await ScenarioRunner.run(
      GoldenScenario(
        name: "G07 create-reminder",
        input: "내일 오전에 약 먹기 알림 만들어줘",
        scope: [.remindersCreate],
        plan: [
          PlannedStep(
            capability: .remindersCreate, arguments: ["title": .text("약 먹기")])
        ],
        tools: [create],
        budget: ScenarioBudget(contextBaseline: 274, materials: 1, retrievedRows: 0)))

    try run.assertBounds()
    XCTAssertEqual(run.executed, ["reminders.create"])
    XCTAssertEqual(create.requests.first?.arguments["title"]?.textValue, "약 먹기")
  }

  // MARK: G08 — 웹에서 읽은 것을 기억으로

  /// **공개 웹에서 읽은 것이 사적 저장으로 간다.**
  ///
  /// 저장할 글은 계획 시점에 존재하지 않는다 — 읽고 줄인 뒤에 생긴다. 그래서 이
  /// 자리는 앞 단계의 산출로 채워져야 하고(`ResolvableArgument.body`), 모델이 미리
  /// 쓴 문장으로 채우면 읽지도 않은 내용을 저장한다.
  func testG08WebToMemory() async throws {
    let model = ScenarioOnDeviceModel(reply: "PCC가 서버로 확장됐다.")
    let save = FixtureTool(
      .memorySave, required: [.init("body")], optional: [.init("title")]
    ) { _ in [] }
    let run = await ScenarioRunner.run(
      GoldenScenario(
        name: "G08 web-to-memory",
        input: "PCC 최신 소식 찾아서 메모로 저장해줘",
        scope: [.webSearch, .webRead, .textSummarize, .memorySave],
        plan: [
          PlannedStep(capability: .webSearch, arguments: ["query": .text("PCC 최신")]),
          PlannedStep(capability: .webRead, arguments: [:], unresolved: ["url"]),
          PlannedStep(
            capability: .textSummarize, arguments: [:], unresolved: ["sourceText"]),
          PlannedStep(capability: .memorySave, arguments: [:], unresolved: ["body"]),
        ],
        tools: [
          WebSearchTool(
            broker: WebSearchBroker(engines: [
              StubSearchEngine(
                name: "stub",
                outcome: .success([
                  WebSearchResult(
                    title: "PCC", url: "https://example.com/pcc", snippet: Self.snippet)
                ]))
            ])),
          FixtureTool(.webRead, required: [.init("url")]) { _ in
            [CapabilitySourceRow(title: "PCC", body: Self.page)]
          },
          SummarizeTool(model: model),
          save,
        ],
        budget: ScenarioBudget(contextBaseline: 487, materials: 3, retrievedRows: 3),
        forbidden: [Self.pageMarker, Self.snippet]))

    try run.assertBounds()
    XCTAssertEqual(
      run.executed, ["web.search", "web.read", "text.summarize", "memory.save"])
    // **저장된 것은 요약이다.** 원문도, 모델이 미리 쓴 문장도 아니다.
    XCTAssertEqual(
      save.requests.first?.arguments["body"]?.textValue, "PCC가 서버로 확장됐다.",
      "읽고 줄인 글이 저장 자리로 흐르지 않았다")
  }

  // MARK: G09 — 읽기를 뺀 계획

  /// **찾았으면 읽는다.** 계획에 읽기가 없어도 그렇다.
  ///
  /// 실기 2026-09-17(iPad, 실제 PCC)에서 PCC는 `"찾아서 요약해서 저장해줘"`의
  /// 계획을 `web.search → text.summarize → memory.save`로 냈다. 읽기가 없는데
  /// 요약이 성립한 이유는 원문 자리가 **검색 줄의 제목과 스니펫**으로 채워졌기
  /// 때문이다 — 그 차례는 페이지를 한 장도 열지 않고 공급자가 쓴 한 줄을 요약해
  /// 기록으로 저장하고 `completed`로 닫혔다.
  ///
  /// 그래서 둘을 함께 본다: 손잡이 줄은 원문 자리를 채우지 못하고(`produces`),
  /// 채우지 못한 그 자리는 **되물음이 아니라 읽기로** 메워진다.
  func testG09SearchWithoutReadStillReadsThePage() async throws {
    let model = ScenarioOnDeviceModel(reply: "PCC가 서버로 확장됐다.")
    let save = FixtureTool(
      .memorySave, required: [.init("body")], optional: [.init("title")]
    ) { _ in [] }
    let read = FixtureTool(.webRead, required: [.init("url")]) { _ in
      [CapabilitySourceRow(title: "PCC", body: Self.page)]
    }
    let run = await ScenarioRunner.run(
      GoldenScenario(
        name: "G09 search-without-read",
        input: "PCC 최신 소식 찾아서 요약해서 메모로 저장해줘",
        scope: [.webSearch, .webRead, .textSummarize, .memorySave],
        // **계획에 `web.read`가 없다.** 이것이 실기에서 PCC가 낸 계획이다.
        plan: [
          PlannedStep(capability: .webSearch, arguments: ["query": .text("PCC 최신")]),
          PlannedStep(
            capability: .textSummarize, arguments: [:], unresolved: ["sourceText"]),
          PlannedStep(capability: .memorySave, arguments: [:], unresolved: ["body"]),
        ],
        tools: [
          WebSearchTool(
            broker: WebSearchBroker(engines: [
              StubSearchEngine(
                name: "stub",
                outcome: .success([
                  WebSearchResult(
                    title: "PCC", url: "https://example.com/pcc", snippet: Self.snippet)
                ]))
            ])),
          read,
          SummarizeTool(model: model),
          save,
        ],
        budget: ScenarioBudget(contextBaseline: 492, materials: 3, retrievedRows: 3),
        forbidden: [Self.pageMarker, Self.snippet]))

    try run.assertBounds()
    XCTAssertEqual(
      run.executed, ["web.search", "web.read", "text.summarize", "memory.save"],
      "빠진 읽기가 메워지지 않았다")
    XCTAssertEqual(
      read.requests.first?.arguments["url"]?.textValue, "https://example.com/pcc",
      "검색이 준 주소를 읽지 않았다")
    // **요약한 것은 페이지다.** 스니펫이 아니다.
    XCTAssertEqual(model.received.count, 1)
    let material = try XCTUnwrap(model.received.first)
    XCTAssertTrue(material.contains(Self.pageMarker), "페이지 본문이 요약기에 닿지 않았다")
    XCTAssertFalse(material.contains(Self.snippet), "공급자가 쓴 한 줄을 요약했다")
    XCTAssertEqual(
      save.requests.first?.arguments["body"]?.textValue, "PCC가 서버로 확장됐다.")
  }
}
