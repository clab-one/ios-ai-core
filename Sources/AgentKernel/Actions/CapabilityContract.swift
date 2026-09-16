import Foundation

/// 능력 하나가 받는 **인자의 계약**.
///
/// 일반 계획 모양(`text`·`target`·`when` 세 칸) 하나로 모든 능력을 태우려 하면
/// 어댑터가 실제로 필요한 값을 채울 수 없다 — `mail.reply`는 스레드와 헤더를
/// 요구하고 `calendar.update`는 식별자를 요구한다. 그 요구를 능력 **밖에서**
/// 선언해 두면 실행 전에 한 번 걸러낼 수 있고, 걸러낸 이유를 사용자에게
/// 되물을 수 있다(`needs`).
///
/// 계약은 두 가지를 한다:
///
/// 1. **모자란 값을 실행 전에 잡는다.** 어댑터까지 내려가 던진 오류는 이미
///    HTTP 왕복을 한 뒤이고, 되돌릴 수 없는 능력이라면 절반만 일어난 뒤다.
/// 2. **선언되지 않은 인자를 버린다.** 모델이나 라우터가 넣은 낯선 칸이
///    공급자 API 질의로 새는 길을 닫는다.
public struct CapabilityContract: Sendable, Hashable {
  /// 인자 한 칸이 담는 값의 종류.
  public enum ValueKind: String, Sendable, Hashable {
    case text
    case number
    case flag
    case timestamp
    /// 여러 값. 원소의 종류까지는 계약하지 않는다 — 목록을 받는 능력은 지금
    /// 없고, 생기면 그 능력이 자기 원소를 검사한다.
    case list

    func matches(_ value: ActionValue) -> Bool {
      switch (self, value) {
      case (.text, .text), (.number, .number), (.flag, .flag),
        (.timestamp, .timestamp), (.list, .list):
        return true
      default:
        return false
      }
    }
  }

  public struct Argument: Sendable, Hashable {
    public let key: String
    public let kind: ValueKind

    public init(_ key: String, _ kind: ValueKind = .text) {
      self.key = key
      self.kind = kind
    }
  }

  public let capability: CapabilityID
  /// 없으면 **실행하지 않는다.**
  public let required: [Argument]
  /// 있으면 쓰고, 없으면 어댑터의 기본값이 쓰인다.
  public let optional: [Argument]

  public init(
    _ capability: CapabilityID, required: [Argument] = [], optional: [Argument] = []
  ) {
    self.capability = capability
    self.required = required
    self.optional = optional
  }

  /// 계약 위반. 이유를 자리 이름으로 든다 — 화면이 "무엇이 모자란지"를 말할 수
  /// 있어야 되물음이 성립한다.
  public enum Violation: Error, Sendable, Hashable {
    /// 이 자리들이 비어 있다.
    case missing([String])
    /// 자리는 있지만 값의 종류가 다르다.
    case malformed(key: String, expected: ValueKind)
    /// 계약이 선언되지 않은 능력. **실행하지 않는다** — 계약 없는 능력은
    /// 검증 없이 부작용을 내는 능력이다.
    case unknownCapability(CapabilityID)

    /// 사람이 읽고 로그에 남길 한 줄. 값은 담지 않는다(자리 이름만).
    public var reason: String {
      switch self {
      case .missing(let keys): "missing:\(keys.sorted().joined(separator: ","))"
      case .malformed(let key, let expected): "malformed:\(key):\(expected.rawValue)"
      case .unknownCapability(let capability): "noContract:\(capability.rawValue)"
      }
    }

    /// 사용자에게 되물을 첫 자리. 여러 개가 모자라면 첫 자리부터 묻는다.
    public var missingKey: String? {
      switch self {
      case .missing(let keys): keys.sorted().first
      case .malformed(let key, _): key
      case .unknownCapability: nil
      }
    }
  }

