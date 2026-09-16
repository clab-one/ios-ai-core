import AgentKernel
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

  /// 툴이 기기에서 쓸 모델. 주면 코어가 `text.summarize` 툴을 등록한다.
  ///
  /// 이 자리가 비면 "요약해서 보내줘"의 중간 단계가 없어지고, 계획은 그 자리에서
  /// 멈춘다 — 원문을 그대로 보내는 대체 경로를 만들지 않는다.
  public var onDeviceModel: (any OnDeviceTextModel)?

  /// 열쇠 없는 웹 검색. 주면 코어가 `web.search` 툴을 등록한다.
  ///
  /// **이 자리를 비워 두는 것이 기본이다.** 검색은 사용자의 문장을 공개 웹으로
  /// 내보내는 유일한 능력이고, 그 유출은 앱이 명시로 켜야 한다 — 코어가 기본으로
  /// 켜면 어떤 앱은 자기가 웹에 질의한다는 사실을 모른 채 배포된다.
  ///
  /// 켠 앱에는 `.standard`가 보통 답이다(`WebSearchBroker.standard`).
  public var webSearch: WebSearchBroker?

  /// 상태 문구. 낱말과 언어는 호스트의 것이다(`TurnCopy.Key.all`).
  public var copy: TurnCopy

  /// 차례 복구 상태의 저장소. 없으면 복구를 포기한다(`NoTurnRunStore`).
  public var turnRuns: (any TurnRunStore)?

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
    onDeviceModel: (any OnDeviceTextModel)? = nil,
    webSearch: WebSearchBroker? = nil,
    copy: TurnCopy = .keysAsText,
    turnRuns: (any TurnRunStore)? = nil,
    actionLedger: (any ActionLedger)? = nil,
    currentAccountID: @escaping @Sendable () -> String?,
    supervising: TurnSupervising? = nil,
    finalizing: TurnFinalizing? = nil,
    onEvent: @escaping @MainActor @Sendable (TurnEventEnvelope) -> Void = { _ in },
    onResult: @escaping @MainActor @Sendable (ConversationTurnResult) -> Void
  ) {
    self.host = host
    self.tools = tools
    self.memoryIndex = memoryIndex
    self.onDeviceModel = onDeviceModel
    self.webSearch = webSearch
    self.copy = copy
    self.turnRuns = turnRuns
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
///   → PCC 1회: 할 일 전부를 순서대로 담은 JSON
///   → 코어: 순차 실행(앞 결과로 다음 자리 채움 · 쓰기 앞 승인 · 원장 기록)
///   → PCC 1회: 회수한 사실로 최종 답
///   → 화면
/// ```
///
/// 실행 중에는 PCC를 부르지 않는다. 값이 모자라면 **계획 단계에서** 묻고, 그 답은
/// 다음 차례가 된다.
@available(iOS 26.0, *)
@MainActor
public final class AgentRuntime {
  /// 모든 부작용이 지나가는 문. 호스트가 툴을 더 등록할 때 쓴다.
  public let dispatcher: ActionDispatcher
  private let turns: TurnRuntime

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
    if let model = configuration.onDeviceModel {
      await dispatcher.register(SummarizeTool(model: model))
    }
    if let broker = configuration.webSearch {
      await dispatcher.register(WebSearchTool(broker: broker))
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
    let onEvent = configuration.onEvent
    let onResult = configuration.onResult
    self.turns = TurnRuntime(
      dispatcher: dispatcher,
      emit: { onEvent($0) },
      present: { onResult($0) },
      copy: configuration.copy,
      supervising: configuration.supervising,
      finalizing: configuration.finalizing,
      turnRuns: configuration.turnRuns)
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
