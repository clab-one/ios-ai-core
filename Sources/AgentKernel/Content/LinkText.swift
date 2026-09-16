import Foundation

/// 글에서 **주소를 읽고, 주소를 걷어낸 말**을 돌려준다.
///
/// 라우팅이 이것을 먼저 부른다. 주소는 문장의 끝을 차지하지만 뜻을 만들지 않고,
/// 주소 안의 `?s=46` 같은 조각은 물음표 판정까지 흔든다(실기 재현 2026-09-15) —
/// 그래서 뜻을 정하는 규칙은 걷어낸 말을 본다.
///
/// 페이지를 **가져오지 않는다.** 내려받기·렌더링·본문 추출은 앱의 일이고
/// (`LinkExtractor`), 여기에는 네트워크가 없다.
public enum LinkText {
  /// URL 감지는 핫패스에서 반복 호출된다. NSDataDetector는 생성 비용이 커서
  /// 불변 인스턴스를 프로세스 동안 한 번만 만들고 재사용한다.
  private static let detector = try? NSDataDetector(
      types: NSTextCheckingResult.CheckingType.link.rawValue
  )


  /// 텍스트의 첫 http/https URL(없으면 nil). `www.`·스킴 없는 도메인도 감지.
  public static func firstURL(in text: String) -> URL? {
      guard let detector = Self.detector else { return nil }
      let range = NSRange(text.startIndex..., in: text)
      for match in detector.matches(in: text, range: range) {


          guard let url = match.url, let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https" else { continue }
          return url
      }
      return nil
  }
  /// 콘텐츠 유형 분류는 사용자가 URL을 명시한 경우만 링크로 본다. NSDataDetector가
  /// `apple.com` 같은 일반 도메인 언급까지 URL로 승격하는 동작과 분리한다.
  public static func firstExplicitURL(in text: String) -> URL? {
      guard let detector = Self.detector else { return nil }
      let range = NSRange(text.startIndex..., in: text)
      for match in detector.matches(in: text, range: range) {
          guard
              let sourceRange = Range(match.range, in: text),
              text[sourceRange].lowercased().hasPrefix("http://")
                  || text[sourceRange].lowercased().hasPrefix("https://"),
              let url = match.url
          else { continue }
          return url
      }
      return nil
  }

  /// 명시한 주소를 걷어낸 **말**.
  ///
  /// 주소는 문장의 끝을 차지하지만 뜻을 만들지 않는다. 실기 재현
  /// (2026-09-15, 스크린샷 02:40): `"이게 무슨 내용이지? https://x.com/…?s=46"`가
  /// 저장으로 떨어졌다 — 뜻을 정하는 규칙이 문장의 끝을 보는데(어미·물음표)
  /// 그 끝이 주소였고, 하필 주소 안의 `?s=46` 때문에 물음표 판정도 빗나갔다.
  /// 그래서 묻는 문장인지 판정하려면 주소를 먼저 걷어내야 한다.
  ///
  /// 주소가 무엇인지는 `firstExplicitURL`과 **같은 규칙**으로 센다 — 두 값이
  /// 갈라지면 읽을 주소와 판정할 말이 서로 다른 문장을 본다.
  public static func prose(in text: String) -> String {
      guard let detector = Self.detector else { return text }
      let range = NSRange(text.startIndex..., in: text)
      var stripped = text
      // 뒤에서부터 지운다 — 앞에서 지우면 뒤 범위가 밀린다.
      for match in detector.matches(in: text, range: range).reversed() {
          guard let sourceRange = Range(match.range, in: text) else { continue }
          let lowered = text[sourceRange].lowercased()
          guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://"),
                let strippedRange = Range(match.range, in: stripped)
          else { continue }
          stripped.replaceSubrange(strippedRange, with: " ")
      }
      return stripped.replacingOccurrences(
          of: #"\s+"#, with: " ", options: .regularExpression
      ).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
