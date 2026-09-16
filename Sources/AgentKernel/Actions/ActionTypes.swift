import Foundation

/// 행동 인자의 값. **자유 텍스트가 아니라 typed 값이다.**
///
/// 모델이 채우는 자리는 좁고 typed여야 한다는 이 저장소의 실측 결론을 그대로
/// 따른다 — 모델이 문장으로 지시를 쓰면 그 문장을 다시 해석하는 두 번째 판정이
/// 생기고, 그 판정이 오판의 자리가 된다.
public enum ActionValue: Sendable, Hashable, Codable {
  case text(String)
  case number(Double)
  case flag(Bool)
  case timestamp(Date)
  case list([ActionValue])

  public var textValue: String? {
    if case .text(let value) = self { return value }
    return nil
  }
  public var dateValue: Date? {
    if case .timestamp(let value) = self { return value }
    return nil
  }
  public var numberValue: Double? {
    if case .number(let value) = self { return value }
    return nil
  }
  public var flagValue: Bool? {
    if case .flag(let value) = self { return value }
    return nil
  }
  public var listValue: [ActionValue]? {
    if case .list(let value) = self { return value }
    return nil
  }
}

/// 실행 한 건. 어디서 왔고, 무엇을 하고, 같은 일이 두 번 실행되지 않게 하는
/// 열쇠가 무엇인지를 함께 든다.
public struct ActionRequest: Sendable, Identifiable, Hashable, Codable {
  /// Audit metadata only. Origin never grants execution authority.
  public enum Origin: String, Sendable, Codable {
    /// 사용자의 문장이 결정론 라우터에서 그대로 해석된 것.
    case userExplicit
    /// 모델이 계획으로 고른 것.
    case modelPlan
    /// 앱의 자동 처리(공유 수신·백그라운드 정리 등).
    case system
  }

  public let id: UUID
  public let capability: CapabilityID
  public let arguments: [String: ActionValue]
  /// 같은 열쇠의 실행은 **한 번만** 일어난다. 불확실한 전송을 재시도해서 두 번
  /// 보내지 않기 위한 유일한 장치다.
  public let idempotencyKey: String
  public let origin: Origin
  /// 이 요청이 속한 대화. 결과 수령증이 어느 대화에 실릴지를 정한다.
  public let conversationID: String?
  public let accountID: String
  public let requestedAt: Date
  public let turnID: UUID
  public let accountEpoch: UInt64
  public let policyVersion: Int
  public let binding: ConnectorBindingID?
  /// 이 실행의 **자격**. 없으면 되돌릴 수 없는 실행은 승인 문을 지난다(§7.4).
  /// `origin`은 감사 metadata이고 이 값이 권한이다 — 둘을 섞지 않는다.
  public let authorization: AuthorizationProof?
  /// 계획 시점에 관측한 대상의 revision. 실행 직전에 다시 확인해, 그 사이 바뀐
  /// 대상에 같은 동작을 하지 않는다(§PR5). 공급자가 revision을 주지 않으면 nil이고,
  /// 그 부재 자체는 기능 차단 사유가 아니다(§4.4).
  public let targetRevision: String?

  public init(
    id: UUID = UUID(),
    capability: CapabilityID,
    arguments: [String: ActionValue] = [:],
    idempotencyKey: String? = nil,
    origin: Origin,
    conversationID: String? = nil,
    accountID: String,
    requestedAt: Date = Date(),
    turnID: UUID? = nil,
    accountEpoch: UInt64 = AssistantAccountEpoch.current,
    policyVersion: Int = 1,
    binding: ConnectorBindingID? = nil,
    authorization: AuthorizationProof? = nil,
    targetRevision: String? = nil
  ) {
    self.id = id
    self.capability = capability
    self.arguments = arguments
    self.idempotencyKey = idempotencyKey ?? "\(capability.rawValue)#\(id.uuidString)"
    self.origin = origin
    self.conversationID = conversationID
    self.accountID = accountID
    self.requestedAt = requestedAt
    self.turnID = turnID ?? id
    self.accountEpoch = accountEpoch
    self.policyVersion = policyVersion
    self.binding = binding
    self.authorization = authorization
    self.targetRevision = targetRevision
  }

  public func with(origin: Origin) -> ActionRequest {
    ActionRequest(
      id: id, capability: capability, arguments: arguments, idempotencyKey: idempotencyKey,
      origin: origin, conversationID: conversationID, accountID: accountID,
      requestedAt: requestedAt, turnID: turnID, accountEpoch: accountEpoch,
      policyVersion: policyVersion, binding: binding, authorization: authorization,
      targetRevision: targetRevision)
  }

  /// 확인된 자격을 실은 같은 요청. 인자·열쇠·정체는 그대로다 — 자격은 무엇을
  /// 하는지를 바꾸지 않고, 그것을 할 수 있는지만 말한다.
  public func with(authorization: AuthorizationProof?) -> ActionRequest {
    ActionRequest(
      id: id, capability: capability, arguments: arguments, idempotencyKey: idempotencyKey,
      origin: origin, conversationID: conversationID, accountID: accountID,
      requestedAt: requestedAt, turnID: turnID, accountEpoch: accountEpoch,
      policyVersion: policyVersion, binding: binding, authorization: authorization,
      targetRevision: targetRevision)
  }

