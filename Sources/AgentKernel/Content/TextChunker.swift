import Foundation

/// 온디바이스 요약 파이프라인의 입력 청킹.
///
/// **정본은 JustSend의 `JustSendMemoryCore/TextChunker`다**(`~/justsend/ios-prod`).
/// 이 코어에도 같은 것을 다시 만들지 않고 그대로 옮겼다 — 경계 계층과 상수는
/// 그쪽의 실측이 정한 값이고, 여기서 다르게 고르면 같은 실패를 다시 겪는다.
///
/// 경계를 계층으로 두고, 최후의 수단을 제외하면 절대 음절 중간에서 자르지 않는다:
/// 문단(빈 줄) > 줄바꿈 > 문장 끝 > 낱말(공백) > 강제.
public enum TextChunker {

  /// 청크당 유니코드 스칼라 예산 — **창 크기에서 파생한다.**
  ///
  /// 정본의 실측(2026-08-13, iPhone 17 Pro / iOS 27, 문서 131건 + 조각 7단):
  ///
  /// - 26.4+에서 기기 모델의 창은 **8,192**다(`SystemLanguageModel.contextSize`).
  ///   4,096은 그 값을 못 물어볼 때의 폴백이다.
  /// - 스칼라당 토큰은 한국어 산문 0.627, 표가 섞인 문서 0.637 — 최악값 0.64.
  ///
  /// 창이 허락하는 만큼 다 쓰지는 않는다. 창만 보고 5,868까지 키웠더니 정리본의
  /// 분량이 무너졌다(7쪽 PDF: 14조각·41불릿·1,635토큰 → 2조각·6불릿·346토큰).
  /// 조각 하나가 원문 서너 쪽을 담으면 모델은 그 서너 쪽을 헤드라인 하나와 요점
  /// 셋으로 접는다. 창은 **넘지 말아야 할 선**이지 채워야 할 목표가 아니다.
  public static func budget(forContextTokens contextTokens: Int) -> Int {
    let usable = Double(contextTokens) * windowShare - Double(reservedTokens)
    guard usable > 0 else { return minimumBudget }
    let windowCeiling = Int(usable / worstCaseTokensPerScalar)
    return max(minimumBudget, min(pageSizedBudget, windowCeiling))
  }

  /// 원문 한 쪽 남짓. 정본이 실물로 고른 값이다(`5,868 → 346` · `1,800 → 1,131` ·
  /// `1,000 → 1,873` 토큰). 조각 수가 곧 분량이다.
  private static let pageSizedBudget = 1_200
  /// 창에서 원문이 차지해도 되는 몫. 나머지 절반은 지시문·토크나이저 차이의 자리다.
  private static let windowShare = 0.5
  /// 원문 앞뒤로 반드시 들어가는 것: 출력 상한과 지시문(실측 59토큰) + 여유.
  private static let reservedTokens = SummaryPrompt.maximumResponseTokens + 60
  /// 실측한 스칼라당 토큰의 **최악값**.
  private static let worstCaseTokensPerScalar = 0.64
  private static let minimumBudget = 400

  /// 창을 모를 때 가정하는 세션 상한. 26.4 미만 기기가 실제로 이 창이다.
  public static let sessionContextLimit = 4_096

  /// 창을 모를 때의 예산.
  public static let defaultBudget = budget(forContextTokens: sessionContextLimit)

  /// 한 조각이 지나치게 짧아지는 걸 막는 하한 비율. 이게 없으면 문단 경계가 맨 앞에
  /// 하나 있을 때 `"짧다."` 3글자가 독립 청크가 되어 모델 호출 한 번을 통째로
  /// 낭비한다(구 코어의 실제 동작).
  private static let minimumFillRatio = 2.0 / 5.0

  /// 정본 한 벌의 **조각 하나.** 오프셋은 다듬은 본문(`trimmed`) 안의 유니코드
  /// 스칼라 자리다 — 조각의 정체(`sequence`)와 자리(`start`/`end`)가 함께 있어야
  /// 근거가 "문서의 어디를 읽었는가"를 말할 수 있다.
  public struct Slice: Sendable, Equatable {
    public let sequence: Int
    public let start: Int
    public let end: Int
    public let body: String
  }

  public static func slices(_ text: String, budget: Int = defaultBudget) -> [Slice] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let budget = max(80, budget)

    let all = Array(trimmed.unicodeScalars)
    guard all.count > budget else {
      return [Slice(sequence: 0, start: 0, end: all.count, body: trimmed)]
    }

