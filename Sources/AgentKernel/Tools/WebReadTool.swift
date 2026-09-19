import Foundation

/// `web.read`의 손. **주소 하나를 글로 바꿔 놓는 것이 전부다.**
///
/// 이 자리가 코어에 있는 이유는 앞뒤가 모두 코어이기 때문이다:
/// `WebSearchTool` → **`WebReadTool`** → `HTMLMarkdown` → `SummarizeTool` →
/// `Evidence`. 가운데 하나만 호스트에 두면 재사용 가능한 파이프라인이 앱마다
/// 다시 구현된다.
///
/// 호스트가 `memoryIndex`를 주면, 읽은 본문을 그 색인에 **정본으로도** 남긴다
/// (`SemanticMemoryIndex.save`) — 청크 정본 원칙(REMAINING_WORK.ko.md)에 예외를
/// 두지 않는다. `web.fetch` capability는 이 정본화가 없던 시절에 따로 계획했던
/// 자리이고 실제로는 구현되지 않았다 — 이 손이 그 역할을 흡수한다.
///
/// ## 무엇을 돌려주는가
/// 줄 하나. `body`에 문서의 글이 들어가고(`ResolvableArgument.sourceText`가 이 자리를
/// 찾는다) `identifier`에는 **리다이렉트를 따라간 최종 주소**가 들어간다. 저장에
/// 성공하면 `memoryItemDetailKey` 자리에 정본 식별자가 들어간다 — 후속 질문이
/// `memory.search`/`memory.read`로 같은 문서를 다시 찾는 손잡이다.
///
/// 글을 PCC에 보내지 않는다. 이 본문은 기기 모델이 사실 몇 줄로 줄이는 재료이고
/// (`EvidenceCompiler`), 줄이지 못하면 잘린다 — 원문이 문맥에 실리는 경로는 없다.
public struct WebReadTool: CapabilityHandler {
  private static let log = AgentHost.logger("web-read")

  /// 수령증에 담을 글자 상한.
  ///
  /// 이 값의 근거는 두 소비자다. 근거 조립(`EvidenceCompiler`)은 이 본문을
  /// 조각으로 쪼개(`TextChunker.Slice`) 질문과 겹치는 조각부터 고르고, 결정적
  /// 추출은 **문서 전체**를 훑어 질문과 겹치는 문장을 고른다. 그래서 앞에서
  /// 잘라 담으면 뒤쪽에 답이 있는 문서가 망가지고, 무한정 담으면 차례
  /// 기록(`TurnRunRecord`)이 그만큼 커진다.
  ///
  /// 40,000자는 본문만 남긴 기사 대부분을 통째로 담는다. 넘치면 자르고, 자른
  /// 사실은 범위에 적는다(`CoverageRecord.truncated`) — 조용히 자르면 차례가
  /// 문서를 다 읽은 것처럼 말한다.
  ///
  /// ## 이 상한에 걸린 페이지는 긴 기사가 아니었다 (실측 2026-09-17)
  ///
  /// 실기 P01이 읽은 `finance.yahoo.com`의 기사 한 장:
  ///
  /// ```
  /// bytes=767,771  markdown=57,001  → 상한에 걸려 차례가 partial
  /// 줄 683개 중 200자를 넘는 줄 17개, 그 합이 7,207자
  /// 앞 4,000자: "Oops, something went wrong / Skip to main content / # Yahoo Finance …"
  /// ```
  ///
  /// 산문은 7천 자였고 5만 자가 메뉴·티커·추천글이었다. 그리고 기기 모델이 받는
  /// 앞 4,000자에는 기사가 **한 줄도** 없었다. 그래서 고칠 것은 이 숫자가 아니다.
  ///
  /// `main`·`article`을 골라 앞에서 걷어내는 판을 만들어 봤고 **되돌렸다**: 같은
  /// 실기에서 POSTECH 기사(14,989자)가 건너뛰기 링크 묶음 1,966자로 줄었고 다른
  /// 페이지는 고른 조각이 비어 읽기가 실패했다. 길이나 문단 길이로는 "기사를 고른
  /// 것"과 "기사를 잃은 것"이 갈리지 않는다 — 블록별 링크 밀도 같은 품질 신호가
  /// 필요하고, 그것을 재려면 지금 없는 신뢰할 수 있는 측정 도구가 먼저다.
  public static let characterLimit = 40_000

  /// 대표 그림이 놓이는 수령증 자리. 화면이 링크 한 줄을 카드로 세울 때 읽는다.
  public static let heroDetailKey = "heroImage"