  /// 인자를 **정규화**한다. 통과하면 선언된 자리만 남은 사전이 나온다.
  ///
  /// 빈 문자열은 없는 것으로 본다 — 모델이 "값 없음"을 빈 칸으로 표현하고
  /// (`@Guide(... empty when not needed)`), 그 빈 칸이 그대로 질의에 실리면
  /// 공급자는 전체 메일함을 돌려준다.
  public func normalize(
    _ arguments: [String: ActionValue]
  ) -> Result<[String: ActionValue], Violation> {
    var normalized: [String: ActionValue] = [:]
    var missing: [String] = []

    for argument in required {
      guard let value = Self.present(arguments[argument.key]) else {
        missing.append(argument.key)
        continue
      }
      guard argument.kind.matches(value) else {
        return .failure(.malformed(key: argument.key, expected: argument.kind))
      }
      normalized[argument.key] = value
    }
    guard missing.isEmpty else { return .failure(.missing(missing)) }

    for argument in optional {
      guard let value = Self.present(arguments[argument.key]) else { continue }
      guard argument.kind.matches(value) else {
        return .failure(.malformed(key: argument.key, expected: argument.kind))
      }
      normalized[argument.key] = value
    }
    return .success(normalized)
  }

  /// 비어 있지 않은 값만 값으로 본다.
  private static func present(_ value: ActionValue?) -> ActionValue? {
    guard let value else { return nil }
    switch value {
    case .text(let text):
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : .text(trimmed)
    case .list(let values):
      return values.isEmpty ? nil : .list(values)
    default:
      return value
    }
  }
}

extension CapabilityContract {
  /// 모든 능력의 계약. **여기 없는 능력은 실행되지 않는다.**
  ///
  /// 공급자 이름이 없다는 점에 주의한다 — `mail.send`의 계약은 Gmail의 계약이
  /// 아니고 "메일을 보낸다"의 계약이다. 공급자별 칸(`provider`)은 어느 계정으로
  /// 갈지를 사용자가 지정한 경우에만 쓰이는 선택 칸이다.
  public static let all: [CapabilityID: CapabilityContract] = Dictionary(
    uniqueKeysWithValues: declared.map { ($0.capability, $0) })

  public static func contract(for capability: CapabilityID) -> CapabilityContract? {
    all[capability]
  }

  /// 이 요청이 실행 가능한가. 통과하면 정규화된 인자를 돌려준다.
  public static func normalize(
    _ arguments: [String: ActionValue], for capability: CapabilityID
  ) -> Result<[String: ActionValue], Violation> {
    guard let contract = contract(for: capability) else {
      return .failure(.unknownCapability(capability))
    }
    return contract.normalize(arguments)
  }

  private static let searchPaging: [Argument] = [
    Argument("limit", .number), Argument("cursor"),
  ]
  private static let providerChoice: [Argument] = [Argument("provider")]

