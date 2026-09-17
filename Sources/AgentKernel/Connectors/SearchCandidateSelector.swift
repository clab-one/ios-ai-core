import Foundation

/// 검색이 돌려준 줄 **중 어느 것을 읽을지 기기에서 고른다.**
///
/// 고르는 일을 PCC에게 묻지 않는 이유는 두 가지다. 후보 다섯 줄을 문맥에 실으면
/// 계획 호출이 그만큼 커지고(제목·스니펫·주소 다섯 벌), 그 선택은 **사적인 맥락이
/// 가장 잘 아는 일**이다 — 내 기록에 `Private Cloud Compute` 메모가 있다는 사실은
/// 공개 웹에 보내지 않고도 후보를 고르는 데 쓸 수 있다.
///
/// ## 왜 필요한가 (실기 2026-09-17, iPad, 실제 PCC)
///
/// `"내 기록에 있는 PCC 메모와 최신 웹 내용을 비교해줘"`가 공급자 1위를 읽었고,
/// 그 1위는 `Pointe Coupée Parish Government`의 연락처 페이지였다. `PCC`는 애플의
/// 낱말이 아니고, 검색 공급자는 우리 사용자의 맥락을 모른다. 그런데 **우리는 안다** —
/// 그 차례가 방금 읽은 사적 기록에 `Private Cloud Compute`가 적혀 있었다.
///
/// ## 경계
///
/// 사적 맥락은 **점수 계산에만** 쓰인다. 공개 웹으로 나가는 것은 질의뿐이고
/// (`web.search`), 이 자리는 이미 받아 온 줄들을 기기에서 다시 세우는 일이다.
public enum SearchCandidateSelector {
  /// 점수가 붙은 후보 하나.
  public struct Candidate: Sendable, Equatable {
    public let row: CapabilitySourceRow
    public let score: Int
    /// 그중 **사적 맥락에서 온 점수.**
    ///
    /// 이 값을 따로 드는 이유는 약어다. `"PCC"`는 애플의 낱말이 아니고
    /// (`PCC Community Markets`·`Pointe Coupée Parish`), 질의에 그 세 글자가 있으면
    /// 어느 후보나 점수를 받는다. 내 기록의 낱말(`Private Cloud Compute`)이 하나도
    /// 맞지 않았다면 그 후보는 **질의의 약어만 맞은 것**이고, 그때 1위라는 사실은
    /// 아무것도 말하지 않는다(실기 2026-09-17 P02: 후보 다섯 줄에 애플 페이지가
    /// 하나도 없었다).
    public let contextScore: Int

    public var url: String { row.identifier }
  }

  /// 제목이 맞은 것은 부제가 맞은 것보다 강한 신호다. 스니펫은 공급자가 질의에
  /// 맞춰 잘라 낸 글이라 어느 후보에서나 질의 낱말이 보인다.
  static let titleWeight = 3
  static let snippetWeight = 1
  /// 낱말이 **그대로** 맞은 것과 안에 들어 있는 것. 한국어는 조사가 붙어
  /// (`애플이`·`메모와`) 정확히 맞는 일이 드물다 — 포함도 신호로 세되 더 약하게 센다.
  static let exactBonus = 2

  /// 기기에서 읽을 수 없는 문서는 후보가 아니다. `web.read`가 글이 아닌 것을
  /// 거절하므로(`ContentFetchError.unsupportedType`) 이 줄을 고르면 그 차례는
  /// 읽기 실패로 끝난다 — 벌점이 아니라 **제외**다.
  static let unreadableExtensions = [
    ".pdf", ".zip", ".dmg", ".pkg", ".mp4", ".mov", ".mp3", ".png", ".jpg", ".jpeg",
    ".gif", ".svg", ".xls", ".xlsx", ".doc", ".docx", ".ppt", ".pptx",
  ]

  /// 후보를 점수 순으로. **같은 점수는 공급자 순서를 지킨다** — 공급자의 순위도
  /// 정보이고, 우리가 아는 것이 없을 때 그 정보를 버릴 이유가 없다.
  ///
  /// - Parameters:
  ///   - rows: `web.search`가 돌려준 줄. `identifier`가 주소다.
  ///   - query: 사용자가 말한 문장. 계획이 만든 질의보다 이 값이 넓다.
  ///   - context: 이 차례가 기기에서 이미 읽은 **사적 맥락**(내 기록의 제목·본문).
  ///     공개 웹으로 나가지 않는다.
  public static func rank(
    _ rows: [CapabilitySourceRow], query: String, context: [String] = []
  ) -> [Candidate] {
    let asked = terms(query)
    let known = Set(context.flatMap { terms($0) }).subtracting(asked)
    var bestByHost: [String: Candidate] = [:]
    var order: [String] = []

    for row in rows {
      guard let url = URL(string: row.identifier), let host = url.host?.lowercased(),
        !isUnreadable(url)
      else { continue }
      let fromContext = score(row, terms: known)
      let candidate = Candidate(
        row: row, score: score(row, terms: asked) + fromContext, contextScore: fromContext)
      // 한 사이트가 다섯 줄을 차지하면 다른 후보를 볼 기회가 없어진다. 그 사이트의
      // **가장 잘 맞는 줄** 하나만 남긴다.
      if let existing = bestByHost[host] {
        if candidate.score > existing.score { bestByHost[host] = candidate }
      } else {
        bestByHost[host] = candidate
        order.append(host)
      }
    }

    let candidates = order.compactMap { bestByHost[$0] }
    // `sorted(by:)`는 안정 정렬이 아니다. 자리를 함께 들고 정렬해 공급자 순서를 지킨다.
    return candidates.enumerated()
      .sorted { left, right in
        left.element.score == right.element.score
          ? left.offset < right.offset : left.element.score > right.element.score
      }
      .map(\.element)
  }

