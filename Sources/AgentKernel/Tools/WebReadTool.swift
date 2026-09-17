import Foundation

/// `web.read`의 손. **주소 하나를 글로 바꿔 놓는 것이 전부다.**
///
/// 이 자리가 코어에 있는 이유는 앞뒤가 모두 코어이기 때문이다:
/// `WebSearchTool` → **`WebReadTool`** → `HTMLMarkdown` → `SummarizeTool` →
/// `Evidence`. 가운데 하나만 호스트에 두면 재사용 가능한 파이프라인이 앱마다
/// 다시 구현된다.
///
/// `web.fetch`는 이 손이 아니다. 그쪽은 받은 것을 **정본 기록으로 남기는** 능력이라
/// 호스트의 저장소가 필요하다 — 여기서 하는 일은 지나가는 읽기이고, 남는 것은 이
/// 차례의 수령증뿐이다.
///
/// ## 무엇을 돌려주는가
/// 줄 하나. `body`에 문서의 글이 들어가고(`ResolvableArgument.sourceText`가 이 자리를
/// 찾는다) `identifier`에는 **리다이렉트를 따라간 최종 주소**가 들어간다.
///
/// 글을 PCC에 보내지 않는다. 이 본문은 기기 모델이 사실 몇 줄로 줄이는 재료이고
/// (`EvidenceCompiler`), 줄이지 못하면 잘린다 — 원문이 문맥에 실리는 경로는 없다.
public struct WebReadTool: CapabilityHandler {
  private static let log = AgentHost.logger("web-read")

  /// 수령증에 담을 글자 상한.
  ///
  /// 이 값의 근거는 두 소비자다. 기기 모델은 앞 4,000자만 본다
  /// (`EvidenceCompiler`의 `forModelContext(limit:)`), 결정적 추출은 **문서 전체**를
  /// 훑어 질문과 겹치는 문장을 고른다. 그래서 4,000자로 자르면 뒤쪽에 답이 있는
  /// 문서가 망가지고, 무한정 담으면 차례 기록(`TurnRunRecord`)이 그만큼 커진다.
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

  private let fetch: ContentFetchTransport
  private let policy: ContentFetchHostPolicy

  /// 제품이 쓰는 자리. **문은 코어가 만든다.**
  ///
  /// 호스트가 문을 주입하지 못하게 나눠 둔 이유는 리다이렉트다. 주입된 문은 홉을
  /// 자기가 따라가고, 따라간 홉은 우리 표를 지나지 않는다 — 그러면 첫 주소만
  /// 심사하는 이 툴은 `public.example → 302 → 192.168.0.1`을 막지 못한다.
  public init(_ configuration: WebReadConfiguration = .standard) {
    self.policy = configuration.policy
    self.fetch = ContentFetch.standard(configuration)
  }

  /// 시험이 대역을 세우는 자리. 같은 패키지 안에서만 보인다.
  package init(
    fetch: @escaping ContentFetchTransport,
    policy: ContentFetchHostPolicy = ContentFetchHostPolicy()
  ) {
    self.fetch = fetch
    self.policy = policy
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

      return ActionReceipt(
        requestID: request.id, capability: .webRead, summary: "web.read.result",
        details: CapabilitySourceRow.detail([
          CapabilitySourceRow(
            title: Self.title(of: body, url: document.url),
            // 부제에 주소를 넣지 않는다. 주소는 식별자 자리에 있고, 부제는
            // 근거 한 줄로 문맥에 올라간다 — 같은 값을 두 자리에 담을 이유가 없다.
            body: body, identifier: document.url.absoluteString)
        ]),
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
  static func text(in document: FetchedDocument) throws -> (text: String, decoded: Int) {
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
    return (trimmed, raw.count)
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
  static func title(of markdown: String, url: URL) -> String {
    let heading = markdown.split(separator: "\n").first {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    let cleaned =
      heading?
      .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !cleaned.isEmpty else { return url.host ?? url.absoluteString }
    return cleaned.count > 120 ? String(cleaned.prefix(120)) : cleaned
  }
}
