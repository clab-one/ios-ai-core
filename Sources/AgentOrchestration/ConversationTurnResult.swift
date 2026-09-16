import AgentKernel
import Foundation

/// 대화 한 차례가 끝난 뒤 **남는 것**.
///
/// 진행 상태(`ConversationOrchestrator.Activity`)와 다르다. 진행 상태는 지나가는
/// 관찰이고, 이 값은 대화에 남는 내용이다 — 조수의 답, 가리키는 기록, 무엇을
/// 읽었는지의 영수증.
///
/// 화면 타입을 여기서 만들지 않는다. 이 값을 받아 `SessionCardPresentation`으로
/// 옮기는 일은 `StreamRuntime`이 한다 — 문구의 언어를 아는 것이 그쪽이고, 카드의
/// 수명을 소유하는 것도 그쪽이다.
public struct ConversationTurnResult: Sendable {
  public enum Phase: String, Sendable {
    case completed
    case partial
    case reconciling
    case cancelled
    case failed
    /// 되물어야 한다. 아무것도 실행하지 않았다.
    case awaitingUser
    /// 아직 돌고 있다. **끝난 단계는 그 자리에서 화면에 선다** — 차례 전체가
    /// 끝날 때까지 결과를 쥐고 있으면, 일정을 만든 뒤에도 사람은 빈 진행 줄만
    /// 보며 모델이 답을 쓰는 시간을 기다린다(사용자 지시 2026-09-15: 쪼개서
    /// 기다리지 않게). 이 상태는 저장하지 않는다 — 저장은 끝에 한 번이다.
    case working
  }

  /// 실행한 단계 하나의 관찰. 접힌 진행 로그가 이 목록으로 선다.
  public struct Step: Sendable, Hashable {
    public let capability: CapabilityID
    public let succeeded: Bool
    /// 실패 사유 코드(`notAuthorized:mail`). 사용자 글이나 공급자 원문은 담지 않는다.
    public let reason: String
    /// 이 단계가 **돌려준 줄 수**. 쓰기처럼 셀 것이 없는 단계는 0이다.
    ///
    /// 숫자만 담고 문구는 담지 않는다 — 화면이 언어를 알고, 여기서 번역하면
    /// 같은 사실이 진행 줄과 영수증에서 두 말을 한다.
    public let rowCount: Int
    /// 이 호출이 **무엇을 대상으로 했는가.** 질의어·제목·받는 사람처럼 사용자가
    /// 준 값이다.
    ///
    /// 이 값이 없던 동안 진행 줄은 영역 이름과 건수만 말했고(`캘린더 · 1건`),
    /// 사용자는 앱이 무엇을 불렀는지 볼 수 없었다(사용자 지적 2026-09-15:
    /// "실제 툴호출이 1 step done 부분에 보이지도 않는다").
    ///
    /// **내부 식별자는 담지 않는다** — 기록 id·메시지 id는 사실이 아니라 배선이다.
    public let subject: String
    /// 아직 **돌지 않은** 단계인가. 계획에는 있고 실행에는 없다.
    ///
    /// 승인 설계(Figma `P3 · Working · Expanded`·`P5 · Failed`)는 계획된 단계를
    /// 미리 세우고 하나씩 채운다. 실패한 차례의 뒤 단계도 사라지지 않고
    /// "실행 안 함"으로 남는다 — 사라지면 사용자는 앱이 무엇을 하려 했는지 모른다.
    public let pending: Bool

    public init(
      capability: CapabilityID, succeeded: Bool, reason: String, rowCount: Int = 0,
      subject: String = "", pending: Bool = false
    ) {
      self.capability = capability
      self.succeeded = succeeded
      self.reason = reason
      self.rowCount = rowCount
      self.subject = subject
      self.pending = pending
    }
  }

