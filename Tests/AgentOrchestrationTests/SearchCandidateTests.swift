import AgentKernel
import XCTest

@testable import AgentOrchestration

/// **L0: 어느 줄을 읽을지 기기에서 고른다.** PCC도 네트워크도 부르지 않는다.
///
/// 이 층이 잡는 것은 실기에서 본 답이다. `"내 기록에 있는 PCC 메모와 최신 웹 내용을
/// 비교해줘"`가 공급자 1위를 읽었고 그 1위는 `Pointe Coupée Parish Government`의
/// 연락처 페이지였다(iPad, 실제 PCC, 2026-09-17). 아래 첫 시험이 그 차례다.
@available(iOS 26.0, *)
final class SearchCandidateTests: XCTestCase {
  /// 실기에서 DuckDuckGo가 `"PCC"`에 돌려준 모양. 1위가 우리가 찾는 것이 아니다.
  private static let rows = [
    CapabilitySourceRow(
      title: "Pointe Coupee Parish Government",
      subtitle: "160 East Main Street, New Roads, LA · (225) 638-9556",
      identifier: "https://pcparishgov.org/contact"),
    CapabilitySourceRow(
      title: "PCC | Portland Community College",
      subtitle: "Register for classes at PCC this term.",
      identifier: "https://www.pcc.edu/"),
    CapabilitySourceRow(
      title: "Private Cloud Compute: A new frontier for AI privacy in the cloud",
      subtitle: "Apple describes verifiable server inference for Apple Intelligence.",
      identifier: "https://security.apple.com/blog/private-cloud-compute/"),
  ]

  /// 내 기록이 고른다. **그 기록은 공개 웹으로 나가지 않는다** — 이미 받아 온 줄을
  /// 기기에서 다시 세우는 데만 쓰인다.
  func testPrivateContextPicksTheRelevantCandidate() {
    let query = "내 기록에 있는 PCC 메모와 최신 웹 내용을 비교해줘"
    let memo =
      "PCC 메모: 애플의 Private Cloud Compute는 서버 추론을 검증 가능하게 만드는 구조다. "
      + "공개된 이미지로만 검증이 성립한다."

    let blind = SearchCandidateSelector.rank(Self.rows, query: query)
    let informed = SearchCandidateSelector.rank(Self.rows, query: query, context: [memo])
    XCTAssertEqual(
      blind.first?.url, "https://www.pcc.edu/",
      "맥락이 없으면 낱말이 맞는 줄이 이긴다 — `PCC`를 제목에 든 대학 페이지다")
    XCTAssertNotEqual(
      blind.first?.url, "https://security.apple.com/blog/private-cloud-compute/",
      "맥락 없이 애플 페이지를 골랐다면 이 시험은 아무것도 증명하지 않는다")
    XCTAssertEqual(
      informed.first?.url, "https://security.apple.com/blog/private-cloud-compute/",
      "사적 맥락이 후보를 고르지 못했다")
  }

  /// 아는 것이 없으면 **공급자 순서를 지킨다.** 점수가 같을 때 순서를 흔들면
  /// 공급자의 순위라는 정보를 버리고 그 자리에 아무 규칙도 놓지 않는 것이다.
  func testProviderOrderSurvivesEqualScores() {
    let rows = [
      CapabilitySourceRow(title: "첫째", identifier: "https://a.example/1"),
      CapabilitySourceRow(title: "둘째", identifier: "https://b.example/2"),
      CapabilitySourceRow(title: "셋째", identifier: "https://c.example/3"),
    ]
    let ranked = SearchCandidateSelector.rank(rows, query: "무엇이든")
    XCTAssertEqual(ranked.map(\.url), rows.map(\.identifier))
    XCTAssertTrue(SearchCandidateSelector.isAmbiguous(ranked), "0점인데 갈렸다고 말했다")
  }

  /// 읽을 수 없는 문서는 **후보가 아니다.** `web.read`가 글이 아닌 것을 거절하므로
  /// 그 줄을 고르면 그 차례는 읽기 실패로 끝난다.
  func testUnreadableDocumentsAreExcluded() {
    let rows = [
      CapabilitySourceRow(
        title: "Private Cloud Compute 백서", identifier: "https://example.com/pcc.pdf"),
      CapabilitySourceRow(
        title: "Private Cloud Compute 소개", identifier: "https://example.com/pcc"),
    ]
    let ranked = SearchCandidateSelector.rank(rows, query: "private cloud compute")
    XCTAssertEqual(ranked.map(\.url), ["https://example.com/pcc"])
  }

