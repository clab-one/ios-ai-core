import Foundation

/// 모델이 쓸 만한 답을 내지 못했을 때 원문에서 요약을 뽑아낸다.
///
/// 이 물건이 있는 이유는 하나다: **요약을 만들어 낸다.** 모델을 세 번 불러도 반복만
/// 돌아오거나 규격을 계속 어기면, 예전에는 그 페이지가 결과에서 사라졌다. 사용자가
/// 첨부한 일곱 장 보고서가 한 장으로 줄어들고도 "요약 완료"라고 말했다.
///
/// 원문 복사와는 다르다. 문장을 **고르고**(전부가 아니라 상위 몇 개) **자른다**(각 문장
/// 상한). 압축률을 스스로 보장하지 못하면 아무것도 돌려주지 않는다 — 요약이라 부를 수
/// 없는 것을 요약 자리에 넣지 않는다.
/// 점수가 매겨진 문장 하나. 튜플로 두면 타입 검사가 폭발한다.
private struct RankedSentence {
  let index: Int
  let text: String
  let score: Int
}

enum ExtractiveSummary {
  /// 뽑아낸 요점 하나의 길이 상한. 이 위로는 문장이 아니라 문단으로 읽힌다.
  private static let pointScalarLimit = 120
  /// 헤드라인 상한. 목록에서 한 줄로 읽혀야 한다.
  private static let headlineScalarLimit = 60
  /// 결과가 원문의 이 비율을 넘으면 요약이 아니다.
  private static let compressionCeiling = 0.4
  /// 이 아래로 짧은 문장은 요점이 되지 못한다(머리글·쪽번호가 여기 걸린다).
  private static let minimumSentenceScalars = 8

  /// 원문에서 헤드라인 하나와 요점 몇 개를 세운다. 세울 수 없으면 nil.
  static func summarize(text: String) -> ExtractedSummary? {
    // 같은 문장이 여러 번 나오는 원문은 흔하다(쪽마다 반복되는 머리글, 스캔 오류).
    // 중복을 **고르기 전에** 접는다 — 접지 않으면 뽑아낸 결과가 그 반복을 물려받는다.
    let sentences = SummaryJudgment.dedupe(self.sentences(in: text))
    guard !sentences.isEmpty else { return nil }
    if sentences.count == 1 {
      if let structured = summarizeUnpunctuatedLine(sentences[0], source: text) {
        return structured
      }
      return preserveAtomicText(sentences[0], source: text)
    }
    if sentences.count == 2, let short = preserveShortSentences(sentences, source: text) {
      return short
    }
    if let rows = preserveShortRows(text) {
      return rows
    }

    var ranked: [RankedSentence] = []
    ranked.reserveCapacity(sentences.count)
    for (offset, sentence) in sentences.enumerated() {
      ranked.append(
        RankedSentence(index: offset, text: sentence, score: score(sentence, at: offset)))
    }
    ranked.sort { left, right in
      left.score == right.score ? left.index < right.index : left.score > right.score
    }

    let sourceScalars = compactScalarCount(text)
    guard sourceScalars > 0 else { return nil }
    let budget = Int(Double(sourceScalars) * compressionCeiling)

    // 점수 순으로 담되, 예산을 넘기 전에 멈춘다. 담은 뒤에는 **원문 순서로 되돌린다**
    // — 시간 순서가 뒤섞인 요약은 무슨 일이 먼저 있었는지 말해 주지 못한다.
    var chosen: [(index: Int, text: String)] = []
    var used = 0
    for candidate in ranked {
      guard chosen.count < maximumPoints(forSentenceCount: sentences.count) else { break }
      let clipped = clip(candidate.text, to: pointScalarLimit)
      let cost = clipped.unicodeScalars.count
      if !chosen.isEmpty, used + cost > budget { continue }
      chosen.append((candidate.index, clipped))
      used += cost
    }
    guard let lead = ranked.first else { return nil }
    let points = chosen.sorted { $0.index < $1.index }.map(\.text)
    guard !points.isEmpty else { return nil }

    let headline =
      sourceHeadline(in: text) ?? clip(headlineClause(of: lead.text), to: headlineScalarLimit)
    guard !headline.isEmpty else { return nil }

    // **헤드라인과 같은 문장은 요점에서 뺀다.**
    //
    // 모델 답은 `SummaryJudgment`가 이 중복을 접지만(실측 DEF-047), 발췌는 그 판정을
    // 지나지 않는다. 그래서 시세 알림처럼 짧은 줄이 늘어선 원문에서 헤드라인으로 고른
    // 문장이 첫 요점으로 그대로 다시 나왔다(실기: `💱 원/달러: 1,418원 (-0.72%)`가
    // 제목과 첫 줄에 나란히).
    let result = ExtractedSummary(
      headline: headline,
      points: SummaryJudgment.dedupe(points)
        .filter { SummaryJudgment.compact($0) != SummaryJudgment.compact(headline) }
    )
    guard !result.points.isEmpty else { return nil }
    // 원문 자체가 퇴화한 경우(같은 글자만 반복되는 스캔 오류 등)에는 뽑아낸 것도
    // 퇴화한다. 그럴 때는 요약이 없다고 말하는 편이 정직하다.
    guard !SummaryJudgment.hasRepetition([result.headline] + result.points) else {
      return nil
    }
    // **문장 단위 복사 검사는 여기에 적용하지 않는다.**
    //
    // 발췌는 정의상 원문 문장을 고르는 일이므로 그 검사를 통과할 수 없다. 고유 문장이
    // 둘뿐인 원문(같은 두 문장이 예순 번 반복되는 스캔)에서 그 둘을 고르면 문장 기준
    // 복사율은 100%지만 길이로는 30:1 압축이다. 발췌의 정당성은 **압축률**이고 그것은
    // 위 `budget`(원문의 40%)이 이미 강제한다.
    return result
  }