    var pieces: [Slice] = []
    var start = 0
    while start < all.count {
      let remaining = all.count - start
      if remaining <= budget {
        appendSlice(all[start...], start: start, end: all.count, to: &pieces)
        break
      }
      let cut = cutPoint(all, from: start, budget: budget)
      appendSlice(all[start..<cut], start: start, end: cut, to: &pieces)
      start = cut
      while start < all.count, isWhitespace(all[start]) { start += 1 }
    }
    return pieces
  }

  public static func chunk(_ text: String, budget: Int = defaultBudget) -> [String] {
    slices(text, budget: budget).map(\.body)
  }

  private static func appendSlice(
    _ slice: ArraySlice<Unicode.Scalar>, start: Int, end: Int, to pieces: inout [Slice]
  ) {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: slice)
    let piece = String(view).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !piece.isEmpty else { return }
    pieces.append(Slice(sequence: pieces.count, start: start, end: end, body: piece))
  }

  /// `start`부터 최대 `budget` 스칼라 안에서 자를 지점을 고른다.
  /// 반환값은 "다음 청크가 시작되는 인덱스".
  ///
  /// 각 등급에서 하한 위쪽의 **가장 뒤** 경계를 쓴다 — 예산을 최대한 채워야 모델
  /// 호출 횟수와 지연이 줄기 때문이다.
  private static func cutPoint(
    _ scalars: [Unicode.Scalar],
    from start: Int,
    budget: Int
  ) -> Int {
    let upper = start + budget
    let lower = start + max(1, Int(Double(budget) * minimumFillRatio))

    var paragraph = -1
    var line = -1
    var sentence = -1
    var word = -1

    // 한 번만 역주행하면서 등급별 최댓값을 채운다. 뒤에서 오므로 각 등급은 처음
    // 만나는 지점이 곧 가장 뒤의 경계다.
    var i = upper
    while i > lower {
      let prev = scalars[i - 1]

      if prev == "\n" || prev == "\r" {
        if line < 0 { line = i }
        if paragraph < 0, hasBlankLineBreak(scalars, endingAt: i - 1, notBefore: start) {
          paragraph = i
        }
      } else if sentence < 0, isSentenceEnd(scalars, at: i - 1, limit: upper) {
        sentence = i
      } else if word < 0, isWhitespace(prev) {
        word = i
      }

      if paragraph >= 0 { break }  // 최고 등급을 찾았으면 더 볼 필요 없다.
      i -= 1
    }

    if paragraph > 0 { return paragraph }
    if line > 0 { return line }
    if sentence > 0 { return sentence }
    if word > 0 { return word }
    return upper  // 공백조차 없는 연속 CJK — 이때만 스칼라 단위로 자른다.
  }

  /// `index`에서 끝나는 개행 연쇄가 빈 줄(개행 2회 이상)을 포함하는지.
  private static func hasBlankLineBreak(
    _ scalars: [Unicode.Scalar],
    endingAt index: Int,
    notBefore start: Int
  ) -> Bool {
    var newlines = 0
    var i = index
    while i >= start {
      let scalar = scalars[i]
      if scalar == "\n" {
        newlines += 1
        if newlines >= 2 { return true }
      } else if scalar != "\r", !isSpaceOnly(scalar) {
        return false
      }
      i -= 1
    }
    return false
  }

  /// 문장이 `index`에서 끝나는가.
  ///
  /// 구두점만 보면 한국어 캐주얼 메모("…만나기로 함\n…챙겨야 됨")를 전부 놓친다.
  /// 그래서 종결어미 + 뒤따르는 공백도 문장 끝으로 인정한다. 오탐이 나도 손해는
  /// "조금 이른 청크 경계"뿐이다.
  private static func isSentenceEnd(
    _ scalars: [Unicode.Scalar],
    at index: Int,
    limit: Int
  ) -> Bool {
    let scalar = scalars[index]
    if terminators.contains(scalar) { return true }
    guard koreanEnders.contains(scalar) else { return false }
    let next = index + 1
    guard next < limit, next < scalars.count else { return false }
    return isWhitespace(scalars[next])
  }

  private static let terminators: Set<Unicode.Scalar> = [
    ".", "!", "?", "…", "。", "！", "？", ";", "；",
  ]

  /// 보수적으로 고른 한국어 종결어미 음절. 넓히면 낱말 중간("다음", "요일")을 문장
  /// 끝으로 오인하는 빈도가 올라간다.
  private static let koreanEnders: Set<Unicode.Scalar> = [
    "다", "요", "죠", "함", "됨", "임", "음", "까", "네", "셈",
  ]

  private static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
      || CharacterSet.whitespacesAndNewlines.contains(scalar)
  }

  private static func isSpaceOnly(_ scalar: Unicode.Scalar) -> Bool {
    scalar == " " || scalar == "\t"
  }
}
