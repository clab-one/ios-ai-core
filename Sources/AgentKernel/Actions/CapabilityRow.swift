import Foundation

/// 결과 한 줄의 **자리 구분**.
///
/// 유닛 구분자(U+001F)를 쓰는 이유: 메일 제목과 Slack 문장에 들어갈 수 있는
/// 글자가 아니다. 쉼표·탭·파이프는 모두 본문에 나타난다.
enum CapabilityRowCodec {
  static let separator: Character = "\u{001F}"

  /// 한 줄로 접는다. 빈 자리도 **자리를 지킨다** — 빈 값을 버리면 뒤 자리가
  /// 앞으로 밀려 식별자가 제목으로 읽힌다.
  static func encode(_ fields: [String]) -> String {
    fields.map { $0.replacingOccurrences(of: String(separator), with: " ") }
      .joined(separator: String(separator))
  }

  static func decode(_ raw: String, fields: Int) -> [String] {
    var parts = raw.split(separator: separator, omittingEmptySubsequences: false)
      .map(String.init)
    if parts.count < fields {
      parts.append(contentsOf: Array(repeating: "", count: fields - parts.count))
    }
    return Array(parts.prefix(fields))
  }
}

/// 검색·조회 결과 한 줄의 **공통 모양**.
///
/// 능력마다 다른 자리 배치를 두지 않는다. 예전에는 어댑터가 각자 문자열을 이어
/// 붙였고(메일은 네 자리, Slack은 세 자리, 연락처는 네 자리), 그 배치를 아는
/// 곳은 이어 붙인 파일 하나뿐이었다 — 결과를 읽어 축약하는 쪽
/// (`ToolResultReducer`)이 생기자 그 배치는 곧바로 첨자 마법이 됐다.
///
/// 그래서 자리는 **다섯 개로 고정**하고, 각 어댑터가 자기 값을 이 다섯 자리로
/// 옮긴다. 자리가 비는 것은 허용된다(일정에는 본문이 없다).
public struct CapabilitySourceRow: Sendable, Hashable {
  /// 사람이 먼저 읽는 한 줄. 메일 제목, 일정 제목, 채널 이름, 기록 제목.
  public let title: String
  /// 제목 아래의 한 줄. 보낸 사람, 기한, 말한 사람, 요약 첫 줄.
  public let subtitle: String
  /// **바깥에서 온 본문.** 있으면 이 값이 축약의 재료가 된다.
  ///
  /// 어댑터는 이 자리에 원문을 그대로 담는다 — 여기서 `UntrustedText`로 감싸지
  /// 않는 이유는 감싸는 자리가 하나여야 하기 때문이다(`ToolResultReducer`).
  /// 중간에서 감싸면 문맥에 `<<<data>>>` 표시가 겹쳐 들어간다.
  public let body: String
  /// 공급자·기기가 준 식별자. 다음 단계(`mail.read`·`calendar.update`)의 인자다.
  public let identifier: String
  /// 사람이 읽을 시각 문자열. 없으면 빈 값이다 — 시각을 지어내지 않는다.
  public let timestamp: String

  public init(
    title: String, subtitle: String = "", body: String = "", identifier: String = "",
    timestamp: String = ""
  ) {
    self.title = title
    self.subtitle = subtitle
    self.body = body
    self.identifier = identifier
    self.timestamp = timestamp
  }

  private static let fieldCount = 5

  public var encoded: ActionValue {
    .text(CapabilityRowCodec.encode([title, subtitle, body, identifier, timestamp]))
  }

  public init?(_ value: ActionValue) {
    guard case .text(let raw) = value, !raw.isEmpty else { return nil }
    let fields = CapabilityRowCodec.decode(raw, fields: Self.fieldCount)
    self.init(
      title: fields[0], subtitle: fields[1], body: fields[2], identifier: fields[3],
      timestamp: fields[4])
  }

  /// 수령증의 `rows` 자리에서 줄들을 꺼낸다. 다른 모양이 담겨 있으면 빈 배열이다.
  public static func rows(in details: [String: ActionValue]) -> [CapabilitySourceRow] {
    guard case .list(let values)? = details[Self.detailKey] else { return [] }
    return values.compactMap(CapabilitySourceRow.init)
  }

  public static func detail(_ rows: [CapabilitySourceRow]) -> [String: ActionValue] {
    [
      detailKey: .list(rows.map(\.encoded)),
      "count": .number(Double(rows.count)),
    ]
  }

  /// 수령증에서 줄들이 사는 자리 이름.
  public static let detailKey = "rows"
}
