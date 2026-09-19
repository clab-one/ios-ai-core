import AgentKernel
import Foundation

/// A value remains attached to the observation and owner that produced it, never just a string slot.
public struct BoundReference: Sendable {
  public let accountID: String
  public let accountEpoch: UInt64
  public let conversationID: String?
  public let producingRequestID: UUID
  public let capability: CapabilityID
  public let source: SourceReference?
  public let sourceID: String?
  public let resolvedAt: Date
  public let kind: ResolvableArgument
  public let value: ActionValue

  public func isValid(in context: TurnContextSnapshot) -> Bool {
    accountID == context.accountID && accountEpoch == context.accountEpoch
      && conversationID == context.conversationID
      && (source == nil || source?.accountID == context.accountID)
  }

  public func allows(_ consumer: CapabilityID) -> Bool {
    switch kind {
    case .to, .messageID, .threadID, .messageIDHeader: return consumer.domain == "mail"
    case .channelID, .threadTS: return consumer.domain == "chat"
    case .eventID: return consumer.domain == "calendar"
    case .reminderID: return consumer.domain == "reminders"
    case .photoID: return consumer.domain == "photos"
    case .itemID: return ["memory", "artifact", "content", "recording", "share"].contains(consumer.domain)
    case .url: return consumer.domain == "web" || consumer.domain == "content"
    // 옮길 원문도 같은 자리로 온다. 이 표를 요약만 열어 두면 번역 단계는
    // 원문을 받지 못해 매번 되묻는다.
    case .sourceText: return consumer == .textSummarize || consumer == .textTranslate
    // 만든 글은 **보내는 능력과 저장**이 받는다.
    //
    // 저장을 뺐던 이유는 "앞 단계의 요약을 몰래 기록으로 만들지 않는다"였다. 그
    // 전제가 틀렸다: 저장 단계는 **계획에 있어야** 돌고, 계획에 있다는 것은 이
    // 차례에서 그 실행이 승인됐다는 뜻이다. 막아 둔 동안 `"찾아서 메모로
    // 저장해줘"`는 읽고 줄인 뒤에 `"무엇을 저장할까요?"`를 물었다(G08).
    //
    // 계획에 있다는 것이 **사용자가 그 쓰기를 요청했다**는 증명은 아니다 — 그
    // 증명은 이 자리가 아니라 쓰기 의도를 따로 드는 문이 해야 한다. 여기서 막아도
    // 그 구멍은 닫히지 않고, 대신 정직한 저장이 불가능해진다.
    //
    // 저장할 글은 계획 시점에 **존재하지 않는다.** 그래서 모델이 미리 쓰게 하면
    // 읽지도 않은 내용이 기록이 된다.
    case .body:
      return ["mail", "chat", "memory"].contains(consumer.domain)
    }
  }
}

public struct ConversationAnchor: Sendable {
  public var references: [ResolvableArgument: BoundReference] = [:]
  public var readSources: [AutomationSource] = []
  public var updatedAt: Date
}

/// 이 차례에 **실제로 일어난 일**.
///
/// 새 DB를 만들지 않는다(§13). 내구성 있는 기록은 이미 `ActionLedger`가 디스크에
/// 들고 있고(바깥으로 나간 쓰기), 프로세스 안의 멱등은 `ActionDispatcher`가
/// 들고 있다. 이 값은 **한 차례의 수명** 동안만 사는 관찰 묶음이다 — 감독자에게
/// "무엇이 끝났고 무엇이 남았는가"를 보여 줄 목적 하나로 있다.
///
/// 원문은 담지 않는다. 담는 것은 수령증, 시도의 결과, 압축된 근거다.
public struct TurnExecutionLedger: Sendable {
  /// 시도 하나의 관찰. 실패도 남는다 — 감독자가 같은 실패를 또 계획하지 않게 하는
  /// 유일한 근거다.
  public struct Attempt: Sendable, Hashable {
    public let capability: CapabilityID
    public let succeeded: Bool
    /// 실패 사유 코드(`notAuthorized:mail`). 사용자 글이나 공급자 원문은 담지 않는다.
    public let reason: String
    /// 수령증이 실어 온 줄 수. 원문은 담지 않는다 — 세어 둔 수만 남는다.
    public let rowCount: Int
    /// 이 호출의 대상. **우리가 보낸 인자**에서 온다(`TurnRuntime.subject`).
    public let subject: String

    public init(
      capability: CapabilityID, succeeded: Bool, reason: String, rowCount: Int = 0,
      subject: String = ""
    ) {
      self.capability = capability
      self.succeeded = succeeded
      self.reason = reason
      self.rowCount = rowCount
      self.subject = subject
    }
  }

  public let requestID: UUID

  private(set) var receipts: [ActionReceipt] = []
  private(set) var attempts: [Attempt] = []
  private(set) var evidence: [Evidence] = []
  private(set) var coverage: [CoverageRecord] = []

  public init(requestID: UUID) {
    self.requestID = requestID
  }

  // MARK: 적기

  mutating func record(_ receipt: ActionReceipt, subject: String = "") {
    receipts.append(receipt)
    coverage.append(contentsOf: receipt.coverage)
    attempts.append(
      Attempt(
        capability: receipt.capability, succeeded: true, reason: "",
        rowCount: CapabilitySourceRow.rows(in: receipt.details).count,
        subject: subject))
  }

  mutating func record(
    failure capability: CapabilityID, reason: String, subject: String = "",
    coverage observation: CoverageRecord? = nil
  ) {
    if let observation { coverage.append(observation) }
    attempts.append(
      Attempt(
        capability: capability, succeeded: false, reason: reason, subject: subject))
  }

  /// 근거를 갈아 끼운다. 근거는 **누적이 아니라 재계산**이다 — 수령증 전체에서
  /// 다시 줄이면 중복 제거와 점수가 차례 전체에 걸쳐 한 번만 적용된다.
  mutating func replaceEvidence(_ compiled: [Evidence]) {
    evidence = compiled
  }

  // MARK: 읽기

  /// 성공한 능력. 감독자에게 보이는 `completed` 목록이다.
  public var completed: Set<CapabilityID> {
    Set(attempts.filter(\.succeeded).map(\.capability))
  }

  /// **이미 일어난 부작용.** 재계획이 이것을 다시 계획해도 런타임이 막는다(§12).
  public var completedWrites: Set<CapabilityID> {
    completed.filter { $0.executionClass == .localWrite || $0.executionClass == .remoteWrite }
  }

  /// 화면과 대화에 남을 단계 목록.
  public var steps: [ConversationTurnResult.Step] {
    attempts.map {
      ConversationTurnResult.Step(
        capability: $0.capability, succeeded: $0.succeeded, reason: $0.reason,
        rowCount: $0.rowCount, subject: $0.subject)
    }
  }

  public var hasReceipts: Bool { !receipts.isEmpty }

  /// 감독자 문맥의 `<<<completed>>>` 구획. **관찰된 것만** 적는다.
  public func completedDigest() -> String {
    guard !attempts.isEmpty else { return "" }
    return attempts
      .map { "\($0.capability.rawValue)=\($0.succeeded ? "ok" : $0.reason)" }
      .joined(separator: "\n")
  }
}
