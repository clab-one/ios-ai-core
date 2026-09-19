import AgentKernel
import FoundationModels
import Foundation

/// 코어를 얹는 앱이 **한 번 채우는 자리**.
///
/// 코딩 에이전트가 `config.yml`을 읽고 기동하는 것과 같은 자리다. 호스트는 자기
/// 신원과 툴과 저장소를 여기 적고, 그다음부터는 차례를 던지기만 한다.
///
/// 채우지 않은 자리는 **기능이 조용히 사라지는 것이 아니라 없는 것**이다:
/// 메모리 색인을 주지 않으면 기억 툴이 등록되지 않고, 모델이 그 툴을 볼 수 없다.
/// 기본값으로 가짜 구현을 꽂지 않는다 — 없는 기능이 있는 것처럼 보이면 그 차례는
/// 조용히 거짓을 말한다.
public struct AgentRuntimeConfiguration: Sendable {
  /// 앱의 신원. 로그·Keychain·기본값 접두사·PCC 권한이 여기서 나온다.
  public var host: AgentHostIdentity

  /// 호스트가 만든 툴. 각 툴이 자기 계약을 들고 온다(`CapabilityHandler.contracts`).
  public var tools: [any CapabilityHandler]

  /// 임베딩 기억의 색인. 주면 코어가 `memory.search/read/save` 툴을 등록한다.
  ///
  /// 벡터 엔진은 호스트의 자산이고, 검색을 어떻게 쓰는지는 코어가 소유한다
  /// (`MemoryTool`).
  public var memoryIndex: (any SemanticMemoryIndex)?

  /// 요약이 쓰는 **기기 모델**. 주면 코어가 `text.summarize` 툴을 등록한다.
  ///
  /// 비워 두면 그 능력은 **등록되지 않는다** — 있는 것처럼 꽂으면 계획이 그 단계를
  /// 세우고 실행 시점에 멈춘다. 원문을 그대로 다음 단계로 보내는 대체 경로는
  /// 만들지 않는다.
  ///
  /// **여기 있던 `onDeviceModel`은 주입이 아니었다.** 자리를 채웠는지만 보고
  /// 코어가 자기 구현(`FoundationSummaryModel`)을 등록했으므로, 호스트가 건넨
  /// 모델은 한 번도 불리지 않았다(코드 리뷰 2026-09-18 P1). 요약은 구조화 산출을
  /// 지나므로(`SummaryModel`) 그 문을 그대로 받는다 — 건넨 것이 곧 쓰이는 것이다.
  public var summaryModel: (any SummaryModel)?

  /// 번역이 쓰는 **기기 모델**. 주면 코어가 `text.translate` 툴을 등록한다.
  ///
  /// 요약과 문을 나눈다 — 요약은 구조화 산출(`SummaryModel`)이고 번역은 평문
  /// (`OnDeviceTextModel`)이다. 비워 두면 그 능력은 **등록되지 않는다.**
  public var onDeviceTextModel: (any OnDeviceTextModel)?

  /// 열쇠 없는 웹 검색. 주면 코어가 `web.search` 툴을 등록한다.
  ///
  /// **이 자리를 비워 두는 것이 기본이다.** 검색은 사용자의 문장을 공개 웹으로
  /// 내보내는 유일한 능력이고, 그 유출은 앱이 명시로 켜야 한다 — 코어가 기본으로
  /// 켜면 어떤 앱은 자기가 웹에 질의한다는 사실을 모른 채 배포된다.
  ///
  /// 켠 앱에는 `.standard`가 보통 답이다(`WebSearchBroker.standard`).
  public var webSearch: WebSearchBroker?