  /// 종결 부호 없이 적은 한 줄 메모는 문장 선택으로 줄일 수 없다. 모델도 그 한 줄을
  /// 그대로 돌려보냈다면, 앞부분을 제목으로 세우고 나머지를 요점으로 보존한다.
  ///
  /// 너무 짧은 할 일·장문·구두점이 있는 문장은 받지 않는다. 이 경로는 의미를
  /// 지어내는 요약이 아니라, 사용자가 적은 순서를 유지한 구조화 fallback이다.
  private static func summarizeUnpunctuatedLine(
    _ sentence: String,
    source: String
  ) -> ExtractedSummary? {
    guard source.unicodeScalars.count <= 240 else { return nil }
    guard !source.unicodeScalars.contains(where: {
      $0 == "." || $0 == "!" || $0 == "?" || $0 == "。" || $0 == "\n" || $0 == "\r"
    }) else { return nil }

    let words = sentence.split(whereSeparator: \.isWhitespace)
    guard words.count >= 6 else { return nil }
    let headlineWordCount = min(6, max(3, words.count / 3))
    let headline = clip(words.prefix(headlineWordCount).joined(separator: " "), to: headlineScalarLimit)
    let point = clip(words.dropFirst(headlineWordCount).joined(separator: " "), to: pointScalarLimit)
    guard !headline.isEmpty, point.split(whereSeparator: \.isWhitespace).count >= 3 else {
      return nil
    }
    guard !SummaryJudgment.hasRepetition([headline, point]) else { return nil }
    return ExtractedSummary(headline: headline, points: [point])
  }

