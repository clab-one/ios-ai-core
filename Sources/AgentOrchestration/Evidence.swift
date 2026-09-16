import AgentKernel
import Foundation


/// PCC로 넘어가는 **한 조각의 사실**.
///
/// 공급자 원문이 아니다. Slack 메시지 137건도, 메일 본문 전체도, 웹 페이지 통째도
/// 이 값이 되지 못한다 — 기기에서 줄이고 뽑은 뒤의 결과만 이 모양으로 선다(§14).
///
/// 왜 새 타입인가: 예전에는 축약기가 만든 `UntrustedText`가 곧 모델의 재료였고
/// (`ToolResultReducer.describe`), 그 문자열 안에 `text: <본문 600자>`가 그대로
/// 들어 있었다. 그 문맥은 합성 단계에서 그대로 PCC로 나갔다. 경계가 **타입으로**
/// 서 있지 않으면 호출부가 하나 늘 때마다 조용히 새 구멍이 난다.
public struct Evidence: Sendable, Equatable, Identifiable {
  /// 이 사실이 어디서 왔는가. `CapabilityID.domain`과 같은 낱말을 쓴다.
  public enum Source: String, Sendable, Hashable {
    case memory
    case artifact
    case content
    case recording
    case calendar
    case reminders
    case people
    case mail
    case chat
    case web
    case share
    /// 읽은 것이 아니라 **한 일**. 수령증이 근거다.
    case action

    public init(domain: String) {
      self = Source(rawValue: domain) ?? (domain == "contacts" ? .people : .action)
    }

    /// 이 출처의 글이 바깥에서 왔는가. 왔으면 지시 평면에 서지 못한다.
    public var isExternal: Bool {
      switch self {
      case .mail, .chat, .web, .share: true
      default: false
      }
    }

    /// 문맥 구획에 적을 출처 한 줄.
    public var contextOrigin: String {
      switch self {
      case .mail: "mail:message"
      case .chat: "chat:message"
      case .web: "web:document"
      case .calendar: "calendar:event"
      case .reminders: "reminders:item"
      case .people: "contacts:person"
      case .action: "justsend:receipt"
      default: "justsend:item"
      }
    }
  }

  public let source: Source
  /// 공급자·기기가 준 식별자. **다음 단계의 인자**가 이 값이다.
  public let sourceID: String?
  public var sourceReference: SourceReference? = nil
  public let title: String?
  /// 뽑아낸 사실. 한 줄은 한 문장이고, 길이는 `factLimit`로 잘린다.
  public let facts: [String]
  /// 기기 모델이 만든 압축 한 줄. 없으면 nil — 없는 요약을 지어내지 않는다.
  public let summary: String?
  /// 사람이 읽을 시각 문자열.
  ///
  /// `Date`가 아니다. 공급자가 준 것은 표시용 문자열이고(`CapabilitySourceRow`),
  /// 그것을 날짜로 파싱하면 앱이 시각을 **지어내는** 일이 된다(§45).
  public let timestamp: String?

  public var id: String { sourceReference?.identity ?? "\(source.rawValue)#\(sourceID ?? title ?? facts.first ?? "")" }

  /// 한 사실 줄의 글자 상한. 이 값이 곧 **원문이 기기를 떠나는 최대 폭**이다.
  public static let factLimit = 240
  /// 한 조각이 들 사실의 개수 상한.
  public static let factsPerEvidence = 3

  public init(
    source: Source,
    sourceID: String? = nil,
    title: String? = nil,
    facts: [String] = [],
    summary: String? = nil,
    timestamp: String? = nil
  ) {
    self.source = source
    self.sourceID = sourceID
    self.title = title
    // 상한은 **생성자가** 지킨다. 호출부가 지키게 두면 한 호출부가 빠진 날
    // 원문이 그대로 나간다.
    self.facts = facts
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .map { $0.count > Self.factLimit ? String($0.prefix(Self.factLimit)) + "…" : $0 }
      .prefix(Self.factsPerEvidence)
      .map { $0 }
    let trimmedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.summary = (trimmedSummary?.isEmpty ?? true) ? nil : trimmedSummary
    self.timestamp = timestamp?.isEmpty ?? true ? nil : timestamp
  }

  /// 모델 문맥의 **데이터 구획** 한 칸.
  ///
  /// 감싸는 자리는 여기 하나다 — 중간에서 감싸면 구획 표시가 겹쳐 들어간다.
  ///
  /// `includeIdentifier`는 최소 권한이다. 식별자의 쓸모는 **다음 단계의 인자**
  /// 하나뿐이고(`chat.read`의 채널, `memory.read`의 기록), 도구가 닫힌 단계에는
  /// 다음 단계가 없다. 그 단계에 식별자를 넘기던 동안 모델은 그것을 사실로 읽어
  /// 답에 적었다 — `"ID는 52C3E0B2-4A3A-…입니다."`(시뮬레이터 실측
  /// 2026-09-15 03:13). 지시로 막는 대신 **주지 않아서** 막는다.
  public func forModelContext(includeIdentifier: Bool = true) -> String {
    var lines: [String] = []
    if let title, !title.isEmpty { lines.append("title: \(title)") }
    if let timestamp { lines.append("at: \(timestamp)") }
    if includeIdentifier, let sourceID, !sourceID.isEmpty { lines.append("id: \(sourceID)") }
    if let summary { lines.append("summary: \(summary)") }
    for fact in facts { lines.append("- \(fact)") }
    return UntrustedText(origin: source.contextOrigin, lines.joined(separator: "\n"))
      .forModelContext(limit: Self.factLimit * (Self.factsPerEvidence + 2))
  }

  /// 사람이 읽을 한 줄. 합성이 없는 차례에서 화면이 세우는 근거다.
  public var displayLine: String {
    let head = title ?? summary ?? facts.first ?? ""
    guard let timestamp, !head.isEmpty else { return head }
    return "\(head) · \(timestamp)"
  }
}

/// 한 줄을 어떻게 줄일지. **모든 결과에 AI를 쓰지 않는다**(§15).
public enum EvidenceStrategy: String, Sendable, Hashable {
  /// 이미 구조화된 것. 일정·미리 알림·연락처·식별자.
  case passthrough
  /// 구조만 옮긴다. 짧은 본문은 그대로 사실 한 줄이 된다.
  case deterministicExtraction
  /// 자연어가 길다. 기기 모델이 뽑는다 — 메일·채팅·웹·문서.
  case localModelExtraction

  /// 이 줄에 맞는 전략.
  public static func resolve(
    for row: CapabilitySourceRow, source: Evidence.Source
  ) -> EvidenceStrategy {
    guard !row.body.isEmpty else { return .passthrough }
    guard source.isExternal || source == .content || source == .recording else {
      // 내 기록의 본문은 이미 우리 것이다. 길면 자르고, 모델을 부르지 않는다.
      return .deterministicExtraction
    }
    return row.body.count > Evidence.factLimit
      ? .localModelExtraction : .deterministicExtraction
  }
}
