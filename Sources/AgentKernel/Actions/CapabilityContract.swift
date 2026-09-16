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

  /// 이 능력이 돌려주는 줄이 **무엇인가.**
  ///
  /// 줄 하나가 곧 근거가 되는 능력이 대부분이다(메일 한 통·메시지 한 줄·페이지
  /// 하나). 그러나 검색 결과 목록은 다르다 — 그것은 답의 재료가 아니라 **다음
  /// 단계로 가는 손잡이**다. 공급자가 쓴 요약 한 줄이 답의 근거로 올라가면, 우리가
  /// 읽지도 않은 문장이 사용자에게 사실로 제시된다.
  public enum RowKind: String, Sendable, Hashable {
    /// 사용자 질문에 답할 재료. 근거가 된다.
    case evidence
    /// 다음 단계의 손잡이(주소·식별자). **근거가 되지 않는다.**
    case handle
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
  /// 이 능력의 줄이 근거인가 손잡이인가. 적지 않으면 근거다 — 툴 대부분이 그렇고,
  /// 손잡이는 선언해야 성립한다.
  public let rows: RowKind

  public init(
    _ capability: CapabilityID, required: [Argument] = [], optional: [Argument] = [],
    rows: RowKind = .evidence
  ) {
    self.capability = capability
    self.required = required
    self.optional = optional
    self.rows = rows
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

/// 등록된 툴 계약이 놓이는 자리.
///
/// 열쇠마다 마지막 등록이 이긴다 — 호스트가 코어의 기본 계약을 자기 것으로
/// 덮어쓸 수 있어야 한다(같은 능력을 다른 인자로 구현한 툴).
final class ContractRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var contracts: [CapabilityID: CapabilityContract]

  init(seed: [CapabilityContract]) {
    contracts = Dictionary(seed.map { ($0.capability, $0) }, uniquingKeysWith: { _, last in last })
  }

  func register(_ added: [CapabilityContract]) {
    lock.lock()
    for contract in added { contracts[contract.capability] = contract }
    lock.unlock()
  }

  func contract(for capability: CapabilityID) -> CapabilityContract? {
    lock.lock()
    defer { lock.unlock() }
    return contracts[capability]
  }

  func snapshot() -> [CapabilityID: CapabilityContract] {
    lock.lock()
    defer { lock.unlock() }
    return contracts
  }
}

extension CapabilityContract {
  /// 실행 가능한 툴의 계약 전부. **여기 없는 능력은 실행되지 않는다.**
  ///
  /// 공급자 이름이 없다는 점에 주의한다 — `mail.send`의 계약은 Gmail의 계약이
  /// 아니고 "메일을 보낸다"의 계약이다. 공급자별 칸(`provider`)은 어느 계정으로
  /// 갈지를 사용자가 지정한 경우에만 쓰이는 선택 칸이다.
  private static let registry = ContractRegistry(seed: coreShipped)

  /// 호스트가 자기 툴의 계약을 등록한다. 부팅에서 한 번 부른다
  /// (`AgentRuntimeConfiguration.apply()`가 대신 부른다).
  ///
  /// 등록하지 않은 툴은 손(`CapabilityHandler`)이 있어도 실행되지 않는다 —
  /// 계약 없는 인자는 검사할 수 없고, 검사하지 않은 인자를 공급자 API로
  /// 흘리는 것이 이 코어가 막는 일이다.
  public static func register(_ contracts: [CapabilityContract]) {
    registry.register(contracts)
  }

  /// 지금 등록된 계약. 호스트가 "손은 있는데 계약이 없는 툴"을 잡는 근거다.
  public static var registered: [CapabilityID: CapabilityContract] { registry.snapshot() }

  public static func contract(for capability: CapabilityID) -> CapabilityContract? {
    registry.contract(for: capability)
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

  /// 코어가 **직접 싣는 툴**의 계약. 메일·채팅·웹 커넥터는 이 저장소 안에 구현이
  /// 있으므로(`Connectors/`) 그 계약도 여기 있다.
  ///
  /// 호스트의 툴(기록·보관함·캘린더·연락처 등)은 **호스트가 등록한다**
  /// (`CapabilityContract.register`). 그 계약을 코어에 적어 두면 코어가 자기가
  /// 구현하지도 않은 툴의 인자 규칙을 소유하게 되고, 호스트가 툴을 하나 더
  /// 만들 때마다 코어를 고쳐야 한다.
  public static let coreShipped: [CapabilityContract] = [
    // MARK: 외부 서비스 (코어의 커넥터)
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
    // 쓸 글의 자리는 **메일과 같은 낱말**이다(`body`). 이름이 갈리면 앞 단계가 만든
    // 글이 이 자리로 흐르지 못한다 — `ResolvableArgument.body`가 자리 이름으로
    // 찾기 때문이다. 그 시절 `"요약해서 슬랙에 보내줘"`는 본문을 되물었다.
    CapabilityContract(
      .chatSend, required: [Argument("channelID"), Argument("body")],
      optional: providerChoice),
    CapabilityContract(
      .chatReply,
      required: [Argument("channelID"), Argument("threadTS"), Argument("body")],
      optional: providerChoice),

    // MARK: 웹
    // 날짜 자리는 메일 검색과 **같은 낱말**을 쓴다. `"최신"`을 물은 차례가 이 자리로
    // 좁혀지고, 그 창의 위 끝은 툴이 기기 시계에서 박는다(`WebSearchTool.window`).
    //
    // 줄은 **손잡이다.** 검색이 돌려주는 것은 주소 후보이고, 답의 근거는 그 주소를
    // 읽은 다음 단계에서 나온다 — 공급자가 쓴 스니펫이 근거로 올라가면 우리가 읽지
    // 않은 문장이 사용자에게 사실로 제시된다.
    CapabilityContract(
      .webSearch, required: [Argument("query")],
      optional: searchPaging + [Argument("site")]
        + [Argument("after", .timestamp), Argument("before", .timestamp)],
      rows: .handle),
    // 주소는 **사용자나 앞 단계의 검색 결과**에서만 온다. 모델이 주소를 지어낼
    // 자리를 만들지 않는다 — 지어낸 주소는 존재하지 않는 페이지이거나, 더 나쁘게는
    // 남의 사설망 주소다(`ContentFetchHostPolicy`).
    CapabilityContract(.webFetch, required: [Argument("url")]),
    CapabilityContract(.webRead, required: [Argument("url")]),
  ]
}
