import Foundation

/// 구조화 모델 답의 규격·복사·반복을 판정한다.
///
/// **정본은 JustSend의 `JustSendMemoryCore/SummaryJudgment`다**(`~/justsend/ios-prod`).
/// 판정 셋(규격 위반·원문 복사·반복)과 상수(복사 상한 0.6, 헤드라인 60, 요점 180)는
/// 그쪽 실기에서 나온 값이므로 그대로 옮겼다.
///
/// 출력 언어는 여기서 모델 재시도의 이유로 쓰지 않는다. 이 코어는 번역 경로를
/// 옮기지 않았다 — 요약은 원문의 언어로 선다.
enum SummaryJudgment {

  enum Reason: String, Sendable, Equatable {
    /// JSON이 아니다(코드펜스, 산문, 잘린 응답).
    case notJSON
    /// 키가 다르다(여분 키, 누락 키).
    case wrongKeys
    /// 헤드라인이나 요점이 비었다.
    case empty
    /// 마지막 요점만 완결되지 않아 안전하게 버렸다.
    case incomplete
    /// 헤드라인이 화면 제목으로 읽기에는 너무 길다.
    case overlong
    /// 원문이 그대로 실렸다.
    case copiedSource
    /// 같은 글자·구문의 되풀이.
    case repeated
    /// 대상 언어와 다른 필드를 발견했다.
    case wrongLanguage
    /// 언어를 확정할 수 없어 안전하게 승격하지 않았다.
    case languageIndeterminate
    /// 번역 또는 번역 후 검증이 실패했다.
    case translationFailed
    /// 모델 호출 자체가 실패했다.
    case modelFailed
  }

  enum Verdict {
    case accept(headline: String, points: [String])
    case reject(Reason)
  }

  enum TitleVerdict {
    case accept(String?)
    case reject(Reason)
  }

  /// 원문의 이 비율 이상이 요약에 그대로 실렸으면 복사로 본다.
  ///
  /// 0.9가 아니라 0.6인 이유: 앞부분만 요약하고 뒤에 원문을 이어 붙인 응답이 실제로
  /// 관찰됐고(사용자 지적), 그 경우 복사율이 절반 남짓이었다. 정상 요약은 원문의
  /// 20~40% 길이이므로 0.6에 닿지 않는다.
  private static let copyCeiling = 0.6
  private static let headlineScalarLimit = 60
  private static let pointScalarLimit = 180


  static func judge(_ data: Data, source: String) -> Verdict {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .reject(.notJSON)
    }
    guard Set(object.keys) == ["headline", "points"] else { return .reject(.wrongKeys) }
    guard let rawHeadline = object["headline"] as? String,
      let rawPoints = object["points"] as? [String]
    else { return .reject(.wrongKeys) }

    // **다듬기 전에 원문과 견준다.** 예전에는 sanitize·truncate를 거친 뒤 비교했고,
    // 원문을 그대로 되돌려준 응답이 잘려 나간 덕에 그 문을 통과했다.
    let asWritten = ([rawHeadline] + rawPoints).joined(separator: " ")
    if copiesSource(asWritten, source: source),
      !preservesShortSingleLine(headline: rawHeadline, points: rawPoints, source: source)
    {
      return .reject(.copiedSource)
    }
    if hasRepetition([rawHeadline] + rawPoints) { return .reject(.repeated) }

