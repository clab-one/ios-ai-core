import Foundation

/// `web.search`의 손. **주소 후보를 돌려주는 것이 전부다.**
///
/// 이 툴이 돌려주는 줄의 `identifier`가 곧 다음 단계의 인자다
/// (`ResolvableArgument.url` → `web.read`). 그래서 이 자리에 주소를 넣지 않으면
/// 검색은 성공하고 읽기는 되물음으로 끝난다 — 런타임이 주소를 찾는 자리는 여기
/// 하나다.
///
/// 본문 자리(`body`)는 **비워 둔다.** 스니펫은 본문이 아니고, 본문을 들고 오는 일은
/// 다음 단계(`web.read`)의 몫이다. 그 자리에 스니펫을 넣으면 읽기가 실패한 차례가
/// 스니펫을 본문으로 삼아 요약하고, 그 요약은 페이지를 읽은 것처럼 보인다.
public struct WebSearchTool: CapabilityHandler {
  /// 돌려줄 줄의 기본 개수. **첫 줄이 열린다** — 많이 돌려줘도 읽는 것은 하나다.
  public static let defaultLimit = 5
  /// 상한. 모델이 요구하는 값과 무관하게 이 값을 넘지 않는다.
  public static let maximumLimit = 10

  private let broker: WebSearchBroker

  public init(broker: WebSearchBroker = .standard) {
    self.broker = broker
  }

  public var capabilities: Set<CapabilityID> { [.webSearch] }

  public func perform(_ request: ActionRequest) async throws -> ActionReceipt {
    guard
      let query = request.arguments["query"]?.textValue?
        .trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty
    else { throw ActionError.invalidArguments(reason: "query") }

    let limit = Self.limit(request.arguments["limit"]?.numberValue)
    let results = try await search(
      Self.scoped(query: query, site: request.arguments["site"]?.textValue),
      limit: limit,
      window: Self.window(
        after: request.arguments["after"]?.dateValue,
        before: request.arguments["before"]?.dateValue,
        now: request.requestedAt))

    let rows = results.map { result in
      CapabilitySourceRow(
        title: result.title,
        // 스니펫은 부제다. 사람이 읽는 한 줄이고, 요약의 재료가 아니다.
        subtitle: result.snippet,
        identifier: result.url)
    }
    return ActionReceipt(
      requestID: request.id, capability: .webSearch,
      summary: "web.search.result",
      details: CapabilitySourceRow.detail(rows),
      // **읽은 범위를 적는다.** 찾은 건수와 읽은 건수는 다르고, 읽는 일은 다음
      // 단계가 한다(`readCount: 0`).
      coverage: [
        CoverageRecord(
          binding: .publicWeb, capability: .webSearch,
          queryFingerprint: ActionFingerprint.arguments(request.arguments),
          state: .complete, discoveredCount: rows.count, readCount: 0,
          paginationExhausted: true)
      ])
  }

  /// 찾지 못한 것과 **묻지 못한 것**을 가른다.
  ///
  /// 엔진이 답하고 0건이면 그것은 관찰된 사실이므로 빈 줄의 수령증이 된다. 아무도
  /// 답하지 못했으면 실패다 — 그때 0건을 돌려주면 화면이 "찾지 못했어요"라고
  /// 거짓을 말하고, 사용자는 다시 물어볼 이유를 알 수 없다.
  private func search(
    _ query: String, limit: Int, window: WebSearchWindow?
  ) async throws -> [WebSearchResult] {
    do {
      return try await broker.search(query: query, limit: limit, window: window)
    } catch {
      // 사유 코드에 **질의를 담지 않는다** — 원장과 계측에 남는 값이다(§35).
      throw ActionError.failed(reason: "web.search.unavailable")
    }
  }

  /// 시간 창. **위 끝은 오늘이다.**
  ///
  /// `"최신"`을 물었을 때 기준이 되는 오늘은 이 차례가 제출된 시각에서 온다
  /// (`ActionRequest.requestedAt`) — 모델이 아는 날짜는 자기 학습 시점이고, 그
  /// 값으로 창을 세우면 몇 달 전이 "최신"이 된다(§45).
  ///
  /// 아래 끝이 없으면 공급자가 창을 무시하지만(`WebSearchWindow.dayRange`) 창
  /// 자체는 세운다 — 세운 창을 무엇에 쓸지는 부르는 쪽의 몫이다.
  private static func window(
    after: Date?, before: Date?, now: Date
  ) -> WebSearchWindow? {
    guard after != nil || before != nil else { return nil }
    return WebSearchWindow(
      after: after, before: min(before ?? now, now), timeZone: .current)
  }

  /// `site`는 질의 연산자로 옮긴다. 공급자별 인자로 넘기지 않는 이유는 능력의
  /// 이름에 공급자가 없기 때문이다 — `site:` 연산자는 어느 엔진에서도 성립한다.
  private static func scoped(query: String, site: String?) -> String {
    guard let site = site?.trimmingCharacters(in: .whitespacesAndNewlines),
      !site.isEmpty, !query.lowercased().contains("site:")
    else { return query }
    return "site:\(site) \(query)"
  }

  private static func limit(_ requested: Double?) -> Int {
    guard let requested, requested >= 1 else { return defaultLimit }
    return min(Int(requested), maximumLimit)
  }
}