  /// 계약 검증을 지난 인자로 갈아 끼운 같은 요청.
  ///
  /// `id`와 멱등 열쇠를 **그대로** 들고 간다 — 검증은 요청을 새로 만드는 일이
  /// 아니라 같은 요청의 인자를 정리하는 일이고, 열쇠가 바뀌면 같은 전송이
  /// 두 번 나간다.
  public func with(arguments: [String: ActionValue]) -> ActionRequest {
    ActionRequest(
      id: id, capability: capability, arguments: arguments, idempotencyKey: idempotencyKey,
      origin: origin, conversationID: conversationID, accountID: accountID,
      requestedAt: requestedAt, turnID: turnID, accountEpoch: accountEpoch,
      policyVersion: policyVersion, binding: binding, authorization: authorization,
      targetRevision: targetRevision)
  }
}

/// 실제로 일어난 일의 **수령증**.
///
/// 모델이 "보냈습니다"라고 말한 것은 수령증이 아니다. 화면의 완료 표시는 이
/// 값에서만 나온다(`ActionOutcome.completed`).
public struct ActionReceipt: Sendable, Hashable, Codable {
  public let requestID: UUID
  public let capability: CapabilityID
  /// 어댑터가 돌려준 식별자 — 만든 일정의 id, 보낸 메일의 id, 발행한 공유 링크.
  public let externalID: String?
  /// 사람이 읽을 한 줄. 내부 사고 과정이 아니라 **관찰된 결과**다.
  public let summary: String
  /// 결과에 딸린 값. 검색 결과 개수, 만든 대상의 제목 등.
  public let details: [String: ActionValue]
  public let completedAt: Date
  public let sources: [SourceReference]
  public let coverage: [CoverageRecord]

  public init(
    requestID: UUID,
    capability: CapabilityID,
    externalID: String? = nil,
    summary: String,
    details: [String: ActionValue] = [:],
    completedAt: Date = Date(),
    sources: [SourceReference] = [], coverage: [CoverageRecord] = []
  ) {
    self.requestID = requestID
    self.capability = capability
    self.externalID = externalID
    self.summary = summary
    self.details = details
    self.completedAt = completedAt
    self.sources = sources
    self.coverage = coverage
  }
}

public enum ActionError: Error, Sendable, Hashable {
  /// 그 능력을 맡은 손이 없다(연결되지 않은 서비스, 꺼진 기능).
  case unsupported(CapabilityID)
  /// 권한이 없다. 사용자가 허용해야 진행된다.
  case notAuthorized(CapabilityID)
  /// 인자가 모자라거나 뜻이 둘 이상이다 — **임의 실행 금지**의 자리다.
  case ambiguous(reason: String)
  case invalidArguments(reason: String)
  /// 계정이 바뀌었다. 바뀐 계정으로 남의 일을 실행하지 않는다.
  case accountChanged
  case cancelled
  case failed(reason: String)
}

/// 실행 요청 하나의 관찰 가능한 상태. 사용자에게 보이는 것은 이 값뿐이다.
public enum ActionOutcome: Sendable, Hashable {
  case queued
  case routing
  case working(status: String)
  /// 실행 전에 사람의 한마디가 필요하다.
  case waitingApproval(ActionApprovalRequest)
  case completed(ActionReceipt)
  case failed(reason: String)
  case cancelled
}

/// 승인 문이 보여 주는 **구체적인 대상**(§12 PR 8).
///
/// 인자 이름을 그대로 나열하던 동안 사용자는 `to: a@b.com` 같은 줄을 읽었고,
/// 어느 계정에서 나가는지는 아무 데도 없었다. 같은 주소가 두 계정에 있으면
/// 그 허락은 무엇에 대한 허락인지 말할 수 없다(§4.4).
///
/// 값은 **자르지 않는다.** 사람이 허락할 대상을 앱이 줄여 보이면 그 허락은 다른
/// 것에 대한 허락이 된다.
public struct ActionApprovalPreview: Sendable, Hashable, Codable {
  /// 어느 공급자에서 나가는가(`google`·`slack`). 로컬 실행에서는 빈 값이다.
  public let provider: String
  /// 어느 계정·workspace인가. 없으면 빈 값이다.
  public let principal: String
  public let workspace: String
  /// 받는 사람·채널. 전송·답장의 **대상 그 자체**다.
  public let recipient: String
  /// 이어 붙는 자리(메일 thread, Slack thread ts).
  public let thread: String
  public let subject: String
  public let body: String
  public let attachmentCount: Int
  /// 위 칸에 담기지 않은 나머지 인자. 숨기지 않는다.
  public let extras: [String]