  public let requestID: UUID
  public let request: String
  public let phase: Phase
  /// 조수의 답 한 줄. 되물을 때는 되묻는 문장이 여기 온다.
  public let headline: String
  /// 뒷받침하는 항목. 세 줄을 넘기지 않는다.
  public let points: [String]
  /// 이 줄이 **정말 답인가.** 모델이 쓰지 못해 상태 문구로 물러난 차례는 false다.
  ///
  /// 채팅은 이 값이 false면 답의 자리를 세우지 않는다 — 기본 문구가 답으로 서면
  /// 전화번호를 물은 사람이 `찾은 내용이에요`를 답으로 읽는다(실기 2026-09-15).
  public let isSynthesizedAnswer: Bool
  public let references: [ToolResultReducer.Reference]
  public let readSources: [ToolResultReducer.ReadSource]
  /// 이 차례의 모델 처리가 **어디서** 일어났는가(§36).
  ///
  /// 저장된 값은 위치이고 `processedOnDevice`는 그 위치에서 계산된다. 둘을 따로
  /// 들면 한쪽만 갱신되는 날이 오고, 그날의 고지는 거짓말이다.
  public let processingLocation: ProcessingLocation
  /// 이 차례의 처리가 전부 기기 안에서 끝났는가.
  public var processedOnDevice: Bool { processingLocation.processedEntirelyOnDevice }
  /// 실행한 단계들의 관찰. 접힌 진행 로그가 이 목록으로 선다.
  public let steps: [Step]
  /// 이 차례가 **실제로 무엇을 했는가**의 수령증.
  ///
  /// 읽기는 참조(`references`)로 말하지만 쓰기는 말할 것이 다르다 — 무엇이
  /// 만들어졌고 어디로 나갔는가다. 그 사실은 수령증에만 있으므로 화면까지
  /// 들고 온다(`ActionLedgerEntry`는 `details`를 저장하지 않아 재시작 뒤에는
  /// 복원되지 않는다 — 이 차례 안에서만 서는 값이다).
  public let receipts: [ActionReceipt]
  public let telemetry: TurnTelemetry
  public let context: TurnContextSnapshot?
  public let answerAvailability: TurnAnswerAvailability
  public let effectCompletion: TurnEffectCompletion
  public let coverage: [CoverageRecord]

  public var status: TurnStatus {
    switch phase {
    case .working: .running
    case .completed: .completed
    case .partial: .partial
    case .reconciling: .reconciling
    case .cancelled: .cancelled
    case .failed: .failed
    case .awaitingUser: .awaitingUser
    }
  }

  public init(
    requestID: UUID,
    request: String,
    phase: Phase,
    headline: String,
    points: [String],
    isSynthesizedAnswer: Bool = false,
    references: [ToolResultReducer.Reference],
    readSources: [ToolResultReducer.ReadSource],
    processingLocation: ProcessingLocation,
    steps: [Step],
    receipts: [ActionReceipt] = [],
    telemetry: TurnTelemetry,
    context: TurnContextSnapshot? = nil,
    answerAvailability: TurnAnswerAvailability = .notRequired,
    effectCompletion: TurnEffectCompletion = .none,
    coverage: [CoverageRecord] = []
  ) {
    self.requestID = requestID
    self.request = request
    self.phase = phase
    self.headline = headline
    self.points = points
    self.isSynthesizedAnswer = isSynthesizedAnswer
    self.references = references
    self.readSources = readSources
    self.processingLocation = processingLocation
    self.steps = steps
    self.receipts = receipts
    self.telemetry = telemetry
    self.context = context
    self.answerAvailability = answerAvailability
    self.effectCompletion = effectCompletion
    self.coverage = coverage
  }
}

/// 끝난 차례를 **화면에 세우는 자리**.
///
/// 코어는 화면을 모른다. 결과 하나를 어디에 어떻게 그리는지는 호스트의 것이고,
/// 코어가 아는 것은 "끝났으니 받아라"뿐이다.
@MainActor
public protocol ConversationTurnPresenting: AnyObject {
  func presentConversationTurn(_ result: ConversationTurnResult)
}

/// 조립 순서가 만드는 한 칸.
///
/// 런타임은 대화 계층의 판정·실행을 받아야 하고(`conversationOwnsInput`), 대화
/// 계층은 결과를 남길 곳으로 런타임이 필요하다. 둘 중 하나가 먼저 서야 하므로
/// 뒤에 서는 쪽을 이 칸에 꽂는다.
///
/// 화면을 **약하게** 든다 — 강하게 들면 화면과 대화 계층이 서로를 붙잡아
/// 계정을 바꿀 때 둘 다 살아남는다.
@MainActor
public final class ConversationTurnSink {
  private weak var presenter: (any ConversationTurnPresenting)?

  public init() {}

  public func connect(_ presenter: any ConversationTurnPresenting) {
    self.presenter = presenter
  }

  public func deliver(_ result: ConversationTurnResult) {
    presenter?.presentConversationTurn(result)
  }
}
