import Foundation

/// 클립보드의 `public.html`을 마크다운으로 옮긴다 — 붙여넣기 상호운용의 정본 경로.
///
/// ## 왜 HTML인가 (실측 2026-08-16, IOSPROD-200 §8)
///
/// 노션 iOS의 클립보드를 실기에서 회수해 열었다. 플레인텍스트는 표 구조를 버리고
/// 이미지를 `!파일명` 글자로 눕힌다. RTFD에는 이미지 항목이 없고, 내부
/// JSON(UTF-16)까지 열어도 URL이 0개다. **구조가 온전히 남는 유일한 표현이
/// `public.html`이다** — 표는 진짜 `<table>`이고, 이미지는
/// `<img src="attachment:UUID:파일명">`으로 자리와 이름이 남는다.
///
/// ## 모양 (Joplin paste-as-markdown의 파이프라인을 따른다)
///
/// `토큰화 → 정규화(스타일·스크립트 무시, 공백 접기) → 방출(GFM 표 포함)`.
/// 파서 의존성을 들이지 않는 이유: 클립보드 HTML은 기계가 만든 규칙적인 문서라
/// 손 토크나이저로 충분하고, 이 저장소는 원격 의존성이 둘뿐이다(GRDB·MarkdownUI).
/// 픽스처(실제 노션 페이로드)가 이 판단의 회귀 감시자다 — 깨지는 입력이 나타나면
/// 그때 SwiftSoup을 논의한다.
///
/// ## 이미지의 정직한 한계
///
/// 노션은 이미지 **바이트를 클립보드에 싣지 않는다**(실측: 서명 URL조차 없다).
/// `attachment:UUID:파일명`은 주소가 아니라 노션 내부 블록을 가리키는 사설 표식이라
/// 우리가 받아올 수단도 없다. 그래서 그 이미지는 **버린다** — 채워지지 않을 자리를
/// 글에 남기면 산문 한복판에 파일명만 뜬다. 받을 수 있는 주소(`https:`)는 그대로
/// 남긴다; 물질화는 캡처 파이프라인의 일이다.
///
/// 노션에서 그림까지 옮기려면 클립보드가 아닌 문이 필요하다: **공유 시트**
/// (`JustSendShare`가 이미지 10장까지 받는다)나 워크스페이스를 연결하는 노션 API다.
public enum HTMLMarkdown {

  /// 변환. 구조가 하나도 없으면(문단 하나짜리 순수 텍스트) 그 텍스트를 돌려준다 —
  /// 호출부는 결과가 비었을 때만 플레인텍스트로 물러선다.
  public static func markdown(fromHTML html: String) -> String {
    var emitter = Emitter()
    Tokenizer.walk(html) { token in emitter.take(token) }
    return emitter.finish()
  }

  // MARK: - 토큰

  enum Token {
    case open(name: String, attributes: [String: String])
    case close(name: String)
    case text(String)
  }

  // MARK: - 토크나이저

  /// 기계 생성 HTML을 위한 관대한 토크나이저. 닫히지 않은 태그·주석·독타입을
  /// 견디고, `<script>`·`<style>` 내용은 통째로 건너뛴다.
  enum Tokenizer {
    static func walk(_ html: String, _ yield: (Token) -> Void) {
      let scalars = Array(html)
      var index = 0
      let count = scalars.count
      /// 원문 내용을 그대로 삼켜야 하는 태그(닫는 태그까지).
      var rawUntil: String?

      var textStart = index
      func flushText(_ end: Int) {
        guard end > textStart else { return }
        let raw = String(scalars[textStart..<end])
        guard !raw.isEmpty else { return }
        yield(.text(decodeEntities(raw)))
      }

      while index < count {
        guard scalars[index] == "<" else {
          index += 1
          continue
        }
        // `<`를 만났다 — 태그, 주석, 독타입, 혹은 그냥 글자.
        if let raw = rawUntil {
          // raw 모드에서는 정확히 그 닫는 태그만 찾는다.
          let closer = "</\(raw)"
          if matches(scalars, at: index, closer), let end = find(scalars, ">", from: index) {
            rawUntil = nil
            textStart = end + 1
            index = end + 1
            continue
          }
          index += 1
          continue
        }
        if matches(scalars, at: index, "<!--") {
          flushText(index)
          let end = findSequence(scalars, "-->", from: index + 4) ?? count
          index = min(end + 3, count)
          textStart = index
          continue
        }
        if index + 1 < count, scalars[index + 1] == "!" || scalars[index + 1] == "?" {
          flushText(index)
          let end = find(scalars, ">", from: index) ?? count
          index = min(end + 1, count)
          textStart = index
          continue
        }
        guard index + 1 < count,
          scalars[index + 1].isLetter || scalars[index + 1] == "/"
        else {
          index += 1
          continue
        }
        guard let end = find(scalars, ">", from: index) else { break }
        flushText(index)
        let inner = String(scalars[(index + 1)..<end])
        parseTag(inner, yield: &rawUntil, emit: yield)
        index = end + 1
        textStart = index
      }
      flushText(min(index, count))
    }

