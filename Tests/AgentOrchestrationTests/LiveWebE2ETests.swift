import AgentKernel
import XCTest

@testable import AgentOrchestration

/// **L3: 살아 있는 웹.** 공급자에게 실제로 묻고, 받은 주소를 실제로 읽는다.
///
/// 이 층이 따로 있는 이유는 픽스처가 증명할 수 없는 것들이 있기 때문이다:
/// 공급자의 마크업이 바뀌었는가, 날짜 필터가 아직도 우리가 보내는 모양을 받는가,
/// 받아 온 HTML이 본문으로 읽히는가. 픽스처는 **우리가 어제 본 웹**을 증명한다.
///
/// 막히면 **건너뛴다.** DuckDuckGo는 한 IP에서 요청이 몰리면 202를 돌려주고
/// (실측 2026-09-17: 20분 이상) 그것은 우리 코드의 실패가 아니다 — 그 사실을
/// 실패로 적으면 실패의 뜻이 사라진다.
///
/// `./Scripts/test.sh e2e`로만 돈다.
@available(iOS 26.0, *)
final class LiveWebE2ETests: XCTestCase {

  // MARK: E01 — 살아 있는 검색

  /// 공급자가 지금도 **쓸 수 있는 줄**을 주는가.
  ///
  /// 단정은 마크업이 아니라 계약이다: 다음 단계가 읽을 수 있는 http(s) 주소가
  /// 식별자 자리에 있는가. 제목 글자를 단정하면 하루 만에 깨지는 시험이 된다.
  func testLiveSearchYieldsReadableAddresses() async throws {
    let rows = try await Self.search("Apple Private Cloud Compute")

    XCTAssertFalse(rows.isEmpty, "살아 있는 검색이 한 줄도 주지 않았다")
    for row in rows {
      let url = try XCTUnwrap(URL(string: row.identifier), "주소가 아니다: \(row.identifier)")
      XCTAssertTrue(
        url.scheme == "https" || url.scheme == "http", "읽을 수 없는 스킴: \(row.identifier)")
      XCTAssertFalse(row.title.isEmpty, "제목이 비었다: \(row.identifier)")
      // 공급자 중계 주소가 남으면 다음 단계가 검색 엔진의 페이지를 읽는다.
      XCTAssertFalse(row.identifier.contains("duckduckgo.com/l/"), "중계 주소가 벗겨지지 않았다")
    }
    print("📐 E01 live-search: rows=\(rows.count) first=\(rows.first?.identifier ?? "")")
  }

  // MARK: E02 — 검색 → 읽기

  /// 검색이 준 주소를 **실제로 받아 와 본문으로 읽는다.**
  ///
  /// 이 두 단계가 이어지는 것은 픽스처로 증명되지 않는다: 픽스처는 우리가 저장한
  /// HTML을 파서에 먹이고, 실제 페이지는 리다이렉트·charset·challenge를 들고 온다.
  func testLiveSearchFeedsRealWebRead() async throws {
    let rows = try await Self.search("Apple Private Cloud Compute security blog")
    let tool = WebReadTool()

    // 첫 줄이 열린다. 하나가 막히면(403·PDF·빈 문서) 다음 줄로 간다 —
    // 어느 한 사이트의 사정이 이 층의 판정이 되면 안 된다.
    var failures: [String] = []
    for row in rows.prefix(4) {
      do {
        let receipt = try await tool.perform(
          ActionRequest(
            capability: .webRead, arguments: ["url": .text(row.identifier)],
            origin: .modelPlan, accountID: "acct"))
        let read = try XCTUnwrap(CapabilitySourceRow.rows(in: receipt.details).first)

        XCTAssertGreaterThan(read.body.count, 200, "본문이 너무 짧다: \(row.identifier)")
        XCTAssertFalse(read.body.contains("<script"), "스크립트가 본문에 남았다")
        XCTAssertFalse(read.body.contains("<div"), "태그가 본문에 남았다")
        XCTAssertEqual(receipt.coverage.first?.readCount, 1)

        let resolved = TurnRuntime.resolvedValue(for: "sourceText", in: [receipt])
        XCTAssertEqual(
          resolved?.textValue?.isEmpty, false, "읽은 글이 요약 단계의 인자가 되지 않았다")

        print(
          "📐 E02 live-read: \(row.identifier) → \(read.body.count)자 "
            + "(자름=\(receipt.coverage.first?.truncated == true))")
        return
      } catch {
        failures.append("\(row.identifier): \(error)")
      }
    }
    throw XCTSkip("네 줄 모두 읽히지 않았다 — 공급자 사정이다:\n\(failures.joined(separator: "\n"))")
  }

  // MARK: E03 — 날짜 창의 공급자 계약

  /// **닫힌 날짜 구간이 실제로 걸리는가.**
  ///
  /// 이 저장소는 `df=2024-06-01..2024-06-30` 모양을 보낸다. 근거는 실측이었고
  /// (2026-09-17) 그 실측은 코드 주석에만 남아 있다 — 공급자가 이 인자를 바꾸는
  /// 날, 우리는 걸렀다고 믿은 채 안 걸린 목록을 받는다.
  ///
  /// 단정을 결과의 날짜로 하지 않는 이유: `html.duckduckgo.com`의 스니펫에는
  /// 발행일이 없다(10/10 확인). 그래서 **창이 결과를 바꾸는가**로 계약을 잡는다 —
  /// 서로 떨어진 두 창이 같은 목록을 주면 필터는 무시된 것이다.
  func testClosedDateWindowActuallyFilters() async throws {
    let engine = DuckDuckGoHTMLSearch()
    let query = "apple wwdc keynote"

    let old = try await Self.urls(engine, query: query, from: "2019-06-01", to: "2019-06-30")
    let recent = try await Self.urls(engine, query: query, from: "2024-06-01", to: "2024-06-30")

    XCTAssertFalse(old.isEmpty, "2019년 창이 0건이다")
    XCTAssertFalse(recent.isEmpty, "2024년 창이 0건이다")
    XCTAssertTrue(
      old.intersection(recent).count < min(old.count, recent.count),
      "떨어진 두 창이 같은 목록을 줬다 — 날짜 인자가 무시되고 있다")
    print("📐 E03 date-window: 2019=\(old.count) 2024=\(recent.count) 겹침=\(old.intersection(recent).count)")
  }

  // MARK: 살아 있는 문

  private static func search(_ query: String) async throws -> [CapabilitySourceRow] {
    let tool = WebSearchTool(broker: .standard)
    do {
      let receipt = try await tool.perform(
        ActionRequest(
          capability: .webSearch, arguments: ["query": .text(query)],
          origin: .modelPlan, accountID: "acct"))
      return CapabilitySourceRow.rows(in: receipt.details)
    } catch {
      throw XCTSkip("공급자가 답하지 않았다(막힘·네트워크): \(error)")
    }
  }

  private static func urls(
    _ engine: DuckDuckGoHTMLSearch, query: String, from: String, to: String
  ) async throws -> Set<String> {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    guard let after = formatter.date(from: from), let before = formatter.date(from: to) else {
      throw XCTSkip("날짜를 읽지 못했다")
    }
    do {
      let results = try await engine.search(
        query: query, limit: 10,
        window: WebSearchWindow(after: after, before: before, timeZone: TimeZone(identifier: "UTC")!))
      return Set(results.map(\.url))
    } catch {
      throw XCTSkip("공급자가 답하지 않았다(막힘·네트워크): \(error)")
    }
  }
}