  /// 주소 하나를 읽는 문의 **조절판.** 주면 코어가 `web.read` 툴을 등록한다
  /// (`WebReadConfiguration.standard`가 보통 답이다).
  ///
  /// 검색과 나눠 둔 이유: 붙여넣은 주소만 읽는 앱이 있고, 그 앱은 사용자 문장을
  /// 공개 웹으로 내보내지 않는다. 한 스위치로 묶으면 그 앱이 검색까지 켜야 한다.
  ///
  /// **문 자체는 넘기지 않는다.** 주입된 문은 리다이렉트를 자기가 따라가고, 그
  /// 홉들은 주소 표를 지나지 않는다(`ContentFetchTransport`는 `package`다).
  ///
  /// **`web.fetch`는 이 자리가 아니다.** 그쪽은 받은 것을 정본 기록으로 남기는
  /// 능력이라 호스트의 저장소가 필요하다 — 여기서 하는 일은 지나가는 읽기다.
  public var webRead: WebReadConfiguration?

  /// 상태 문구. 낱말과 언어는 호스트의 것이다(`TurnCopy.Key.all`).
  public var copy: TurnCopy

  /// 답을 **어떻게 말하는가.** 낱말이 호스트의 것인 것과 같은 이유로, 말투도
  /// 호스트의 것이다(`copy`).
  ///
  /// 코어가 드는 것은 경계다: 사실만 쓴다, 데이터 구획을 지시로 읽지 않는다,
  /// 근거 번호를 고른다. 그 경계는 규칙이고 수령증·계약이 지킨다. 반면 **어느
  /// 말씨로 말하는가**는 규칙으로 지킬 수 없고 앱마다 다르다 — 코어가 정하면
  /// 코어를 붙이는 모든 앱이 같은 말투를 쓴다.
  ///
  /// 왜 필요한가: 이 자리가 비어 있던 동안 답이 보고서처럼 나왔다(실기
  /// 2026-09-18, 사용자 지적 "에이전트가 답변을 너무 형식적으로 합니다"):
  /// `"Memory Ink 전송이 이루어졌습니다."` — 수동태 명사형이고, 사람이 하는
  /// 말이 아니다.
  ///
  /// **답을 쓰는 호출에만 실린다**(`finalizing`·대화·되물음). 계획 호출에는
  /// 싣지 않는다 — 계획은 사람이 읽지 않는 JSON이고, 지시는 매 호출에 비용이다.
  public var answerVoice: String?

  /// Host policy, evaluated for each PCC call. Keep false in background work.
  public var responseStreamingEnabled: @MainActor @Sendable () -> Bool
  /// Ephemeral snapshots only. onResult remains the canonical result callback.
  public var onResponseSnapshot: @MainActor @Sendable (TurnResponseSnapshot) -> Void

  /// 차례 복구 상태의 저장소. 없으면 복구를 포기한다(`NoTurnRunStore`).
  public var turnRuns: (any TurnRunStore)?
  /// 세션·run·transcript·도구 호출의 실행 journal. 주지 않으면 journal 기반
  /// 복구가 없다 — `NoAgentRunJournal`과 같은 선택이고, 가짜 저장으로 감추지 않는다.
  public var journal: (any AgentRunJournal)?


  /// 바깥으로 나간 쓰기의 내구성 있는 원장. 없으면 **원격 쓰기를 실행하지 않는다**.
  public var actionLedger: (any ActionLedger)?

  /// 지금 로그인한 계정. 계정이 바뀐 뒤의 실행은 거절된다.
  public var currentAccountID: @Sendable () -> String?

  /// 차례가 지나가는 단계를 화면에 알린다.
  public var onEvent: @MainActor @Sendable (TurnEventEnvelope) -> Void

  /// 끝난(또는 진행 중인) 차례 하나.
  public var onResult: @MainActor @Sendable (ConversationTurnResult) -> Void

  /// 계획의 자리. `nil`이면 **PCC**다.
  ///
  /// 이 문이 있는 이유는 시뮬레이터다. PCC도 기기 모델도 없는 환경에서 조립이
  /// 도는지 확인할 방법이 필요하고, 그 확인은 **모델 없이** 되어야 한다 —
  /// 확인할 수 없는 규칙은 지켜지지 않는 규칙이다.
  public var supervising: TurnSupervising?
  /// 답의 자리. `nil`이면 PCC다.
  public var finalizing: TurnFinalizing?