  public init(
    provider: String = "", principal: String = "", workspace: String = "",
    recipient: String = "", thread: String = "", subject: String = "", body: String = "",
    attachmentCount: Int = 0, extras: [String] = []
  ) {
    self.provider = provider
    self.principal = principal
    self.workspace = workspace
    self.recipient = recipient
    self.thread = thread
    self.subject = subject
    self.body = body
    self.attachmentCount = attachmentCount
    self.extras = extras
  }

  /// 연결 하나의 **사람이 읽는 이름**. 승인 문에는 이 값만 나간다.
  ///
  /// `ConnectorBindingID`의 `principalID`·`workspaceID`는 OAuth sub, Slack user_id,
  /// team_id 같은 불투명 값이다. 그 값을 화면에 내보내면 같은 공급자 계정이 둘일 때
  /// 사람이 어느 계정인지 구별할 수 없다 — 정확성 층의 식별자는 실행이 쓰고,
  /// 표현 층에는 이름만 준다(§2.7, §10.2).
  public struct BindingDisplay: Sendable, Hashable, Codable {
    public let account: String
    public let workspace: String

    public init(account: String, workspace: String = "") {
      self.account = account
      self.workspace = workspace
    }
  }

  /// 사람이 읽을 이름으로 내보내지 않는 인자 열쇠. 불투명 신원은 extras에도
  /// 올리지 않는다.
  static let opaqueArgumentKeys: Set<String> = [
    "principal", "principalID", "sub", "teamID", "team_id", "team", "userID",
    "user_id", "workspaceID", "workspace_id", "token", "accessToken", "cursor",
  ]

  /// 요청 하나에서 만든다. 대상 칸은 능력의 영역이 정한다 — 메일의 `to`와 채팅의
  /// `channel`은 같은 자리이고, 화면은 그 자리를 하나로 읽는다.
  ///
  /// `display`는 연결의 사람이 읽는 이름이다. 없으면 계정 칸을 **비운다** —
  /// 불투명 id로 채우지 않는다.
  public static func make(
    from request: ActionRequest, display: BindingDisplay? = nil
  ) -> ActionApprovalPreview {
    let arguments = request.arguments
    func text(_ keys: [String]) -> String {
      for key in keys {
        if let value = arguments[key]?.textValue,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          return value
        }
      }
      return ""
    }
    // 사람이 읽는 이름이 인자에 있으면 그것을 먼저 쓴다. 채널 id(`C…`)만 보여
    // 주면 사용자가 무엇에 허락하는지 알 수 없다.
    let recipientKeys = [
      "recipientName", "channelName", "to", "recipient", "channel", "channelID",
      "conversationID",
    ]
    let threadKeys = [
      "threadID", "threadId", "thread", "threadTS", "thread_ts", "messageID",
      "messageId", "ts",
    ]
    let subjectKeys = ["subject", "title"]
    let bodyKeys = ["body", "text", "message"]
    let consumed = Set(recipientKeys + threadKeys + subjectKeys + bodyKeys + ["provider"])
    let extras = arguments.keys.sorted().compactMap { key -> String? in
      guard !consumed.contains(key), !Self.opaqueArgumentKeys.contains(key) else {
        return nil
      }
      switch arguments[key] {
      case .text(let value):
        return value.isEmpty ? nil : "\(key): \(value)"
      case .number(let value): return "\(key): \(value)"
      case .flag(let value): return "\(key): \(value)"
      case .timestamp(let value):
        return "\(key): \(value.formatted(date: .abbreviated, time: .shortened))"
      case .list(let values): return values.isEmpty ? nil : "\(key): \(values.count)"
      case .none: return nil
      }
    }
    return ActionApprovalPreview(
      provider: request.binding?.provider.rawValue ?? "",
      principal: display?.account ?? "",
      workspace: display?.workspace ?? "",
      recipient: text(recipientKeys),
      thread: text(threadKeys),
      subject: text(subjectKeys),
      body: text(bodyKeys),
      attachmentCount: arguments["attachments"]?.listValue?.count ?? 0,
      extras: extras)
  }
}

/// 승인 문. **무엇을, 어디에, 무엇으로** 하는지 사람이 읽을 수 있게 담는다.
public struct ActionApprovalRequest: Sendable, Hashable, Identifiable {
  public let id: UUID
  public let request: ActionRequest
  public let title: String
  /// 승인 문이 보여 주는 대상. 화면이 문구를 입힌다 — 여기서 번역하지 않는다.
  public let preview: ActionApprovalPreview
  public let isIrreversible: Bool
  public let expiresAt: Date
  public let argumentFingerprint: String

  public init(
    id: UUID = UUID(), request: ActionRequest, title: String,
    preview: ActionApprovalPreview? = nil,
    isIrreversible: Bool, expiresAt: Date = Date().addingTimeInterval(300)
  ) {
    self.id = id
    self.request = request
    self.title = title
    self.preview = preview ?? ActionApprovalPreview.make(from: request)
    self.isIrreversible = isIrreversible
    self.expiresAt = expiresAt
    self.argumentFingerprint = ActionFingerprint.arguments(request.arguments)
  }
}