  /// 결정적 점수로 **고르지 못했는가.**
  ///
  /// 둘이다:
  ///
  /// 1. 아무 낱말도 맞지 않았다(0점). 우리가 판단한 것이 없다.
  /// 2. 사적 맥락이 있었는데 1위가 그 맥락에서 점수를 하나도 받지 못했다. 그 1위는
  ///    **질의의 약어만 맞은 줄**이다 — `"PCC"`로 찾은 식료품 협동조합의 특가
  ///    페이지가 그것이다(실기 2026-09-17 P02).
  ///
  /// **동점은 여기 없다.** 넣었다가 뺐다: 1위가 양수 점수를 들고 있으면 우리가
  /// 판단한 것이 있고, 동점의 순서는 공급자 순위가 정한다(이 랭커는 그 순서를
  /// 안정적으로 보존한다). 동점에 모델을 부르던 동안 결정적 랭킹이 고른 설명글
  /// 대신 모델이 보도자료를 골랐고 그 차례는 `partial`로 닫혔다(실기 2026-09-17
  /// P01 run B). 그리고 `localSelections`가 "결정적 점수로 안전하게 읽을 수 없었다"를
  /// 뜻하게 된다 — 단순 동점이 섞여 있으면 그 뜻이 흐려진다.
  ///
  /// - Parameter informed: 사적 맥락을 넘겨 점수를 냈는가.
  public static func isAmbiguous(_ ranked: [Candidate], informed: Bool = false) -> Bool {
    guard let first = ranked.first else { return false }
    if first.score == 0 { return true }
    return informed && first.contextScore == 0
  }

  static func isUnreadable(_ url: URL) -> Bool {
    let path = url.path.lowercased()
    return unreadableExtensions.contains(where: path.hasSuffix)
  }

  static func score(_ row: CapabilitySourceRow, terms wanted: Set<String>) -> Int {
    guard !wanted.isEmpty else { return 0 }
    let title = terms(row.title)
    let snippet = terms(row.subtitle)
    var total = 0
    for term in wanted {
      total += weight(term, in: title) * titleWeight
      total += weight(term, in: snippet) * snippetWeight
    }
    return total
  }

  private static func weight(_ term: String, in candidate: Set<String>) -> Int {
    if candidate.contains(term) { return exactBonus }
    if candidate.contains(where: { overlaps(term, $0) }) { return 1 }
    return 0
  }

  /// 한쪽이 다른 쪽 안에 있는가. 조사와 복합어를 위한 비교다 — `"애플"`은
  /// `"애플이"` 안에 있고 `"compute"`는 `"computing"` 안에 있다.
  ///
  /// 짧은 라틴 낱말은 이 비교에서 뺀다. `co-op`의 `co`가 `compute`에 들어맞고
  /// (시험 실측) 그 한 글자 겹침이 "내 기록과 관련 있다"는 신호로 세어졌다 —
  /// 두 글자 영문은 기능어이고, 그 기능어는 아무 후보에나 있다. 정확히 맞는
  /// 낱말은 길이와 무관하게 위에서 이미 세어진다.
  static func overlaps(_ term: String, _ candidate: String) -> Bool {
    let shorter = term.count <= candidate.count ? term : candidate
    let longer = term.count <= candidate.count ? candidate : term
    guard longer.contains(shorter) else { return false }
    // 한글 두 글자는 낱말이다(`애플`·`검증`). 라틴 두세 글자는 아니다.
    return shorter.allSatisfy(\.isASCII) ? shorter.count >= 4 : shorter.count >= 2
  }

  /// 글을 낱말로. 영문은 소문자로, 한국어는 붙어 오는 조사를 떼지 않는다 —
  /// 떼려면 형태소 분석이 필요하고, 포함 비교가 그 일을 대신한다(`weight`).
  ///
  /// 한 글자 낱말은 버린다. `"의"`·`"a"`는 어느 후보에나 있어 점수를 평평하게 만든다.
  static func terms(_ text: String) -> Set<String> {
    let lowered = text.lowercased()
    let pieces = lowered.split(whereSeparator: { character in
      !character.isLetter && !character.isNumber
    })
    return Set(pieces.filter { $0.count > 1 }.map(String.init))
  }
}
