import Foundation

/// 검색 결과 한 줄.
///
/// **기기가 고르고 PCC는 고르지 않는다.** 검색 결과 열 건을 PCC에 보여 주고
/// "무엇을 열까"를 묻는 구조는 이 저장소의 방향과 반대다 — 주소를 고르는 일은
/// 기기에서 끝나고(`ResolvableArgument.url`), PCC는 그 뒤에 만들어진 작은 근거만
/// 본다.
public struct WebSearchResult: Sendable, Hashable {
  public let title: String
  public let url: String
  public let snippet: String
  /// 결과 목록이 적어 준 발행 날짜. **없으면 "모른다"다** — 창 밖이라는 뜻이
  /// 아니다. 공급자가 적어 주지 않는 결과가 흔하므로 이 값으로 거르는 일은
  /// 값이 있는 줄에만 일어난다(`WebSearchBroker.inWindow`).
  public let published: Date?

  public init(title: String, url: String, snippet: String, published: Date? = nil) {
    self.title = title
    self.url = url
    self.snippet = snippet
    self.published = published
  }
}

/// 검색의 **시간 창.**
///
/// `"최신"`을 물으면 기준은 **오늘**이다. 그 오늘은 기기의 벽시계에서 오고
/// (`ActionRequest.requestedAt`) 모델이 정하지 않는다 — 모델이 아는 날짜는 자기
/// 학습 시점이지 사용자의 오늘이 아니다(§45).
///
/// 시간대를 값으로 드는 이유: 하루의 경계가 시간대에 따라 다르다. UTC로 접으면
/// KST 오전 한 시의 "오늘"이 어제가 되고, 오늘 나온 글이 창 밖으로 밀린다.
///
/// **공급자는 이 창을 그대로 받지 못한다.** 열쇠 없는 검색 창구가 받는 최신성은
/// "지난 하루·주·달·해" 같은 굵은 값뿐이다. 그래서 창은 두 번 쓰인다: 공급자에게는
/// 창을 덮는 가장 작은 굵은 값을 보내고(`WebSearchHTTP.recency`), 정확한 경계는
/// 기기에서 자른다(`WebSearchBroker.inWindow`).
public struct WebSearchWindow: Sendable, Equatable {
  /// 이 시각 이후. 없으면 아래 끝이 열려 있다.
  public let after: Date?
  /// 이 시각까지. **부르는 쪽이 오늘을 넣는다.**
  public let before: Date
  /// 이 차례의 오늘.
  ///
  /// `before`와 따로 드는 이유는 굵은 필터가 **오늘에 매달려 있기** 때문이다 —
  /// `"지난 주"`는 창의 위 끝에서 세는 값이 아니라 지금에서 세는 값이다. 지난달
  /// 어느 한 주를 묻는 창에 `"지난 주"`를 보내면 공급자가 창 밖만 돌려준다.
  public let asOf: Date
  public let timeZone: TimeZone

  public init(after: Date?, before: Date, asOf: Date, timeZone: TimeZone) {
    self.after = after
    self.before = before
    self.asOf = asOf
    self.timeZone = timeZone
  }

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
  }

  /// 창의 아래 끝이 **며칠 전인가.** 아래 끝이 열려 있으면 없다.
  public var daysSinceStart: Int? {
    guard let after else { return nil }
    return calendar.dateComponents(
      [.day], from: calendar.startOfDay(for: after),
      to: calendar.startOfDay(for: asOf)
    ).day
  }

  /// 이 날짜가 창 안에 드는가. **하루 단위로 본다** — 결과 목록이 적어 주는 것은
  /// 날짜이고, 그 날짜에 시각은 없다.
  public func contains(_ date: Date) -> Bool {
    let calendar = self.calendar
    let day = calendar.startOfDay(for: date)
    if let after, day < calendar.startOfDay(for: after) { return false }
    return day <= calendar.startOfDay(for: before)
  }
}