  /// 정본 저장 식별자가 놓이는 수령증 자리. 저장에 성공했을 때만 채워진다.
  /// `memory.read(id:)`로 같은 본문을 다시 찾는 손잡이다 — 후속 질문·인용·보관함이
  /// 이 값을 쓴다.
  public static let memoryItemDetailKey = "memoryItem"

  private let fetch: ContentFetchTransport
  private let policy: ContentFetchHostPolicy
  /// 읽은 본문을 정본으로 남길 색인. 없으면(`nil`) 저장을 건너뛴다 — 이 읽기
  /// 자체는 색인 없이도 이번 차례의 수령증으로 동작한다.
  private let memoryIndex: (any SemanticMemoryIndex)?

  /// 제품이 쓰는 자리. **문은 코어가 만든다.**
  ///
  /// 호스트가 문을 주입하지 못하게 나눠 둔 이유는 리다이렉트다. 주입된 문은 홉을
  /// 자기가 따라가고, 따라간 홉은 우리 표를 지나지 않는다 — 그러면 첫 주소만
  /// 심사하는 이 툴은 `public.example → 302 → 192.168.0.1`을 막지 못한다.
  public init(
    _ configuration: WebReadConfiguration = .standard,
    memoryIndex: (any SemanticMemoryIndex)? = nil
  ) {
    self.policy = configuration.policy
    self.fetch = ContentFetch.standard(configuration)
    self.memoryIndex = memoryIndex
  }

  /// 시험이 대역을 세우는 자리. 같은 패키지 안에서만 보인다.
  package init(
    fetch: @escaping ContentFetchTransport,
    policy: ContentFetchHostPolicy = ContentFetchHostPolicy(),
    memoryIndex: (any SemanticMemoryIndex)? = nil
  ) {
    self.fetch = fetch
    self.policy = policy
    self.memoryIndex = memoryIndex
  }

  public var capabilities: Set<CapabilityID> { [.webRead] }

  public func perform(_ request: ActionRequest) async throws -> ActionReceipt {
    guard let raw = request.arguments["url"]?.textValue?
      .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
      let url = URL(string: raw)
    else { throw ActionError.invalidArguments(reason: "url") }

    do {
      // **문보다 앞에서 심사한다.** 심사를 기본 문 안에만 두면(`ContentFetch.standard`)
      // 자기 문을 주입한 호스트에게는 이 능력이 그냥 HTTP 클라이언트가 된다 —
      // 그리고 그 주소는 인터넷이 골라 준 주소다.
      let document = try await fetch(policy.vet(url))
      let extracted = try Self.text(in: document)
      let truncated = extracted.text.count > Self.characterLimit
      let body =
        truncated ? String(extracted.text.prefix(Self.characterLimit)) : extracted.text
      let title = Self.title(of: body, url: document.url)
      // **어느 단계에서 커졌는지 적는다.** 한 줄에 네 숫자다: 받은 바이트, 해독한
      // 글자, 마크다운 글자, 수령증에 담은 글자. 페이지가 상한에 걸렸을 때
      // "기사가 길다"와 "메뉴·추천글이 대부분이다"를 이 줄로 가른다.
      Self.log.info(
        """
        web.read host=\(document.url.host ?? "", privacy: .public) \
        bytes=\(document.bytes.count, privacy: .public) \
        decoded=\(extracted.decoded, privacy: .public) \
        markdown=\(extracted.text.count, privacy: .public) \
        receipt=\(body.count, privacy: .public) \
        truncated=\(truncated, privacy: .public)
        """)

      // **청크 정본, 예외 없음.** 첨부가 `memory.save`로 정본이 되는 문과 같은 문을
      // 지난다(`App/ChatStore.swift`) — receipt의 `body`는 이번 차례의 임시 근거일
      // 뿐이고, 후속 질문·요약·번역·인용은 이 색인이 정본이다. 저장 실패는 이번
      // 읽기 자체를 실패시키지 않는다 — 이미 받은 본문은 이번 차례의 근거로 쓴다.
      var memoryItemID: String?
      if let memoryIndex {
        do {
          memoryItemID = try await memoryIndex.save(
            text: body, title: title, accountID: request.accountID,
            conversationID: request.conversationID)
        } catch {
          Self.log.error(
            "web.read memory.save 실패 host=\(document.url.host ?? "", privacy: .public) \(String(describing: error), privacy: .public)"
          )
        }
      }

      return ActionReceipt(
        requestID: request.id, capability: .webRead, summary: "web.read.result",
        details: CapabilitySourceRow.detail([
          CapabilitySourceRow(
            title: title,
            // 부제에 주소를 넣지 않는다. 주소는 식별자 자리에 있고, 부제는
            // 근거 한 줄로 문맥에 올라간다 — 같은 값을 두 자리에 담을 이유가 없다.
            body: body, identifier: document.url.absoluteString)
        ])
          // **대표 그림.** 페이지가 자기 얼굴로 내놓은 주소다(`og:image`). 이 값은
          // 근거가 아니라 화면의 것이므로 문맥에 싣지 않는다 — 앱이 한 줄의 링크를
          // 카드로 세울 때 쓴다(사용자 지시 2026-09-18: "웹사이트 파싱시에는 대표
          // hero 이미지를 보여주는").
          .merging(
            extracted.hero.map { [Self.heroDetailKey: ActionValue.text($0.absoluteString)] }
              ?? [:],
            uniquingKeysWith: { current, _ in current })
          .merging(
            memoryItemID.map { [Self.memoryItemDetailKey: ActionValue.text($0)] } ?? [:],
            uniquingKeysWith: { current, _ in current }),
        coverage: [
          CoverageRecord(
            binding: .publicWeb, capability: .webRead,
            queryFingerprint: ActionFingerprint.arguments(request.arguments),
            state: truncated ? .partial : .complete,
            discoveredCount: 1, readCount: 1, paginationExhausted: true,
            truncated: truncated, reason: truncated ? .truncation : nil)
        ])
    } catch let error as ContentFetchError {
      // **왜 못 읽었는지**가 화면에 남는다. 사설 주소를 막은 것과 서버가 500을 준
      // 것은 사용자가 할 수 있는 일이 다르다.
      throw ActionError.failed(reason: error.reason)
    }
  }