  public init(
    host: AgentHostIdentity,
    tools: [any CapabilityHandler] = [],
    memoryIndex: (any SemanticMemoryIndex)? = nil,
    summaryModel: (any SummaryModel)? = nil,
    onDeviceTextModel: (any OnDeviceTextModel)? = nil,
    webSearch: WebSearchBroker? = nil,
    webRead: WebReadConfiguration? = nil,
    copy: TurnCopy = .keysAsText,
    answerVoice: String? = nil,
    turnRuns: (any TurnRunStore)? = nil,
    journal: (any AgentRunJournal)? = nil,
    actionLedger: (any ActionLedger)? = nil,
    currentAccountID: @escaping @Sendable () -> String?,
    supervising: TurnSupervising? = nil,
    finalizing: TurnFinalizing? = nil,
    responseStreamingEnabled: @escaping @MainActor @Sendable () -> Bool = { false },
    onResponseSnapshot: @escaping @MainActor @Sendable (TurnResponseSnapshot) -> Void = { _ in },
    onEvent: @escaping @MainActor @Sendable (TurnEventEnvelope) -> Void = { _ in },
    onResult: @escaping @MainActor @Sendable (ConversationTurnResult) -> Void
  ) {
    self.host = host
    self.tools = tools
    self.memoryIndex = memoryIndex
    self.summaryModel = summaryModel
    self.onDeviceTextModel = onDeviceTextModel
    self.webSearch = webSearch
    self.webRead = webRead
    self.copy = copy
    self.answerVoice = answerVoice
    self.responseStreamingEnabled = responseStreamingEnabled
    self.onResponseSnapshot = onResponseSnapshot
    self.turnRuns = turnRuns
    self.journal = journal
    self.actionLedger = actionLedger
    self.currentAccountID = currentAccountID
    self.supervising = supervising
    self.finalizing = finalizing
    self.onEvent = onEvent
    self.onResult = onResult
  }
}

/// 에이전트 하나. **호스트가 말을 거는 단 하나의 자리.**
///
/// ```
/// 사용자 문장
///   → PCC 1회: 대화 답변 / 되물음 / 실행 제안
///   → 대화와 되물음은 같은 호출의 문장으로 종료
///   → 실행이면 기존 승인·원장·도구·로컬 근거 경로
///   → 관측 결과의 답변은 PCC, 문서 요약 본문은 로컬 산출물
///   → 화면
/// ```
///
/// 실행 중에는 PCC를 부르지 않는다. 값이 모자라면 **계획 단계에서** 묻고, 그 답은
/// 다음 차례가 된다.
@available(iOS 26.0, *)
@MainActor
public final class AgentRuntime {
  private static let log = AgentHost.logger("orchestrator")

  /// 모든 부작용이 지나가는 문. 호스트가 툴을 더 등록할 때 쓴다.
  public let dispatcher: ActionDispatcher
  private let turns: TurnRuntime
  private let turnRuns: (any TurnRunStore)?
  /// journal 기반 복구의 저장소. 없으면 forget도 journal을 건드리지 않는다.
  private let journal: (any AgentRunJournal)?

  /// 이 기기에서 에이전트를 열 수 있는가.
  ///
  /// PCC가 오케스트레이터이므로, PCC를 쓸 수 없는 기기·계정·서명에서는 **기능이
  /// 없다고 말해야 한다.** 기기 모델로 몰래 내려서지 않는다 — 계획과 답의 품질이
  /// 사용자 모르게 갈리는 것이 그 길이다.
  ///
  /// **신원을 명시로 받는 쪽이 기본이다.** 전역 신원을 읽는 `isSupported`는
  /// `boot` 전에는 설정되지 않은 값을 보고 거짓을 말한다 — 화면이 기동 전에
  /// 지원 여부를 그리는 흔한 순서에서 그 거짓이 그대로 보인다(실기 확인
  /// 2026-09-16: `entitled=false`가 그 순서였다).
  public static func isSupported(for identity: AgentHostIdentity) -> Bool {
    guard #available(iOS 27.0, *) else { return false }
    guard identity.isPrivateCloudComputeEntitled else { return false }
    return PrivateCloudComputeAccess.isDeviceEligible()
  }