  /// 세 단어 안팎의 메모와 OCR 한 줄은 줄일 정보가 없다. 모델이 같은 사실을 되돌린
  /// 경우에도 원문을 버리지 않고 제목과 한 요점으로 보존한다.
  private static func preserveAtomicText(
    _ sentence: String,
    source: String
  ) -> ExtractedSummary? {
    let sourceScalars = source.unicodeScalars.count
    guard sourceScalars >= 8, sourceScalars <= 80 else { return nil }
    let words = sentence.split(whereSeparator: \.isWhitespace)
    let hasLineStructure = source.contains("\n") || source.contains("\r")
    guard words.count <= 5 || hasLineStructure else { return nil }
    guard !SummaryJudgment.hasRepetition([sentence]) else { return nil }

    let headline = clip(sentence, to: headlineScalarLimit)
    let point = clip(sentence, to: pointScalarLimit)
    guard !headline.isEmpty, !point.isEmpty else { return nil }
    return ExtractedSummary(headline: headline, points: [point])
  }

  /// 아주 짧은 입력은 줄일 정보가 없다. 모델이 원문 복사 판정으로 거부되더라도 원문을
  /// 버리기보다 제목과 요점으로 구조화해 보존한다. 이 경로는 80자 이하에서만 열린다.
  private static func preserveShortSentences(
    _ sentences: [String],
    source: String
  ) -> ExtractedSummary? {
    guard source.unicodeScalars.count <= 80 else { return nil }
    guard let headline = sentences.first, headline.unicodeScalars.count <= headlineScalarLimit else {
      return nil
    }
    let points = SummaryJudgment.dedupe(Array(sentences.dropFirst()))
      .filter { SummaryJudgment.compact($0) != SummaryJudgment.compact(headline) }
    guard !points.isEmpty, points.allSatisfy({ $0.unicodeScalars.count <= pointScalarLimit }) else {
      return nil
    }
    guard !SummaryJudgment.hasRepetition([headline] + points) else { return nil }
    return ExtractedSummary(headline: headline, points: points)
  }

  /// 짧은 OCR·표 파편은 문장으로 압축할 수 없다. 제목 한 줄과 나머지 행을 그대로
  /// 구조화해 보존한다. 긴 표에는 열리지 않아 표 전체를 요약처럼 복사하지 않는다.
  private static func preserveShortRows(_ source: String) -> ExtractedSummary? {
    guard source.unicodeScalars.count <= 80 else { return nil }
    let rows = SummaryJudgment.dedupe(
      source.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    )
    guard (2...4).contains(rows.count), let first = rows.first else { return nil }
    let headline = clip(first, to: headlineScalarLimit)
    let points = rows.dropFirst().map { clip($0, to: pointScalarLimit) }
    guard !headline.isEmpty, !points.isEmpty else { return nil }
    guard !SummaryJudgment.hasRepetition([headline] + points) else { return nil }
    return ExtractedSummary(headline: headline, points: points)
  }

  // MARK: - 조립

  /// 원문 문장 수에 따른 요점 개수. 짧은 청크에 다섯 줄을 세우면 요약이 원문만큼 길어진다.
  private static func maximumPoints(forSentenceCount count: Int) -> Int {
    min(max(2, count / 4), 5)
  }

  /// 종결 부호와 줄바꿈으로만 자른다. 형태소 분석 없이 한국어·영어를 함께 다루려면
  /// 이 경계가 가장 안전하다 — 소수점(`9.3`)은 뒤에 공백이 없으므로 잘리지 않는다.
  private static func sentences(in text: String) -> [String] {
    var sentences: [String] = []
    var current = ""
    var scalars = Array(text.unicodeScalars)
    scalars.append(" ")
    var index = 0
    while index < scalars.count - 1 {
      let scalar = scalars[index]
      current.unicodeScalars.append(scalar)
      let isTerminator = scalar == "." || scalar == "!" || scalar == "?" || scalar == "。"
      let next = scalars[index + 1]
      let breaks =
        scalar == "\n"
        || (isTerminator
          && (next == " " || next == "\n" || CharacterSet.decimalDigits.contains(next) == false))
      if breaks {
        append(current, to: &sentences)
        current = ""
      }
      index += 1
    }
    append(current, to: &sentences)
    return sentences
  }

  private static func append(_ candidate: String, to sentences: inout [String]) {
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.unicodeScalars.count >= minimumSentenceScalars, isUsable(trimmed) else { return }
    sentences.append(trimmed)
  }

