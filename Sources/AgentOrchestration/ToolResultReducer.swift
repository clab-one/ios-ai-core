import AgentKernel
import Foundation


/// 도구가 돌려준 것을 **기기에서 먼저 줄인다.**
///
/// 검색 결과 열여덟 건을 그대로 모델에 실으면 두 가지가 함께 나빠진다. 문맥이
/// 남의 글로 가득 차 지시가 묻히고, 그 문맥이 통째로 Private Cloud Compute로
/// 나간다. 그래서 순서는 언제나 **회수 → 지역 축소 → (필요하면) 합성**이다.
///
/// 축소는 세 가지만 한다:
///
/// 1. **같은 것 지우기** — 같은 스레드의 같은 문장이 검색과 히스토리에서 두 번
///    올라온다.
/// 2. **질의와의 겹침으로 줄 세우기** — 모델이 고르게 하지 않는다. 낱말 겹침은
///    계산이고, 계산을 모델에 맡기면 비용만 든다.
/// 3. **상한 걸기** — 출처마다, 그리고 전체에 상한이 있다.
public struct ToolResultReducer: Sendable {
  /// 한 출처에서 문맥에 실을 최대 줄 수.
  public static let perSourceLimit = 5
  /// 전체 상한. 이 수를 넘기면 합성 품질이 아니라 지연이 늘어난다.
  public static let totalLimit = 12
  /// 열 수 있는 결과 하나 — 화면이 **기존 렌더러**로 그린다.
  public struct Reference: Sendable, Hashable, Identifiable {
    public let capability: CapabilityID
    public let identifier: String
    public let title: String
    public let subtitle: String
    public var sourceReference: SourceReference? = nil

    public init(
      capability: CapabilityID, identifier: String, title: String, subtitle: String,
      sourceReference: SourceReference? = nil
    ) {
      self.capability = capability
      self.identifier = identifier
      self.title = title
      self.subtitle = subtitle
      self.sourceReference = sourceReference
    }
    public var id: String { sourceReference?.identity ?? "\(capability.rawValue)#\(identifier)" }

    /// 앱 안의 기록이면 그 id. 바깥 식별자(메일 id·일정 id)는 기록이 아니다.
    public var itemID: String? {
      switch capability.domain {
      case "memory", "artifact", "content", "recording": identifier.isEmpty ? nil : identifier
      default: nil
      }
    }
  }

  /// 무엇을 얼마나 읽었는가. 문구는 화면이 만든다 — 여기서 번역하면 접근
  /// 영수증의 말이 런타임과 갈라진다.
  public struct ReadSource: Sendable, Hashable {
    public let capability: CapabilityID
    public let count: Int

    public init(capability: CapabilityID, count: Int) {
      self.capability = capability
      self.count = count
    }
  }

  /// 상한과 중복 제거를 지난 한 줄. **여기서 모델 문맥을 만들지 않는다** —
  /// 문맥으로 옮기는 일은 `EvidenceCompiler`가 하고, 그 자리가 원문 경계다(§17).
  public struct Selected: Sendable, Hashable {
    public let capability: CapabilityID
    public let row: CapabilitySourceRow
    public var sourceReference: SourceReference? = nil

    public init(
      capability: CapabilityID, row: CapabilitySourceRow, sourceReference: SourceReference? = nil
    ) {
      self.capability = capability
      self.row = row
      self.sourceReference = sourceReference
    }
  }

  public struct Reduced: Sendable {
    /// 근거로 옮길 줄들. 점수 순이고 상한이 걸려 있다.
    public let selected: [Selected]
    public let references: [Reference]
    public let readSources: [ReadSource]
    /// 이 차례에 기기를 떠난 요청이 있었는가(접근 영수증).
    public let leftDevice: Bool
    /// 합성이 필요한가. 쓰기 수령증 하나로 끝나는 차례는 합성하지 않는다 —
    /// "일정을 만들었다"는 사실은 모델이 다시 쓸 필요가 없다.
    public let needsSynthesis: Bool

    public init(
      selected: [Selected], references: [Reference], readSources: [ReadSource],
      leftDevice: Bool, needsSynthesis: Bool
    ) {
      self.selected = selected
      self.references = references
      self.readSources = readSources
      self.leftDevice = leftDevice
      self.needsSynthesis = needsSynthesis
    }

    public static let empty = Reduced(
      selected: [], references: [], readSources: [], leftDevice: false,
      needsSynthesis: false)
  }

  public let query: String

  public init(query: String) {
    self.query = query
  }