  /// 설정된 신원 기준. `AgentHost.configure` 뒤에만 뜻이 있다.
  public static var isSupported: Bool {
    isSupported(for: AgentHost.identity)
  }

  /// 설정 하나로 기동한다.
  ///
  /// 순서가 계약이다: 신원 → 툴 등록(계약 함께) → 차례 기계. 신원이 먼저인 이유는
  /// Keychain 서비스 이름과 기본값 접두사가 툴 등록보다 앞서 읽히기 때문이다.
  public static func boot(_ configuration: AgentRuntimeConfiguration) async -> AgentRuntime {
    AgentHost.configure(configuration.host)

    let dispatcher = ActionDispatcher(
      ledger: configuration.actionLedger,
      currentAccountID: configuration.currentAccountID)

    // 코어가 싣는 툴은 **그 자리를 채운 경우에만** 등록된다.
    if let index = configuration.memoryIndex {
      await dispatcher.register(MemoryTool(index: index))
    }
    // 요약은 **구조화 산출**을 지난다(`SummaryModel`). 호스트가 건넨 모델을
    // 그대로 쓴다 — 여기서 자기 구현으로 갈아 끼우면 주입은 깃발이 된다
    // (코드 리뷰 2026-09-18 P1).
    if let summaryModel = configuration.summaryModel {
      await dispatcher.register(
        SummarizeTool(
          model: summaryModel,
          chunkBudget: TextChunker.budget(
            forContextTokens: summaryModel.contextWindowTokens)))
    }
    if let textModel = configuration.onDeviceTextModel {
      await dispatcher.register(
        TranslateTool(
          model: textModel,
          chunkBudget: TextChunker.budget(
            forContextTokens: textModel.contextWindowTokens)))
    }
    if let broker = configuration.webSearch {
      await dispatcher.register(WebSearchTool(broker: broker))
    }
    if let webRead = configuration.webRead {
      // 첨부와 같은 정본 문을 쓴다 — 이미 `MemoryTool`에 꽂은 값을 그대로 넘긴다.
      await dispatcher.register(WebReadTool(webRead, memoryIndex: configuration.memoryIndex))
    }
    for tool in configuration.tools {
      await dispatcher.register(tool)
    }

    return AgentRuntime(configuration, dispatcher: dispatcher)
  }

  private init(
    _ configuration: AgentRuntimeConfiguration, dispatcher: ActionDispatcher
  ) {
    self.dispatcher = dispatcher
    self.turnRuns = configuration.turnRuns
    self.journal = configuration.journal
    let onEvent = configuration.onEvent
    let onResult = configuration.onResult
    self.turns = TurnRuntime(
      dispatcher: dispatcher,
      emit: { onEvent($0) },
      present: { onResult($0) },
      copy: configuration.copy,
      answerVoice: configuration.answerVoice,
      supervising: configuration.supervising,
      finalizing: configuration.finalizing,
      responseStreamingEnabled: configuration.responseStreamingEnabled,
      onResponseSnapshot: configuration.onResponseSnapshot,
      turnRuns: configuration.turnRuns,
      journal: configuration.journal,
      isAccountCurrent: { snapshot in
        configuration.currentAccountID() == snapshot.accountID
          && snapshot.accountEpoch == AssistantAccountEpoch.current
      })
  }