  private static let declared: [CapabilityContract] = [
    // MARK: 기존 JustSend 경로
    CapabilityContract(
      .memorySearch, required: [Argument("query")], optional: searchPaging),
    CapabilityContract(.memorySave, required: [Argument("text")]),
    CapabilityContract(.memoryRead, required: [Argument("itemID")]),
    CapabilityContract(
      .contentIngest, required: [Argument("url")], optional: [Argument("title")]),
    CapabilityContract(.contentRead, required: [Argument("itemID")]),
    CapabilityContract(.contentSummarize, required: [Argument("itemID")]),
    CapabilityContract(.recordingStart),
    CapabilityContract(.recordingStop),
    CapabilityContract(.recordingRead, required: [Argument("itemID")]),
    CapabilityContract(
      .artifactFind, required: [Argument("query")], optional: searchPaging),
    CapabilityContract(.artifactRead, required: [Argument("itemID")]),
    // 무엇을 공유할지 없으면 발행하지 않는다 — 앱이 최근 기록을 골라 공개하면
    // 그것은 사용자가 지시한 공개가 아니다.
    CapabilityContract(.sharePublish, required: [Argument("itemID")]),
    CapabilityContract(.shareRevoke, required: [Argument("itemID")]),

    // MARK: Apple 기본 앱
    CapabilityContract(
      .calendarSearch,
      optional: [
        Argument("query"), Argument("start", .timestamp), Argument("end", .timestamp),
      ]),
    CapabilityContract(
      .calendarCreate,
      required: [Argument("title"), Argument("start", .timestamp)],
      optional: [
        Argument("end", .timestamp), Argument("location"), Argument("notes"),
      ]),
    CapabilityContract(
      .calendarUpdate,
      required: [Argument("eventID")],
      optional: [
        Argument("title"), Argument("start", .timestamp), Argument("end", .timestamp),
        Argument("location"),
      ]),
    CapabilityContract(.calendarDelete, required: [Argument("eventID")]),
    CapabilityContract(
      .remindersSearch,
      optional: [Argument("query"), Argument("includeCompleted", .flag)]),
    CapabilityContract(
      .remindersCreate,
      required: [Argument("title")],
      optional: [
        Argument("due", .timestamp), Argument("hasClockTime", .flag), Argument("notes"),
      ]),
    // 제목만으로 하나가 확정되는 경우가 있어 식별자를 강제하지 않는다. 여럿이
    // 잡히면 어댑터가 `ambiguous`로 멈춘다(`AppleRemindersCapability.resolve`).
    CapabilityContract(
      .remindersUpdate,
      optional: [
        Argument("reminderID"), Argument("title"), Argument("due", .timestamp),
        Argument("notes"),
      ]),
    CapabilityContract(
      .remindersComplete, optional: [Argument("reminderID"), Argument("title")]),
    CapabilityContract(
      .remindersDelete, optional: [Argument("reminderID"), Argument("title")]),
    CapabilityContract(.peopleResolve, required: [Argument("name")]),
    CapabilityContract(.contactsRead, required: [Argument("name")]),
    CapabilityContract(
      .contactsCreate,
      required: [Argument("givenName")],
      optional: [
        Argument("familyName"), Argument("organization"), Argument("email"),
        Argument("phone"),
      ]),
    CapabilityContract(
      .contactsUpdate,
      required: [Argument("contactID")],
      optional: [Argument("organization"), Argument("email"), Argument("phone")]),

    // MARK: 외부 서비스
    CapabilityContract(
      .mailSearch, required: [Argument("query")],
      optional: searchPaging + providerChoice
        + [Argument("after", .timestamp), Argument("before", .timestamp)]),
    CapabilityContract(
      .mailRead, required: [Argument("messageID")], optional: providerChoice),
    CapabilityContract(
      .mailSend, required: [Argument("to"), Argument("body")],
      optional: [Argument("subject")] + providerChoice),
    // 답장은 스레드와 원문 헤더가 있어야 **대화에 붙는다.** 없으면 새 메일이
    // 되고, 받는 사람에게는 문맥 없는 메일 한 통이 도착한다.
    CapabilityContract(
      .mailReply,
      required: [
        Argument("to"), Argument("body"), Argument("threadID"),
        Argument("messageIDHeader"),
      ],
      optional: [Argument("subject")] + providerChoice),
    CapabilityContract(
      .chatSearch, required: [Argument("query")],
      optional: searchPaging + providerChoice
        + [Argument("after", .timestamp), Argument("before", .timestamp)]),
    CapabilityContract(
      .chatRead, required: [Argument("channelID")],
      optional: searchPaging + providerChoice + [Argument("threadTS")]),
    CapabilityContract(
      .chatSend, required: [Argument("channelID"), Argument("text")],
      optional: providerChoice),
    CapabilityContract(
      .chatReply,
      required: [Argument("channelID"), Argument("threadTS"), Argument("text")],
      optional: providerChoice),

    // MARK: 웹
    CapabilityContract(
      .webSearch, required: [Argument("query")],
      optional: searchPaging + [Argument("site")]),
    // 주소는 **사용자나 앞 단계의 검색 결과**에서만 온다. 모델이 주소를 지어낼
    // 자리를 만들지 않는다 — 지어낸 주소는 존재하지 않는 페이지이거나, 더 나쁘게는
    // 남의 사설망 주소다(`ContentFetchHostPolicy`).
    CapabilityContract(.webFetch, required: [Argument("url")]),
    CapabilityContract(.webRead, required: [Argument("url")]),
  ]
}