    private static func parseTag(
      _ inner: String, yield rawUntil: inout String?, emit: (Token) -> Void
    ) {
      var body = inner
      let closing = body.hasPrefix("/")
      if closing { body.removeFirst() }
      let selfClosing = body.hasSuffix("/")
      if selfClosing { body.removeLast() }

      let nameEnd = body.firstIndex { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }
      let name = String(body[..<(nameEnd ?? body.endIndex)]).lowercased()
      guard !name.isEmpty else { return }

      if closing {
        emit(.close(name: name))
        return
      }
      var attributes: [String: String] = [:]
      if let nameEnd {
        attributes = parseAttributes(String(body[nameEnd...]))
      }
      emit(.open(name: name, attributes: attributes))
      if voidTags.contains(name) || selfClosing {
        emit(.close(name: name))
      } else if name == "script" || name == "style" {
        rawUntil = name
      }
    }

    private static func parseAttributes(_ text: String) -> [String: String] {
      var attributes: [String: String] = [:]
      var rest = Substring(text)
      while let equal = rest.firstIndex(of: "=") {
        let key = rest[..<equal].trimmingCharacters(in: .whitespacesAndNewlines)
          .split(separator: " ").last.map(String.init)?.lowercased() ?? ""
        var value = rest[rest.index(after: equal)...].drop { $0 == " " }
        if let quote = value.first, quote == "\"" || quote == "'" {
          value = value.dropFirst()
          if let close = value.firstIndex(of: quote) {
            if !key.isEmpty { attributes[key] = decodeEntities(String(value[..<close])) }
            rest = value[value.index(after: close)...]
            continue
          }
        }
        let end = value.firstIndex(of: " ") ?? value.endIndex
        if !key.isEmpty { attributes[key] = decodeEntities(String(value[..<end])) }
        rest = value[end...]
      }
      return attributes
    }

    private static let voidTags: Set<String> = [
      "br", "hr", "img", "meta", "link", "input", "col", "area", "base", "embed",
      "source", "track", "wbr",
    ]

    private static func matches(_ scalars: [Character], at index: Int, _ needle: String) -> Bool {
      let chars = Array(needle)
      guard index + chars.count <= scalars.count else { return false }
      for (offset, ch) in chars.enumerated()
      where Character(ch.lowercased()) != Character(scalars[index + offset].lowercased()) {
        return false
      }
      return true
    }

    private static func find(_ scalars: [Character], _ needle: Character, from: Int) -> Int? {
      var i = from
      while i < scalars.count {
        if scalars[i] == needle { return i }
        i += 1
      }
      return nil
    }

    private static func findSequence(_ scalars: [Character], _ needle: String, from: Int) -> Int? {
      var i = from
      while i < scalars.count {
        if matches(scalars, at: i, needle) { return i }
        i += 1
      }
      return nil
    }
  }