    let headline = tidy(rawHeadline)
    // 모델이 헤드라인을 첫 요점으로 그대로 되풀이하는 일이 잦다(실측 DEF-047).
    // 화면에서는 제목과 첫 줄이 같은 문장으로 겹쳐 보인다 — 요점 쪽을 접는다.
    var points = dedupe(
      rawPoints.map(tidy).filter { !$0.isEmpty }.flatMap(readablePoints)
    ).filter { compact($0) != compact(headline) }
    guard !headline.isEmpty, !points.isEmpty else { return .reject(.empty) }
    if let last = points.last, !isCompletePoint(last) {
      points.removeLast()
    }
    guard !points.isEmpty else { return .reject(.incomplete) }
    guard headline.unicodeScalars.count <= headlineScalarLimit else {
      return .reject(.overlong)
    }
    return .accept(headline: headline, points: points)
  }

  static func judgeTitle(_ data: Data, source: String) -> TitleVerdict {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .reject(.notJSON)
    }
    if object.isEmpty { return .accept(nil) }
    guard Set(object.keys) == ["title"],
      let rawTitle = object["title"] as? String
    else { return .reject(.wrongKeys) }
    let title = tidy(rawTitle)
    guard !title.isEmpty else { return .accept(nil) }
    if copiesSource(title, source: source) { return .reject(.copiedSource) }
    if hasRepetition([title]) { return .reject(.repeated) }
    return .accept(title)
  }

  // MARK: - 2. 원문 복사

  /// 요약이 원문을 옮겨 놓았는가.
  ///
  /// 문장 단위로 견준다. 요약이 원문 문장을 몇 개 그대로 담는 것은 흔하고 문제도
  /// 아니다 — 원문 **대부분**이 그대로 실렸을 때만 복사다.
  static func copiesSource(_ summary: String, source: String) -> Bool {
    let compactSource = compact(source)
    guard !compactSource.isEmpty else { return false }
    let compactSummary = compact(summary)
    // 원문을 통째로 품고 있으면 더 볼 것이 없다.
    if compactSummary.contains(compactSource) { return true }

    // **고유 문장으로 센다.** 같은 문장이 여러 번 나오는 원문(쪽마다 반복되는 머리글,
    // 시세 알림처럼 형식이 같은 줄)에서 중복을 각각 세면, 요약이 그 문장 하나를 담기만
    // 해도 복사율이 100%로 부풀려진다 — 정상 요약이 복사로 거부됐다.
    var unique: [String] = []
    var seen = Set<String>()
    for sentence in sentences(in: source) {
      let key = compact(sentence)
      guard key.count >= 12, seen.insert(key).inserted else { continue }
      unique.append(key)
    }
    guard unique.count >= 2 else {
      // 문장이 하나뿐인 짧은 원문은 길이로만 판정한다.
      return Double(compactSummary.count) >= Double(compactSource.count) * copyCeiling
        && compactSummary.contains(compactSource)
    }
    let total = unique.reduce(0) { $0 + $1.count }
    let copied = unique.filter { compactSummary.contains($0) }.reduce(0) { $0 + $1.count }
    return Double(copied) / Double(total) >= copyCeiling
  }

  /// 한 줄짜리 짧은 기록은 압축할 여백이 작다. 모델이 별도 헤드라인을 만들고
  /// 원문을 소수의 요점으로 정확히 보존했다면, 장문 복사 방지 규칙으로 버리지 않는다.
  ///
  /// 여러 줄·너무 짧은 할 일·장문에는 이 예외를 열지 않는다. 표·OCR 파편은 줄 경계로
  /// 걸러지고, 통째 복사도 계속 실패다.
  private static func preservesShortSingleLine(
    headline rawHeadline: String,
    points rawPoints: [String],
    source rawSource: String
  ) -> Bool {
    let source = tidy(rawSource)
    guard (24...240).contains(source.unicodeScalars.count) else { return false }
    guard !source.contains("\n"), !source.contains("\r"),
      (1...4).contains(rawPoints.count)
    else { return false }

    let headline = tidy(rawHeadline)
    let points = rawPoints.map(tidy).filter { !$0.isEmpty }
    let sourceKey = compact(source)
    let headlineKey = compact(headline)
    guard !headlineKey.isEmpty, headlineKey != sourceKey, headlineKey.count < sourceKey.count else {
      return false
    }
    return compact(points.joined()) == sourceKey && !hasRepetition([headline] + points)
  }

  // MARK: - 3. 반복

  /// 같은 글자나 짧은 구문의 되풀이인가.
  ///
  /// 두 가지를 본다: 한 글자가 네 번 이상 이어지는 줄(`1111111111`), 그리고 한 줄
  /// 안에서 1~4낱말 구문이 세 번 이상 되풀이되는 것("승인 완료. 승인 완료. 승인 완료.").
  static func hasRepetition(_ lines: [String]) -> Bool {
    lines.contains { line in
      let scalars = line.unicodeScalars
      if scalars.count >= 4, let first = scalars.first,
        scalars.dropFirst().allSatisfy({ $0 == first })
      {
        return true
      }
      let words = line.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
      guard words.count >= 3 else { return false }
      for length in 1...min(4, words.count / 3) {
        for start in 0...(words.count - length * 3) {
          let phrase = words[start..<(start + length)]
          var runs = 1
          while start + (runs + 1) * length <= words.count,
            words[(start + runs * length)..<(start + (runs + 1) * length)].elementsEqual(phrase)
          {
            runs += 1
          }
          if runs >= 3 { return true }
        }
      }
      return false
    }
  }

  // MARK: - 다듬기

  /// 목록 기호와 둘레 공백만 걷는다. 내용은 건드리지 않는다 — 자르고 고치기 시작하면
  /// 모델이 쓴 문장이 우리가 쓴 문장으로 변한다.
  static func tidy(_ value: String) -> String {
    var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    for marker in ["- ", "* ", "• ", "· "] where text.hasPrefix(marker) {
      text = String(text.dropFirst(marker.count))
      break
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 같은 뜻의 요점을 접는다. 대소문자와 공백만 무시해 비교한다.
  static func dedupe(_ points: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for point in points {
      let key = compact(point)
      guard !key.isEmpty, seen.insert(key).inserted else { continue }
      result.append(point)
    }
    return result
  }

  /// 모델이 한 배열 값에 여러 문장을 몰아넣으면 내용을 버리거나 글자를 자르지 않고
  /// 문장 경계에서 요점으로 나눈다. 단일 장문은 그대로 두어 사실을 훼손하지 않는다.
  private static func readablePoints(_ point: String) -> [String] {
    guard point.unicodeScalars.count > pointScalarLimit else { return [point] }
    let parts = sentences(in: point).map(tidy).filter { !$0.isEmpty }
    guard parts.count > 1, parts.allSatisfy(isCompletePoint) else { return [point] }
    return parts
  }

  /// Guided generation이 token 상한에서 닫은 마지막 값만 중간에서 끊길 수 있다.
  /// 구두점은 모든 언어에서 강한 완결 신호다. 한국어는 명사형 종결도 정상 문장으로 쓴다.
  private static func isCompletePoint(_ point: String) -> Bool {
    guard let last = point.unicodeScalars.last else { return false }
    if last == "." || last == "!" || last == "?" || last == "。" || last == "…" {
      return true
    }
    return [
      "다", "요", "함", "됨", "임", "음", "없음", "있음", "낮음", "높음",
      "완료", "유지", "적용", "발표", "배송", "시작", "초과", "필요", "예정", "가능",
    ].contains { point.hasSuffix($0) }
  }


  // MARK: - 도구

  static func compact(_ value: String) -> String {
    value.lowercased().unicodeScalars.reduce(into: "") { result, scalar in
      if CharacterSet.alphanumerics.contains(scalar) { result.unicodeScalars.append(scalar) }
    }
  }

  static func sentences(in text: String) -> [String] {
    var sentences: [String] = []
    var current = ""
    for scalar in text.unicodeScalars {
      current.unicodeScalars.append(scalar)
      if scalar == "." || scalar == "!" || scalar == "?" || scalar == "\n" || scalar == "。" {
        sentences.append(current)
        current = ""
      }
    }
    sentences.append(current)
    return sentences.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}