/// 웹에서 찾는 **한 가지 방법**.
///
/// 공급자 이름이 능력에 들어가지 않는다 — `web.search`는 "웹에서 찾는다"의
/// 이름이고, 어느 서비스로 찾는지는 이 구현이 정한다.
///
/// 열쇠를 요구하지 않는 것이 이 자리의 요건이다. 예전에는 번들에서 API 키를 읽는
/// 설정 하나가 있었고(`WebSearchConfiguration`), 그 값이 없는 앱에서 `web.search`는
/// 아예 없는 능력이었다 — 그리고 그 설정을 쓰는 구현은 끝내 없었다.
public protocol WebSearchEngine: Sendable {
  /// 로그와 계측에 남을 이름. **질의는 담지 않는다** — 사용자 글이다.
  var name: String { get }
  /// - Parameter window: 시간 창. nil이면 공급자의 기본 정렬을 쓴다.
  func search(
    query: String, limit: Int, window: WebSearchWindow?
  ) async throws -> [WebSearchResult]
}

/// 찾지 못했다. **사유를 나눠 든다** — 없는 것과 막힌 것은 다른 사실이다.
public enum WebSearchError: Error, Sendable, Equatable {
  /// 어느 엔진도 답하지 못했다.
  case noEngineAnswered
  case malformedResponse
  /// 공급자가 사람인지 물었다. **우회하지 않는다** — 다음 공급자로 간다.
  case challenged
  case rejected(status: Int)
}

/// 엔진 여러 개를 **순서대로** 쓴다.
///
/// 하나가 막히면 다음으로 간다. 막힘을 우회하지 않는 이유는 그것이 자동화 차단을
/// 무력화하는 구조이기 때문이다 — 다른 문을 두는 것과 같은 문을 부수는 것은 다르다.
public struct WebSearchBroker: Sendable {
  private static let log = AgentHost.logger("web-search")

  public let engines: [any WebSearchEngine]

  public init(engines: [any WebSearchEngine]) {
    self.engines = engines
  }

  /// 코어가 싣는 순서. 둘 다 열쇠가 필요 없다.
  ///
  /// 실측 2026-09-17: `html.duckduckgo.com`은 User-Agent가 없으면 202 challenge를
  /// 돌려주고, iPhone UA로는 200에 결과 열 건을 돌려준다. `www.startpage.com`은
  /// POST를 307로 돌려보내고 `www.mojeek.com`은 JavaScript challenge를 세운다 —
  /// 그래서 그 둘은 싣지 않았다. 헤드리스 브라우저를 iOS에 들이는 선택은 이 저장소의
  /// 무게와 맞지 않는다.
  public static var standard: WebSearchBroker {
    WebSearchBroker(engines: [DuckDuckGoHTMLSearch(), DuckDuckGoLiteSearch()])
  }

  /// **"없다"와 "못 물었다"를 구별한다.**
  ///
  /// 한 곳이라도 답했다면 결과 0건은 관찰된 사실이고, 그 사실은 화면이 말해야
  /// 한다. 아무도 답하지 못했으면 그것은 실패다 — 그때 0건을 돌려주면 앱이
  /// "찾지 못했어요"라고 **거짓을** 말한다.
  public func search(
    query: String, limit: Int, window: WebSearchWindow? = nil
  ) async throws -> [WebSearchResult] {
    var answered = false
    var failure: any Error = WebSearchError.noEngineAnswered
    for engine in engines {
      do {
        let results = Self.inWindow(
          try await engine.search(query: query, limit: limit, window: window),
          window)
        answered = true
        guard results.isEmpty else {
          Self.log.info(
            """
            web.search engine=\(engine.name, privacy: .public) \
            results=\(results.count, privacy: .public)
            """)
          return results
        }
      } catch {
        failure = error
        Self.log.error(
          "web.search engine=\(engine.name, privacy: .public) failed")
      }
    }
    guard answered else { throw failure }
    return []
  }

  /// 공급자의 굵은 필터가 남긴 것을 **정확한 경계로** 자른다.
  ///
  /// 창이 열흘이어도 공급자에게 보낼 수 있는 값은 `"지난 달"`이다. 그 응답에는 창
  /// 밖의 글이 섞여 있고, 그것을 그대로 넘기면 `"최신"`을 물은 차례가 석 주 전
  /// 글을 첫 줄로 받는다 — 그리고 첫 줄이 열린다.
  ///
  /// **날짜를 모르는 줄은 남긴다.** 모르는 것과 창 밖인 것은 다른 사실이고, 모른다는
  /// 이유로 버리면 날짜를 적지 않는 공급자에서 결과가 통째로 사라진다.
  private static func inWindow(
    _ results: [WebSearchResult], _ window: WebSearchWindow?
  ) -> [WebSearchResult] {
    guard let window else { return results }
    return results.filter { result in
      guard let published = result.published else { return true }
      return window.contains(published)
    }
  }
}