  /// `&amp;` 같은 이름 엔티티와 `&#NN;`·`&#xHH;` 숫자 엔티티를 푼다.
  static func decodeEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }
    var out = ""
    out.reserveCapacity(text.count)
    var rest = Substring(text)
    while let amp = rest.firstIndex(of: "&") {
      out += rest[..<amp]
      let tail = rest[amp...]
      guard let semi = tail.prefix(12).firstIndex(of: ";") else {
        out += "&"
        rest = tail.dropFirst()
        continue
      }
      let entity = tail[tail.index(after: tail.startIndex)..<semi]
      if entity.hasPrefix("#") {
        let number = entity.dropFirst()
        let value =
          number.hasPrefix("x") || number.hasPrefix("X")
          ? UInt32(number.dropFirst(), radix: 16) : UInt32(number)
        if let value, let scalar = Unicode.Scalar(value) {
          out.append(Character(scalar))
          rest = tail[tail.index(after: semi)...]
          continue
        }
      } else if let known = namedEntities[String(entity)] {
        out.append(known)
        rest = tail[tail.index(after: semi)...]
        continue
      }
      out += "&"
      rest = tail.dropFirst()
    }
    out += rest
    return out
  }

  private static let namedEntities: [String: Character] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
    "nbsp": " ", "hellip": "…", "mdash": "—", "ndash": "–",
    "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
    "middot": "·", "bull": "•", "times": "×", "copy": "©",
  ]

  // MARK: - 방출기

  private struct Emitter {
    private var blocks: [String] = []
    private var inline = ""
    /// 목록 중첩: (순서형인가, 다음 번호)
    private var lists: [(ordered: Bool, index: Int)] = []
    private var quoteDepth = 0
    private var headingLevel = 0
    /// 표 수집 상태. `</table>`에서 GFM으로 눕는다.
    private var tableRows: [[String]] = []
    private var currentRow: [String]?
    private var currentCell: String?
    private var headerRowCount = 0
    /// 원문 그대로 담는 중인가. `<pre>`뿐 아니라 **`white-space`가 접지 말라고
    /// 말하는 요소**와 `<code>`가 모두 이 모드로 들어온다.
    private var inPre = false
    /// 원문 모드를 연 태그와 그 안의 같은 이름 중첩 수 — 짝이 맞는 닫기에서만 닫힌다.
    private var preTag = ""
    private var preNesting = 0
    /// 이 `<code>`가 무엇인지 아직 모른다. 줄바꿈이 있으면 블록(펜스), 없으면 인라인.
    private var preIsTentativeCode = false
    private var preBuffer = ""
    private var codeLanguage = ""
    private var listItemOpen = false

    mutating func take(_ token: Token) {
      // **사이트의 가구는 글이 아니다.** 위키백과 한 쪽을 통째로 옮기던 동안
      // 본문 앞에 `둘러보기`·`대문으로 가기` 같은 메뉴가 수백 자 들어왔고, 그
      // 글자가 요약 조각의 첫 장을 차지해 "이 문서의 홈페이지 주소는 /wiki/…"가
      // 요약문 1번 항목으로 섰다(실기 2026-09-19). 건너뛰는 영역은 HTML이
      // 스스로 그렇다고 말한 것들뿐이다 — 사이트 이름으로 거르지 않는다.
      if skipping { return skip(token) }
      switch token {
      case .text(let text):
        if inPre {
          preBuffer += text
        } else if currentCell != nil {
          let piece = collapse(text)
          currentCell? += piece
        } else {
          inline += collapse(text)
        }
      case .open(let name, let attributes):
        if !inPre, Self.isChrome(name, attributes) {
          flushBlock()
          skipTag = name
          skipNesting = 0
          return
        }
        open(name, attributes)
      case .close(let name):
        close(name)
      }
    }

    /// 건너뛰는 중인 영역의 태그와 그 안의 같은 이름 중첩 수. `<pre>`와 같은
    /// 짝 맞추기다 — 닫히지 않은 태그가 흔하므로 이름으로만 닫는다.
    private var skipTag = ""
    private var skipNesting = 0
    private var skipping: Bool { !skipTag.isEmpty }

    private mutating func skip(_ token: Token) {
      switch token {
      case .open(let name, _) where name == skipTag:
        skipNesting += 1
      case .close(let name) where name == skipTag:
        if skipNesting > 0 { skipNesting -= 1 } else { skipTag = "" }
      default:
        break
      }
    }

    /// 이 요소가 **문서의 가구**인가.
    ///
    /// 이름(`nav`·`footer`)과 역할(`role="navigation"`)만 본다. 둘 다 저자가
    /// "여기는 본문이 아니다"라고 표시한 자리다. `header`는 뺀다 — 문서 제목이
    /// 거기 있는 판이 있고(위키백과 `mw-body-header`), 제목까지 버리면 읽은 글이
    /// 이름을 잃는다.
    static func isChrome(_ name: String, _ attributes: [String: String]) -> Bool {
      if chromeTags.contains(name) { return true }
      if let role = attributes["role"]?.lowercased(), chromeRoles.contains(role) { return true }
      return attributes["aria-hidden"]?.lowercased() == "true"
    }

    private static let chromeTags: Set<String> = [
      "nav", "aside", "footer", "form", "dialog", "template", "noscript", "button", "select",
    ]
    private static let chromeRoles: Set<String> = [
      "navigation", "banner", "contentinfo", "search", "complementary", "dialog", "menu",
      "menubar", "toolbar",
    ]

    private mutating func open(_ name: String, _ attributes: [String: String]) {
      if inPre { return openInsidePre(name, attributes) }
      // `<pre>`는 물론이고, 스타일이 접지 말라고 하면 그것도 원문이다.
      let styledPre =
        Self.preformattable.contains(name) && Self.isPreformattedStyle(attributes["style"])
      if name == "pre" || styledPre {
        return beginPre(tag: name, attributes: attributes, tentative: false)
      }
      // `<code>`는 내용을 먼저 모으고 닫을 때 판정한다 — 줄바꿈을 품은 `<code>`는
      // 인라인 코드가 아니라 코드블록이고, 접어 버리면 코드가 한 줄로 뭉개진다.
      if name == "code" { return beginPre(tag: name, attributes: attributes, tentative: true) }
      switch name {
      case "h1", "h2", "h3", "h4", "h5", "h6":
        flushBlock()
        headingLevel = Int(String(name.dropFirst())) ?? 3
      case "p", "div", "section", "article", "figure":
        // 문단 경계. 셀·목록 항목 안에서는 경계를 만들지 않는다 — 거기서 문단은 이어 쓴다.
        if currentCell == nil && !listItemOpen { flushBlock() }
      case "br":
        if currentCell != nil {
          currentCell? += " "
        } else {
          inline += "\n"
        }
      case "hr":
        flushBlock()
        blocks.append("---")
      case "ul":
        flushBlock()
        lists.append((ordered: false, index: 1))
      case "ol":
        flushBlock()
        lists.append((ordered: true, index: 1))
      case "li":
        flushBlock()
        listItemOpen = true
      case "blockquote":
        flushBlock()
        quoteDepth += 1
      case "strong", "b":
        appendInline("**")
      case "em", "i":
        appendInline("*")
      case "s", "del", "strike":
        appendInline("~~")
      case "a":
        appendInline("[")
      case "img":
        appendInline(imageMarkdown(attributes))
      case "table":
        flushBlock()
        tableRows = []
        headerRowCount = 0
      case "thead":
        break
      case "tr":
        currentRow = []
      case "th", "td":
        currentCell = ""
      default:
        break
      }
      lastAnchorHref = name == "a" ? (attributes["href"] ?? "") : lastAnchorHref
    }

    private var lastAnchorHref = ""

    private mutating func close(_ name: String) {
      if inPre {
        guard name == preTag else { return }
        if preNesting > 0 { preNesting -= 1 } else { endPre() }
        return
      }
      switch name {
      case "h1", "h2", "h3", "h4", "h5", "h6":
        flushBlock()
        headingLevel = 0
      case "p", "div", "section", "article", "figure":
        if currentCell == nil && !listItemOpen { flushBlock() }
      case "ul", "ol":
        flushBlock()
        if !lists.isEmpty { lists.removeLast() }
      case "li":
        flushBlock()
        listItemOpen = false
      case "blockquote":
        flushBlock()
        quoteDepth = max(0, quoteDepth - 1)
      case "strong", "b":
        appendInline("**")
      case "em", "i":
        appendInline("*")
      case "s", "del", "strike":
        appendInline("~~")
      case "a":
        let href = lastAnchorHref
        appendInline(href.isEmpty || href.hasPrefix("attachment:") ? "]" : "](\(href))")
        lastAnchorHref = ""
      case "th", "td":
        if let cell = currentCell {
          currentRow?.append(cell.trimmingCharacters(in: .whitespacesAndNewlines))
          currentCell = nil
        }
      case "tr":
        if let row = currentRow {
          tableRows.append(row)
          currentRow = nil
        }
      case "thead":
        headerRowCount = tableRows.count
      case "table":
        emitTable()
      default:
        break
      }
    }

    // MARK: 원문 모드 (`<pre>` · `white-space: pre*` · 줄바꿈을 품은 `<code>`)
    //
    // **접을지 말지는 CSS가 말한다.** 노션·문서 편집기의 클립보드 HTML은 블록마다
    // 인라인 스타일을 통째로 실어 보내고(실측 픽스처: 모든 블록에
    // `white-space: normal`), 코드블록만 그 값이 `pre`·`pre-wrap`이다. 태그 이름만
    // 보던 동안 그런 코드블록은 한 줄짜리 산문으로 뭉개졌다.

    /// 스타일이 붙으면 원문으로 인정하는 태그. `span`은 일부러 뺐다 — WebKit이
    /// 공백 런에 `white-space: pre` 스팬을 두르므로, 넣으면 문장 한복판이 코드가 된다.
    private static let preformattable: Set<String> = ["div", "p", "code", "figure", "section"]

    private static func isPreformattedStyle(_ style: String?) -> Bool {
      guard let style, let key = style.range(of: "white-space") else { return false }
      let value = style[key.upperBound...]
        .drop { $0 == " " || $0 == ":" }
        .prefix { $0 != ";" }
        .split(separator: " ").first.map(String.init)?.lowercased() ?? ""
      return value == "pre" || value == "pre-wrap" || value == "pre-line"
        || value == "break-spaces"
    }

    private mutating func beginPre(
      tag: String, attributes: [String: String], tentative: Bool
    ) {
      // 미정인 `<code>`는 아직 문단을 끊지 않는다 — 인라인으로 판명되면 그 문단에
      // 도로 들어가야 한다.
      if !tentative { flushBlock() }
      inPre = true
      preTag = tag
      preNesting = 0
      preIsTentativeCode = tentative
      preBuffer = ""
      codeLanguage = Self.language(from: attributes)
    }

    /// 원문 모드 안에서 열린 태그. 줄을 나누는 것들만 의미가 있다.
    private mutating func openInsidePre(_ name: String, _ attributes: [String: String]) {
      if name == preTag { preNesting += 1 }
      switch name {
      case "br":
        preBuffer += "\n"
      case "p", "div", "li", "tr":
        // 줄마다 블록을 두르는 직렬화(WebKit)가 있다. 줄이 붙어 버리면 코드가 아니다.
        if !preBuffer.isEmpty, !preBuffer.hasSuffix("\n") { preBuffer += "\n" }
      case "code":
        if codeLanguage.isEmpty { codeLanguage = Self.language(from: attributes) }
      default:
        break
      }
    }

    /// `class="language-swift"`·`class="code-swift"`에서 언어를 집는다.
    private static func language(from attributes: [String: String]) -> String {
      guard let cls = attributes["class"] else { return "" }
      for prefix in ["language-", "lang-", "code-"] {
        guard let range = cls.range(of: prefix) else { continue }
        let token = cls[range.upperBound...].prefix { !$0.isWhitespace }
        if !token.isEmpty { return String(token) }
      }
      return ""
    }

    private mutating func endPre() {
      let tentative = preIsTentativeCode
      let body = preBuffer.trimmingCharacters(in: .newlines)
      let language = codeLanguage
      inPre = false
      preTag = ""
      preNesting = 0
      preIsTentativeCode = false
      preBuffer = ""
      codeLanguage = ""

      // 줄바꿈 없는 `<code>`는 인라인 코드다 — 문단 흐름으로 되돌려 넣는다.
      if tentative, !body.contains(where: \.isNewline) {
        let text = collapse(body).trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { appendInline("`" + text + "`") }
        return
      }
      // **빈 펜스는 만들지 않는다.** 내용 없는 코드 카드가 화면에 서면 사용자는
      // 무엇이 사라졌는지조차 알 수 없다(실기 지적 2026-08-16).
      guard !body.isEmpty else { return }
      flushBlock()
      blocks.append("```" + language + "\n" + body + "\n```")
    }

    private mutating func appendInline(_ mark: String) {
      if currentCell != nil {
        currentCell? += mark
      } else if !inPre {
        inline += mark
      }
    }

    /// `<img>` 한 장을 마크다운으로.
    ///
    /// - 받을 수 있는 주소(`http…`)는 그대로 남긴다 — 물질화는 캡처 파이프라인의 일이다.
    /// - `attachment:UUID:파일명`(노션 내부 스킴)과 `data:`(본문에 킬로바이트를
    ///   쏟아붓는 인라인 바이트)는 **버린다.**
    ///
    /// 한때 이름만이라도 `![](파일명)`으로 세웠다. 그 자리는 영원히 채워지지 않는다:
    /// 노션은 그림 바이트도 서명 주소도 클립보드에 싣지 않고(실측), `attachment:`는
    /// 주소가 아니라 노션 내부 블록을 가리키는 사설 표식이라 우리가 받아올 수단이
    /// 없다. 채워지지 않을 자리는 글에 남기지 않는다 — 사용자 판단(2026-08-16,
    /// 다른 앱에서도 같은 것을 확인한 뒤): "어차피 복사 안 되는 부분이면 표시 자체가
    /// 없는 게 맞다."
    private func imageMarkdown(_ attributes: [String: String]) -> String {
      let src = attributes["src"] ?? ""
      guard !src.isEmpty, !src.hasPrefix("attachment:"), !src.hasPrefix("data:") else { return "" }
      let alt = (attributes["alt"] ?? "").replacingOccurrences(of: "]", with: "")
      return "\n![\(alt)](\(src))\n"
    }

    /// HTML 공백 의미론: 연속 공백·개행은 한 칸이다. `<pre>` 밖에서만.
    private func collapse(_ text: String) -> String {
      var out = ""
      out.reserveCapacity(text.count)
      var lastWasSpace = false
      for ch in text {
        if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
          if !lastWasSpace { out.append(" ") }
          lastWasSpace = true
        } else {
          out.append(ch)
          lastWasSpace = false
        }
      }
      return out
    }

    private mutating func flushBlock() {
      var text = inline.trimmingCharacters(in: .whitespacesAndNewlines)
      inline = ""
      guard !text.isEmpty else { return }
      // 이미지가 인라인에 끼어 있으면 제 줄로 선다(위 imageMarkdown이 개행을 뒀다).
      if headingLevel > 0 {
        text = String(repeating: "#", count: headingLevel) + " " + text
      }
      if listItemOpen, let list = lists.last {
        let indent = String(repeating: "  ", count: max(0, lists.count - 1))
        if list.ordered {
          text = indent + "\(list.index). " + text
          lists[lists.count - 1].index += 1
        } else {
          text = indent + "- " + text
        }
      }
      if quoteDepth > 0 {
        let prefix = String(repeating: "> ", count: quoteDepth)
        text = text.split(separator: "\n", omittingEmptySubsequences: false)
          .map { prefix + $0 }.joined(separator: "\n")
      }
      blocks.append(text)
    }

    private mutating func emitTable() {
      defer { tableRows = []; headerRowCount = 0 }
      let rows = tableRows.filter { !$0.isEmpty }
      guard let first = rows.first else { return }
      let width = rows.map(\.count).max() ?? first.count
      func line(_ row: [String]) -> String {
        let padded = row + Array(repeating: "", count: max(0, width - row.count))
        let cells = padded.map {
          $0.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
        }
        return "| " + cells.joined(separator: " | ") + " |"
      }
      var out: [String] = []
      // GFM 표는 머리행이 필수다. `<thead>`가 없으면 첫 행이 머리다.
      let headerRows = max(1, min(headerRowCount, rows.count))
      out.append(line(rows[0]))
      out.append("| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |")
      for row in rows.dropFirst(headerRows == 0 ? 1 : headerRows) {
        out.append(line(row))
      }
      // 머리행이 여럿인 표는 둘째 머리행부터 본문으로 눕는다 — 정보를 버리지 않는다.
      for row in rows.prefix(headerRows).dropFirst() {
        out.insert(line(row), at: 2)
      }
      blocks.append(out.joined(separator: "\n"))
    }

    mutating func finish() -> String {
      flushBlock()
      return blocks.joined(separator: "\n\n")
        .replacingOccurrences(of: "\n\n\n", with: "\n\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }
}