  /// 문장으로 읽히는가.
  ///
  /// 표를 쪼갠 조각이 이 문을 넘지 못하게 하는 것이 목적이다. 급여명세서 한 장에서
  /// `에이포엑스 주식회사 (`, `귀속월 2025` 같은 칸 내용을 요점으로 세우면 요약이
  /// 아니라 표의 파편이 된다 — 그럴 때는 요약이 없다고 말하는 편이 정직하다.
  private static func isUsable(_ sentence: String) -> Bool {
    let words = sentence.split(separator: " ").filter { !$0.isEmpty }
    guard words.count >= 3 else { return false }
    // 끊긴 괄호·따옴표는 문장이 중간에서 잘렸다는 표시다.
    for (open, close) in [("(", ")"), ("[", "]"), ("{", "}")] {
      let opens = sentence.components(separatedBy: open).count
      let closes = sentence.components(separatedBy: close).count
      guard opens == closes else { return false }
    }
    return true
  }

  /// 사실을 지고 있는 문장을 위로 올린다. 숫자·단위·고유 표기가 그 신호다 —
  /// 요약에서 가장 아쉬운 것은 문장이 아니라 수치다.
  private static func score(_ sentence: String, at index: Int) -> Int {
    var score = 0
    let scalars = sentence.unicodeScalars
    let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
    score += min(digits, 6)
    if sentence.contains("%") || sentence.contains("퍼센트") { score += 2 }
    if sentence.contains("원") || sentence.contains("명") || sentence.contains("건") { score += 1 }
    let count = scalars.count
    if count >= 20, count <= pointScalarLimit { score += 2 }
    // 첫 문장들은 대개 그 페이지가 무엇에 관한 것인지 말한다.
    if index < 3 { score += 1 }
    return score
  }

  /// 문서 첫 줄이 짧으면 저자가 이미 붙인 제목으로 쓴다. 수치가 많은 본문 문장을
  /// 점수만으로 제목 삼으면 표의 한 행이나 KPI 하나가 기록 전체를 대표하게 된다.
  private static func sourceHeadline(in text: String) -> String? {
    guard let firstLine = text.split(whereSeparator: \.isNewline).first else { return nil }
    var candidate = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    if candidate.hasPrefix("["), candidate.hasSuffix("]") {
      candidate = String(candidate.dropFirst().dropLast())
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let count = candidate.unicodeScalars.count
    guard count >= minimumSentenceScalars, count <= headlineScalarLimit else { return nil }
    return candidate
  }

  /// 헤드라인은 첫 절만 쓴다. 문장 하나를 통째로 제목에 세우면 목록에서 줄이 접힌다.
  private static func headlineClause(of sentence: String) -> String {
    for separator in [". ", ", ", " — ", "; "] {
      if let range = sentence.range(of: separator) {
        let clause = String(sentence[sentence.startIndex..<range.lowerBound])
        if clause.unicodeScalars.count >= minimumSentenceScalars { return clause }
      }
    }
    return sentence
  }

  /// 상한을 넘으면 마지막 공백에서 자르고 말줄임표를 남긴다. 원문 조각을 완결문처럼
  /// 속이지 않으면서 낱말이나 수치를 반쪽 내지 않는다.
  private static func clip(_ text: String, to limit: Int) -> String {
    let scalars = Array(text.unicodeScalars)
    guard scalars.count > limit else { return text }
    let contentLimit = max(1, limit - 1)
    let head = String(String.UnicodeScalarView(scalars.prefix(contentLimit)))
    if let lastSpace = head.lastIndex(of: " "),
      head.distance(from: head.startIndex, to: lastSpace) > contentLimit / 2
    {
      return String(head[head.startIndex..<lastSpace]) + "…"
    }
    return head + "…"
  }

  private static func compactScalarCount(_ text: String) -> Int {
    text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .unicodeScalars.count
  }
}

/// 발췌 결과. 헤드라인 하나와 요점 몇 개.
struct ExtractedSummary {
  let headline: String
  let points: [String]
}