  public func reduce(_ receipts: [ActionReceipt]) -> Reduced {
    var candidates: [(row: CapabilitySourceRow, capability: CapabilityID, score: Double, source: SourceReference?)] = []
    var references: [Reference] = []
    var readSources: [ReadSource] = []
    var leftDevice = false
    var seen: Set<String> = []
    let terms = Self.terms(in: query)

    // 최신 재조회가 앞선 검색 후보를 대체한다.
    for receipt in receipts.reversed() {
      if Self.leavesDevice(receipt.capability) { leftDevice = true }
      let rows = CapabilitySourceRow.rows(in: receipt.details)
      guard !rows.isEmpty else { continue }
      readSources.append(ReadSource(capability: receipt.capability, count: rows.count))

      var kept = 0
      for row in rows {
        let source = receipt.sources.first { reference in
          reference.kind == .chatMessage
            ? reference.containerID == row.identifier && reference.id == row.timestamp
            : reference.id == row.identifier
        }
        let fingerprint = source?.identity ?? (receipt.capability.domain + "#" + Self.fingerprint(row))
        guard seen.insert(fingerprint).inserted else { continue }
        if !row.identifier.isEmpty || !row.title.isEmpty {
          references.append(
            Reference(
              capability: receipt.capability, identifier: row.identifier,
              title: row.title.isEmpty ? row.subtitle : row.title,
              subtitle: Self.subtitle(row), sourceReference: source))
        }
        guard kept < Self.perSourceLimit else { continue }
        kept += 1
        candidates.append(
          (row: row, capability: receipt.capability, score: Self.score(row, terms: terms), source: source))
      }
    }

    // 점수 순으로 세우고 전체 상한을 건다. 같은 점수면 원래 순서를 지킨다 —
    // 공급자가 준 순서에는 최신성이 들어 있다.
    let ranked = candidates.enumerated()
      .sorted { lhs, rhs in
        if lhs.element.score != rhs.element.score {
          return lhs.element.score > rhs.element.score
        }
        return lhs.offset < rhs.offset
      }
      .prefix(Self.totalLimit)
      .map(\.element)

    let selected = ranked.map { Selected(capability: $0.capability, row: $0.row, sourceReference: $0.source) }
    let hasBody = ranked.contains { !$0.row.body.isEmpty }
    let retrievals = readSources.reduce(0) { $0 + $1.count }
    return Reduced(
      selected: selected,
      references: Array(references.prefix(Self.totalLimit)),
      readSources: readSources,
      leftDevice: leftDevice,
      // 합성의 근거: 읽을 본문이 있거나, 출처가 둘 이상이거나, 한 출처에서
      // 여러 건이 왔다. 한 건짜리 조회는 그 한 건을 보여 주는 것이 답이다.
      needsSynthesis: hasBody || readSources.count > 1 || retrievals > 1)
  }

  // MARK: 지역 계산

  private static func terms(in query: String) -> [String] {
    query.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { $0.count > 1 }
  }

  /// 질의 낱말과의 겹침. 제목의 겹침을 본문보다 무겁게 센다 — 제목에 낱말이
  /// 있으면 그 줄은 그 주제에 대한 줄이다.
  private static func score(_ row: CapabilitySourceRow, terms: [String]) -> Double {
    guard !terms.isEmpty else { return 0 }
    let title = (row.title + " " + row.subtitle).lowercased()
    let body = row.body.lowercased()
    var score = 0.0
    for term in terms {
      if title.contains(term) { score += 2 }
      if body.contains(term) { score += 1 }
    }
    return score
  }

  /// 참조 한 줄의 아래 줄. 보낸 사람과 시각을 잇는다.
  private static func subtitle(_ row: CapabilitySourceRow) -> String {
    [row.subtitle, row.timestamp].filter { !$0.isEmpty }.joined(separator: " · ")
  }

  /// 같은 줄 판정.
  ///
  /// 식별자 **하나만** 보면 안 된다. 채팅 줄의 식별자는 채널이고(스레드를 펼치려면
  /// 채널 id가 필요하다), 한 채널의 메시지 열 건이 모두 같은 식별자를 갖는다 —
  /// 그래서 식별자만 보던 판정은 채널마다 한 줄만 남겼다.
  private static func fingerprint(_ row: CapabilitySourceRow) -> String {
    if !row.identifier.isEmpty { return "id:\(row.identifier)#\(row.timestamp)" }
    let body = row.body.isEmpty ? row.title : row.body
    return "text:\(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))"
  }

  /// 이 능력이 기기를 떠나는가. 접근 영수증이 이 값을 말한다.
  private static func leavesDevice(_ capability: CapabilityID) -> Bool {
    switch capability.domain {
    case "mail", "chat", "web", "share": true
    default: false
    }
  }
}