  /// 바이트를 글로. **글이 아닌 것은 글로 읽지 않는다.**
  ///
  /// 해독한 글자 수를 함께 돌려주는 이유는 계측이다. 받은 바이트·해독한 글자·
  /// 마크다운 글자·수령증에 담은 글자가 각각 다른 값이고, 어느 단계에서 커졌는지
  /// 모르면 상한을 어디에 둘지 말할 수 없다(실기 2026-09-17 P01: 한 페이지가
  /// 40,000자 상한에 걸려 차례가 `partial`로 닫혔다).
  static func text(in document: FetchedDocument) throws -> (
    text: String, decoded: Int, hero: URL?
  ) {
    let type = document.mimeType
    let isHTML =
      type.contains("html") || type.contains("xml") || type.isEmpty
    let isPlain = type.hasPrefix("text/") || type.contains("json")
    guard isHTML || isPlain else { throw ContentFetchError.unsupportedType(type) }

    guard let raw = Self.decode(document.bytes, as: document.encoding) else {
      throw ContentFetchError.undecodableText
    }
    // 구조가 하나도 없으면 `HTMLMarkdown`이 그 글을 그대로 돌려준다 — 플레인텍스트
    // 경로를 따로 두지 않아도 되는 이유가 그 계약이다.
    let text = isHTML ? HTMLMarkdown.markdown(fromHTML: raw) : raw
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ContentFetchError.emptyDocument }
    let hero = isHTML ? Self.hero(in: raw, relativeTo: document.url) : nil
    return (trimmed, raw.count, hero)
  }

  /// 페이지가 **자기 얼굴로 내놓은 그림**. `og:image` → `twitter:image` → 첫 `img`.
  ///
  /// 왜 이 순서인가: 앞의 둘은 페이지가 스스로 고른 대표 그림이고, 마지막은
  /// 추측이다. 추측까지 두는 이유는 대표 그림을 적지 않은 페이지가 많기 때문이고,
  /// 데이터 URL과 상대 주소는 여기서 걸러진다(`data:`는 그림이 아니라 바이트열이고,
  /// 상대 주소는 문서 주소로 풀어야 열린다).
  static func hero(in html: String, relativeTo url: URL) -> URL? {
    var openGraph: String?
    var twitter: String?
    var first: String?
    HTMLMarkdown.Tokenizer.walk(html) { token in
      guard case .open(let name, let attributes) = token else { return }
      switch name {
      case "meta":
        let key = (attributes["property"] ?? attributes["name"])?.lowercased()
        guard let content = attributes["content"], !content.isEmpty else { return }
        if key == "og:image" || key == "og:image:url" {
          openGraph = openGraph ?? content
        } else if key == "twitter:image" || key == "twitter:image:src" {
          twitter = twitter ?? content
        }
      case "img":
        // `data:`는 그림이 아니라 바이트열이다(추적 픽셀·플레이스홀더). 여기서
        // 거르지 않으면 **첫 그림이 늘 그것**이 된다.
        guard first == nil, let source = attributes["src"], !source.isEmpty,
          !source.lowercased().hasPrefix("data:")
        else { return }
        first = source
      default:
        return
      }
    }
    for candidate in [openGraph, twitter, first].compactMap({ $0 }) {
      guard !candidate.lowercased().hasPrefix("data:") else { continue }
      guard let resolved = URL(string: candidate, relativeTo: url)?.absoluteURL,
        let scheme = resolved.scheme?.lowercased(),
        scheme == "http" || scheme == "https"
      else { continue }
      return resolved
    }
    return nil
  }

  /// 헤더가 시킨 인코딩으로 먼저 읽고, 실패하면 UTF-8·Latin-1로 내려간다.
  ///
  /// Latin-1이 마지막인 이유: 어떤 바이트열이든 글자로 읽힌다. 거기서 멈추면
  /// `undecodableText`가 사실상 일어나지 않으므로, 그 앞 두 단계가 진짜 판정이다.
  static func decode(_ bytes: Data, as encoding: String.Encoding) -> String? {
    if let text = String(data: bytes, encoding: encoding) { return text }
    if let text = String(data: bytes, encoding: .utf8) { return text }
    return String(data: bytes, encoding: .isoLatin1)
  }

  /// 제목은 **문서에서** 온다. 없으면 호스트 이름이다 — 제목을 지어내지 않는다.
  ///
  /// 첫 줄을 그대로 믿지 않는다. 페이지의 첫 줄은 흔히 글이 아니다: 추적 픽셀,
  /// 로고, 건너뛰기 링크. 실기 2026-09-18(iPhone 15 Pro)에서 읽은 한 장의 제목이
  /// `"![](https://www.facebook.com/tr?id=…)"`이 됐고, 그 값이 근거의 이름으로
  /// 문맥에 올라가 답 단계는 **읽은 페이지를 무관하다고 판정했다** — 각주는 `[1] !`
  /// 였다.
  ///
  /// 그래서 **머리글이 먼저다**(`# …`). 페이지가 자기 글에 붙인 이름이고, 그것이
  /// 없을 때에만 말이 남는 첫 줄로 내려간다.
  static func title(of markdown: String, url: URL) -> String {
    var fallback = ""
    for line in markdown.split(separator: "\n") {
      let isHeading = line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
      let cleaned = Self.prose(in: line)
      guard cleaned.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
      if isHeading { return Self.clipped(cleaned) }
      if fallback.isEmpty { fallback = cleaned }
    }
    guard !fallback.isEmpty else { return url.host ?? url.absoluteString }
    return Self.clipped(fallback)
  }

  private static func clipped(_ title: String) -> String {
    title.count > 120 ? String(title.prefix(120)) : title
  }

  /// 마크다운 표시를 걷어낸 **말**. 그림은 버리고, 링크는 이름만 남긴다.
  ///
  /// 그림을 alt로 대신하지 않는 이유: 걷어내는 목적이 "이 줄에 사람이 읽을 말이
  /// 있는가"를 묻는 것이고, `alt="로고"`는 페이지의 말이 아니다.
  static func prose(in line: some StringProtocol) -> String {
    var out = ""
    out.reserveCapacity(line.count)
    var rest = Substring(line)
    while let open = rest.firstIndex(of: "[") {
      let isImage = open > rest.startIndex && rest[rest.index(before: open)] == "!"
      let head = rest[rest.startIndex..<open]
      out += isImage ? head.dropLast() : head
      guard let close = rest[open...].firstIndex(of: "]") else {
        out += rest[open...]
        rest = rest[rest.endIndex...]
        break
      }
      // 링크의 이름은 말이다(`[이더리움 스테이킹](…)`). 그림의 이름은 아니다.
      if !isImage { out += rest[rest.index(after: open)..<close] }
      rest = rest[rest.index(after: close)...]
      // 뒤따르는 `(주소)`는 표시다 — 있으면 함께 버린다.
      if rest.first == "(", let end = rest.firstIndex(of: ")") {
        rest = rest[rest.index(after: end)...]
      }
    }
    out += rest
    return out
      .trimmingCharacters(in: CharacterSet(charactersIn: "#*_>-| \t"))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