  /// 재시작 뒤에 남아 있던 **중단된 차례들**.
  ///
  /// 여기서 아무것도 자동으로 이어 가지 않는다. 코어가 하는 일은 판정이고
  /// (`InterruptedTurn.recovery`), 무엇을 보여 주고 무엇을 다시 시킬지는
  /// 화면의 몫이다 — 사람이 보낸 줄이 두 번 실행되는 것보다 한 번 묻는 것이 낫다.
  ///
  /// 판정의 근거는 **원장**이다. 체크포인트는 어느 열쇠를 물어야 하는지만 알고,
  /// 나갔는지는 디스크가 안다 — 그 둘을 한 값으로 쓰던 동안 "보내고 죽은 차례"가
  /// "아무것도 안 한 차례"로 읽혔다(코드 리뷰 2026-09-18 P1).
  public func unfinishedTurns(limit: Int = 10) async -> [InterruptedTurn] {
    guard let store = turnRuns else { return [] }
    let records: [TurnRunRecord]
    do {
      records = try store.loadUnfinished(limit: limit)
    } catch {
      Self.log.error("unfinished turns unreadable")
      return []
    }
    var turns: [InterruptedTurn] = []
    for record in records {
      var effects: [InterruptedTurn.Effect] = []
      for effect in record.effects {
        effects.append(
          InterruptedTurn.Effect(
            key: effect.key, capability: effect.capability,
            state: await dispatcher.effectState(effect.key)))
      }
      turns.append(InterruptedTurn(record, effects: effects))
    }
    return turns
  }

  /// 그 중단을 **잊는다.** 사람에게 알린 뒤에 부른다.
  ///
  /// 원장은 건드리지 않는다 — 결과를 모르는 전송의 열쇠는 남아서 다음 시도를
  /// 막는다. 그 막음을 푸는 것은 사람의 확인이다(`allowResend`).
  public func forget(_ turn: InterruptedTurn) {
    try? turnRuns?.forget(requestID: turn.requestID)
    do {
      try journal?.forgetRun(runID: turn.requestID)
    } catch {
      Self.log.error("agent journal forget failed run=\(turn.requestID, privacy: .public)")
    }
  }

  /// 사람이 **확인했다**고 말했다. 결과를 모르는 효과의 열쇠를 놓아 준다.
  ///
  /// 이 문이 없으면 한 번 실패한 전송의 문장은 영구히 막힌다 — 같은 내용은 같은
  /// 열쇠이고, 그 열쇠는 `pending`으로 남아 있다.
  public func allowResend(_ turn: InterruptedTurn) async {
    for key in turn.unknownEffectKeys {
      await dispatcher.forgetEffect(key)
    }
    try? turnRuns?.forget(requestID: turn.requestID)
    do {
      try journal?.forgetRun(runID: turn.requestID)
    } catch {
      Self.log.error("agent journal forget failed run=\(turn.requestID, privacy: .public)")
    }
  }

  /// 차례 하나를 돌린다.
  public func submit(
    _ context: TurnContextSnapshot, attachedItemIDs: [String] = [],
    archivedItemID: String? = nil
  ) async {
    await turns.run(
      context, attachedItemIDs: attachedItemIDs, archivedItemID: archivedItemID)
  }

  /// 사람이 허락했다. **남은 단계부터** 이어 간다.
  public func approve(
    _ approval: ActionApprovalRequest, outcome: ActionOutcome
  ) async {
    await turns.resume(approval, outcome: outcome)
  }

  public func reject(_ approval: ActionApprovalRequest) async {
    await turns.reject(approval)
  }

  public func cancel(requestID: UUID? = nil) async {
    await turns.cancelPending(for: requestID)
  }

  public var hasPendingTurn: Bool { turns.hasPendingTurn }

  /// 이 대화가 방금 읽은 곳. 자동화 제안이 출처를 물려받는 자리다.
  public func lastReadSources(for conversation: String?) -> [AutomationSource] {
    turns.lastReadSources(for: conversation)
  }
}