  /// 한 사이트가 목록을 채우면 다른 후보를 볼 기회가 없다. 그 사이트의 **가장 잘
  /// 맞는 줄** 하나만 남긴다.
  func testOneHostKeepsOnlyItsBestRow() {
    let rows = [
      CapabilitySourceRow(
        title: "채용", subtitle: "일자리", identifier: "https://example.com/jobs"),
      CapabilitySourceRow(
        title: "Private Cloud Compute", subtitle: "검증 가능한 서버 추론",
        identifier: "https://example.com/pcc"),
      CapabilitySourceRow(title: "회사 소개", identifier: "https://example.com/about"),
      CapabilitySourceRow(
        title: "다른 곳의 PCC 정리", identifier: "https://other.example/pcc"),
    ]
    let ranked = SearchCandidateSelector.rank(rows, query: "private cloud compute")
    XCTAssertEqual(ranked.count, 2, "한 사이트의 줄이 여럿 남았다")
    XCTAssertEqual(ranked.first?.url, "https://example.com/pcc")
  }

  /// 1위와 2위가 같은 점수면 **갈리지 않았다.** 그때가 기기 모델에게 물을 자리이고,
  /// 점수가 갈렸을 때 부르는 것은 비용만 늘린다.
  func testTieIsAmbiguousAndClearWinnerIsNot() {
    let tied = [
      CapabilitySourceRow(title: "Private Cloud Compute", identifier: "https://a.example/"),
      CapabilitySourceRow(title: "private cloud compute", identifier: "https://b.example/"),
    ]
    XCTAssertTrue(
      SearchCandidateSelector.isAmbiguous(
        SearchCandidateSelector.rank(tied, query: "private cloud compute")))

    let decided = [
      CapabilitySourceRow(title: "Private Cloud Compute", identifier: "https://a.example/"),
      CapabilitySourceRow(title: "날씨", identifier: "https://b.example/"),
    ]
    XCTAssertFalse(
      SearchCandidateSelector.isAmbiguous(
        SearchCandidateSelector.rank(decided, query: "private cloud compute")))
  }

  // MARK: 런타임 — 불변식이 고른 줄을 읽는가

  /// 차례 전체를 돌려서 본다. 계획에 `web.read`가 없고, 검색 1위는 엉뚱하고, 내
  /// 기록에는 맥락이 있다 — 실기 P02의 모양이다.
  @MainActor
  func testTurnReadsTheCandidateChosenFromPrivateContext() async throws {
    let memo =
      "PCC 메모: 애플의 Private Cloud Compute는 서버 추론을 검증 가능하게 만든다."
    let read = FixtureTool(.webRead, required: [.init("url")]) { request in
      [
        CapabilitySourceRow(
          title: "PCC", body: "검증은 공개된 이미지로만 성립한다.",
          identifier: request.arguments["url"]?.textValue ?? "")
      ]
    }
    let run = await ScenarioRunner.run(
      GoldenScenario(
        name: "S01 candidate-choice",
        input: "내 기록에 있는 PCC 메모와 최신 웹 내용을 비교해줘",
        scope: [.memorySearch, .memoryRead, .webSearch, .webRead],
        plan: [
          PlannedStep(capability: .memorySearch, arguments: ["query": .text("PCC")]),
          PlannedStep(capability: .memoryRead, arguments: [:], unresolved: ["itemID"]),
          PlannedStep(capability: .webSearch, arguments: ["query": .text("PCC")]),
        ],
        tools: [
          FixtureTool(.memorySearch, required: [.init("query")]) { _ in
            [CapabilitySourceRow(title: "PCC 메모", identifier: "memo-1")]
          },
          FixtureTool(.memoryRead, required: [.init("itemID")]) { _ in
            [CapabilitySourceRow(title: "PCC 메모", body: memo, identifier: "memo-1")]
          },
          WebSearchTool(
            broker: WebSearchBroker(engines: [
              StubSearchEngine(
                name: "stub",
                outcome: .success(
                  Self.rows.map {
                    WebSearchResult(title: $0.title, url: $0.identifier, snippet: $0.subtitle)
                  }))
            ])),
          read,
        ],
        budget: ScenarioBudget(contextBaseline: 417, materials: 2, retrievedRows: 6)))

    try run.assertBounds()
    XCTAssertEqual(
      run.executed, ["memory.search", "memory.read", "web.search", "web.read"],
      "빠진 읽기가 메워지지 않았다")
    XCTAssertEqual(
      read.requests.first?.arguments["url"]?.textValue,
      "https://security.apple.com/blog/private-cloud-compute/",
      "공급자 1위를 읽었다 — 사적 맥락이 선택에 쓰이지 않았다")
  }
}
