import AgentKernel
import Foundation
import OSLog

/// 차례 하나의 **생명주기를 소유하는 자리**.
///
/// ```
/// 입력 → 규칙 스케치 → 능력 범위 → 감독자 ─┐
///                                          │
///        ┌─────────────────────────────────┘
///        ▼
///   능력 실행 → 수령증 → 지역 근거 압축 → 원장
///        │                                 │
///        └──── 더 할 일이 있으면 감독자 ◄──┘
///                      │
///                      ▼  없으면
///                 최종 답(도구 닫힘) → 대화
/// ```
///
/// 예전에는 이 전부가 `ConversationOrchestrator` 한 타입에 있었다. 그 타입은
/// 화면 상태(진행 줄·승인 문·자동화 제안)도 함께 들고 있었고, 감독 되돌이를
/// 얹으면 한 파일에서 두 가지 수명이 섞인다. 그래서 차례의 수명은 여기,
/// 화면의 수명은 그쪽에 둔다 — `ConversationOrchestrator`는 이제 facade다.
///
/// **실행 권한의 최종 소유자는 이 런타임이다**(§50). 감독자는 판단하고, 기기
/// 모델은 정리하고, 실행은 `ActionDispatcher`가 하고, 화면이 완료로 바뀌는
/// 근거는 수령증뿐이다.
@MainActor
public final class TurnRuntime {
  private static let log = AgentHost.logger("orchestrator")

  /// 찾은 페이지를 읽으려 **시도할 횟수.**
  ///
  /// 첫 후보가 우리를 거절하는 일이 실제로 일어나고(실기 2026-09-17 P01:
  /// `web.read.rejected`, 그 한 번으로 차례가 근거 0개로 닫혔다), 열린 페이지가
  /// 글을 한 줄도 주지 않는 일도 일어난다(실기 2026-09-18: `msn.com` 한 장을 읽고
  /// `"이더리움에 대한 정보를 찾을 수 없어요"`로 닫혔다 — 그 페이지의 글은
  /// 스크립트가 그린다). 셋이 상한이고, 몇 장을 읽을지는 **모인 사실이** 정한다
  /// (`researchFactFloor`).
  static let searchedPageReadLimit = 3

  /// 이만큼 모이면 **읽기를 멈춘다.** 사실 줄의 수다.
  ///
  /// 장 수로 멈추면 글 없는 한 장에 만족하고, 장 수를 못 박으면 이미 충분한
  /// 차례가 두 장을 더 읽는다. 한 조각이 드는 사실은 최대 셋이므로
  /// (`Evidence.factsPerEvidence`) 이 값은 **한 장으로는 닿지 않는 높이**다 —
  /// 재료가 좋은 페이지는 두 장에서 멈추고, 메뉴만 있는 페이지는 상한까지 간다.
  static let researchFactFloor = 4

  private let dispatcher: ActionDispatcher
  private let emitEvent: @MainActor (TurnEventEnvelope) -> Void
  private var eventSequence: UInt64 = 0
  private var activeRequestID: UUID?
  private let isAccountCurrent: @MainActor (TurnContextSnapshot) -> Bool
  private let present: @MainActor (ConversationTurnResult) -> Void
  /// 상태 문구. 낱말과 언어는 호스트의 것이고, 어느 문구인지는 코어가 정한다.
  private let copy: TurnCopy
  /// 답을 쓰는 호출에 실리는 **호스트의 말투**(`AgentRuntimeConfiguration.answerVoice`).
  /// 계획 호출에는 싣지 않는다.
  private let answerVoice: String?
  private let responseStreamingEnabled: @MainActor @Sendable () -> Bool
  private let onResponseSnapshot: @MainActor @Sendable (TurnResponseSnapshot) -> Void
  private var responseSequence: UInt64 = 0
  /// 효과가 나갔지만 원장에 못 박히지 않았다는 사유의 이름.
  /// `ActionReceipt.ledgerUnsettled`가 이 이름으로 차례에 들어온다.
  static let ledgerUnsettledReason = "effectCommittedLedgerUnsettled"
  /// **재조정으로 닫는 사유들**(소문자 비교). 디스크가 증명하지 못한 효과다.
  static let reconcilingReasons = ["sendoutcomeunknown", "effectcommittedledgerunsettled"]
  private let now: () -> Date
  /// 차례의 복구 상태. 없으면 복구 기록을 남기지 않는다(§9.1).
  private let turnRuns: (any TurnRunStore)?
  /// 실행 journal. 없으면 journal 기반 복구가 없다. 쓰기 실패는 차례를 죽이지 않는다.
  private let journal: (any AgentRunJournal)?
  /// run별 transcript sequence. `checkpointRevisions`와 같이 이 액터가 든다.
  private var journalSequences: [UUID: Int] = [:]
  private let originDeviceID: String
  /// 저장한 상태 판. 늦게 도착한 저장이 앞선 상태를 되돌리지 않게 한다.
  private var checkpointRevisions: [UUID: Int] = [:]

  /// 앞 차례가 가리킨 값. `"그 메일 읽고 정리해줘"`가 무엇을 가리키는지 아는
  /// 유일한 자리다 — 모델에게 물으면 모델은 메일 id를 **지어낸다.**
  ///
  /// 대화별로 나눠 든다. 하나로 들면 A에서 찾은 메일을 B에서 읽는다.
  private var anchors: [String: ConversationAnchor] = [:]
  /// 앞 차례가 **어디를 읽었는가.** `"이걸 매일 자동으로 해줘"`가 가리키는 값이다.

  private var referenceOwner: TurnContextSnapshot?
  /// 승인을 기다리며 멈춘 차례. 허락을 받으면 **남은 단계부터** 이어 간다.
  private var pendingTurn: TurnState?
  /// 지금 도는 차례의 일. **사람이 멈출 수 있으려면 붙잡고 있어야 한다.**
  private var runningWork: Task<Void, Never>?

  /// 감독자와 답 쓰는 자리. **기본값은 실제 모델**이고, 시험이 이 문으로 대역을
  /// 세운다 — 시뮬레이터에는 PCC도 기기 모델도 없어서 되돌이 규칙을 실제 모델로는
  /// 확인할 수 없다(§41·§48).
  private let supervising: TurnSupervising
  private let finalizing: TurnFinalizing

  public init(
    dispatcher: ActionDispatcher,
    emit: @escaping @MainActor (TurnEventEnvelope) -> Void,
    present: @escaping @MainActor (ConversationTurnResult) -> Void,
    copy: TurnCopy = .keysAsText,
    answerVoice: String? = nil,
    now: @escaping () -> Date = Date.init,
    supervising: TurnSupervising? = nil,
    finalizing: TurnFinalizing? = nil,
    responseStreamingEnabled: @escaping @MainActor @Sendable () -> Bool = { false },
    onResponseSnapshot: @escaping @MainActor @Sendable (TurnResponseSnapshot) -> Void = { _ in },
    /// 차례의 복구 상태 저장소(§9). 없으면 복구 기록을 남기지 않는다 — 조립이
    /// 정본 DB를 세울 수 없는 경우다.
    turnRuns: (any TurnRunStore)? = nil,
    /// 실행 journal. 없으면 journal 기반 복구가 없다.
    journal: (any AgentRunJournal)? = nil,
    originDeviceID: String = TurnRuntime.deviceIdentifier,
    isAccountCurrent: @escaping @MainActor (TurnContextSnapshot) -> Bool = {
      $0.accountEpoch == AssistantAccountEpoch.current
    }
  ) {
    self.dispatcher = dispatcher
    self.emitEvent = emit
    self.isAccountCurrent = isAccountCurrent
    self.present = present
    self.copy = copy
    self.answerVoice = answerVoice
    self.now = now
    self.turnRuns = turnRuns
    self.journal = journal
    self.originDeviceID = originDeviceID
    self.supervising = supervising ?? Self.liveSupervising
    self.finalizing = finalizing ?? Self.liveFinalizing
    self.responseStreamingEnabled = responseStreamingEnabled
    self.onResponseSnapshot = onResponseSnapshot
  }

  /// 이 기기. 다른 기기에 동기화된 기록이 실행 명령으로 소비되지 않도록 실행
  /// 소유 기기를 고정한다(§9.4).
  public nonisolated static var deviceIdentifier: String {
    if let existing = UserDefaults.standard.string(forKey: "turn.origin.device") {
      return existing
    }
    let created = UUID().uuidString
    UserDefaults.standard.set(created, forKey: "turn.origin.device")
    return created
  }

  /// 실제 감독자. PCC를 쓸 수 없는 기기에서는 **미지원 처분**을 돌려준다 —
  /// 기기 모델이 계획을 대신 쓰지 않는다.
  private static let liveSupervising: TurnSupervising = { request in
    guard #available(iOS 26.0, *) else {
      return .failed(
        disposition: .surfaceFailure,
        reason: ModelFailureClassifier.unsupportedReason,
        ModelInvocationTrail(outcome: TurnRuntime.unavailableReceipt(request.profile)))
    }
    switch await TurnSupervisor().decide(
      request.context, profile: request.profile,
      conversationID: request.conversationID, accountID: request.accountID)
    {
    case .success(let outcome):
      return .decided(outcome.decision, outcome.trail)
    case .failure(let failure):
      return .failed(
        disposition: failure.disposition, reason: failure.reason, failure.trail)
    }
  }

  private static let liveFinalizing: TurnFinalizing = { context, profile in
    guard #available(iOS 26.0, *) else {
      return FinalizationStep(
        answer: .unavailable(reason: ModelFailureClassifier.unsupportedReason),
        trail: ModelInvocationTrail(outcome: TurnRuntime.unavailableReceipt(profile)))
    }
    let outcome = await TurnFinalizer().finalize(context, profile: profile)
    return FinalizationStep(answer: outcome.answer, trail: outcome.trail)
  }

  /// 부르지 못한 호출의 영수증. **부르려 했다고 적지 않는다** — 부른 적이 없으면
  /// 처리 위치는 여전히 기기다(§36).
  private static func unavailableReceipt(
    _ profile: DynamicTurnProfile
  ) -> ModelInvocationReceipt {
    ModelInvocationReceipt(
      phase: profile.phase, requestedBackend: profile.modelTarget,
      resolvedBackend: .onDevice, pccAttempted: false, pccCompleted: false,
      onDeviceAttempted: false, onDeviceCompleted: false,
      fallbackReason: ModelFailureClassifier.unavailableReason,
      inputCharacters: 0, latencyMilliseconds: 0)
  }

  /// 물리 호출들의 영수증을 차례에 적는다.
  ///
  /// **버린 시도도 적는다.** 나간 호출은 문맥을 태웠고 요금을 냈다 — 세지 않으면
  /// `pccCalls`가 실제 요청 수보다 작아지고, 문맥 크기가 핵심 지표인 코어에서
  /// 그 오차는 지표 전체를 못 믿게 만든다.
  ///
  /// 대역 사유는 **가장 마지막에 말한 것**을 든다. 다시 내서 성공한 차례의 첫
  /// 실패도 일어난 일이므로 그 사유가 계측에 남는다.
  private func record(_ trail: ModelInvocationTrail, in state: inout TurnState) {
    for receipt in trail.all { state.usage.record(receipt) }
    state.telemetry.backend = trail.outcome.resolvedBackend.rawValue
    if let reason = trail.all.compactMap(\.fallbackReason).last {
      state.telemetry.fallbackReason = reason
    }
  }

  // MARK: 차례의 상태

  /// 한 차례가 들고 가는 전부. 승인 대기에서 멈췄다 이어 가려면 이 값이 살아
  /// 있어야 한다 — 예전에는 승인 뒤에 차례가 사라져 합성과 저장이 돌지 않았다.
  private struct TurnState: Sendable {
    public let requestID: UUID
    public let input: String
    public let conversation: String?
    public let account: String
    public let context: TurnContextSnapshot
    /// 사용자가 이 문장과 함께 건넨 기록. 손에 들려 준 대상이다(§24).
    public let attachedItemIDs: [String]
    /// 찾은 기록을 읽으라고 **한 번** 냈는가.
    public var recordReadApplied = false
    /// 그중 읽기를 낸 것. 첨부가 여럿이면 **모두** 읽는다 - 한 장만 읽고 답하면
    /// 나머지 장은 없는 것이 된다.
    public var attachmentReads: Set<String> = []
    /// 이 차례에 모델이 본 툴 집합. 실행 검증이 이 집합으로 자른다.
    ///
    /// 규칙이 만들던 **구제 단계**(`rescue`)는 없앴다 — 계획은 모델의 일이고,
    /// 규칙이 대신 세운 계획은 사용자가 말하지 않은 일을 한다.
    public var scope: CapabilityScope
    /// 이 되돌이가 실행할 남은 단계.
    public var steps: [PlannedStep] = []
    /// 계획이 약속한 **부작용**. 수령증이 없으면 그 차례는 끝난 것이 아니다.
    ///
    /// 이 값이 없던 동안, 모델이 `mail.send`를 계획에서 빼먹고도 답에
    /// `"보냈습니다"`를 썼다(실기 2026-09-16). 완료 표시는 수령증에서만 나온다.
    public var plannedWrites: Set<CapabilityID> = []
    /// 계획이 **스스로 페이지를 읽겠다고 했는가.**
    ///
    /// 이 값이 참이면 몇 장을 읽을지는 계획의 것이다. 거짓이면 검색만 하고 끝낸
    /// 계획이므로 런타임이 읽기를 메운다 — 그때 몇 장까지 갈지를 `researchFactFloor`
    /// 가 정한다.
    public var planReadsPages = false
    public var pendingApprovalID: UUID?
    /// 조사 전 알려진 누락값. 성공한 관찰이 없으면 조회 실패가 질문을 덮지 않는다.
    public var investigationNeeds: String?
    public var stepOrigin: ActionRequest.Origin = .modelPlan
    public var dialogue: DialogueResolution = .none
    public var ledger: TurnExecutionLedger
    public var evidence: EvidenceCompiler.Compiled = .empty
    public var usage = ModelUsageLog()
    public let extractionBudget = LocalExtractionBudget()
    /// 값 뽑기가 입장 줄에서 기다린 시간의 **차례 누적**. 영수증이 없는 목적이라
    /// 사용 기록에서 계산할 수 없다 — 여기서 더한다(§12 PR 6).
    public var extractionWaitMilliseconds = 0
    public var telemetry = TurnTelemetry()
    public var iteration = 0
    public var toolExecutions = 0
    public var lastProgressIteration = 0
    public var unsuccessfulToolExecutions = 0
    public let executionDeadline = ContinuousClock.now.advanced(by: TurnLimits.executionWindow)
    public var incomplete = false
    public var answerRequired = false
    public var startedAt: Date
    /// 의미 불변식을 이미 적용했는가. 한 번만 적용한다(§24).
    public var invariantApplied = false
    /// 요약 보정을 이미 한 번 냈는가. 한 차례에 한 번만 잇는다.
    public var summaryInvariantApplied = false
    /// 이 차례를 **결정론 문**이 잡았는가(`IntentGate.Route.reason`).
    ///
    /// 잡힌 차례의 줄은 답 그 자체다 — 기기 시각으로 만든 창을 달력에 물었고,
    /// 돌아온 일정이 곧 대답이다. 그래서 그 줄에는 질의 낱말 겹침 판정
    /// (`overlapping`)을 걸지 않는다: `"오늘 일정 뭐 있어?"`와 `"치과"`는 한
    /// 글자도 겹치지 않고, 겹침으로 거르면 찾은 일정이 사라진 자리에서 차례가
    /// 대화 모델을 부른다(실측 2026-09-19, 이 배선의 첫 시험).
    public var deterministicRoute: String?
    /// `web.read`를 **시도한** 주소. 거절당한 시도도 든다.
    ///
    /// `readURLs`와 나눠 둔다: 그쪽은 읽은 주소이고 이쪽은 부른 주소다. 하나로
    /// 접으면 거절당한 주소가 읽은 것으로 세어지거나, 다음 후보 선택에서 같은
    /// 주소가 다시 1위가 된다.
    public var attemptedURLs: Set<String> = []
    /// 찾은 페이지를 읽으라고 낸 횟수. 거절당한 시도도 센다.
    public var searchedPageReadAttempts = 0
    /// 차례를 **끝낸 사실들.** 마감·상한·문맥 초과·계약 거절.
    ///
    /// 문자열 한 칸에 덮어쓰지 않고 목록으로 드는 이유: 한 차례에 둘 이상 성립한다
    /// (마감에 걸린 차례가 약속한 쓰기도 못 했다). 마지막에 이 목록과 관측된
    /// 수령증에서 `completionReason`을 계산한다.
    public var terminations: [String] = []
    /// 감독을 PCC가 했는가. 답을 누가 써야 하는지의 근거다(§19).
    public var pccSupervised = false
    /// 이미 **똑같이** 실행한 호출. 열쇠는 능력 이름 + 인자 지문이다.
    ///
    /// 능력 이름만으로 세면 한 차례에서 채널이 다른 두 `chat.read`가 한 호출로
    /// 붕괴하고(두 번째가 첫 수령증을 돌려받는다), 제목이 다른 두
    /// `calendar.create`는 두 번째가 조용히 사라진다. 막아야 하는 것은 **같은
    /// 호출의 재실행**이고, 다른 인자의 호출은 다른 일이다.
    public var performed: Set<String> = []
    public var attemptedReads: Set<String> = []
    /// **함께 돌린 읽기의 결과.** 독립 읽기 여러 개를 동시에 보내고, 소비는
    /// 계획 순서대로 한다 — 병렬이 순서를 흔들면 같은 질문이 다른 답을 낸다.
    public var prefetchedReads: [String: ActionOutcome] = [:]
    /// 이 차례에 실제로 읽은 주소. URL 불변식이 **어느** 주소를 읽었는지 본다 —
    /// "아무 웹 읽기나 있으면 통과"는 모델이 딴 페이지를 성공적으로 읽은 경우에
    /// 속는다.
    public var readURLs: Set<String> = []
    /// 모델이 **안전 판정으로 거부했다.**
    ///
    /// 우회하지 않는다(§37) — 같은 내용을 어느 모델에도 다시 내지 않는다. 그러나
    /// 그 시점에 기기가 이미 읽어 둔 것은 사용자의 것이고, 차례를 빈손으로 닫을
    /// 이유가 아니다(실기 2026-09-17, iPhone: 원천징수영수증 요약이 `fallback
    /// guardrail`로 `하지 못했어요`가 됐다 — 1,886자를 이미 읽은 뒤였다).
    /// 이 표시가 서면 남은 일은 **기기 안에서만** 하고, 답 자리에는 거부를 말한다.
    public var safetyRefused = false

    /// 이 차례가 **바깥에 내려 한 효과들.** 원장 선점 전에 적고, 결과가 오면
    /// 고친다 — 재시작 뒤 복구가 물어야 할 열쇠가 이 값이다.
    var effects: [TurnEffectCheckpoint] = []
  }

  /// 단계를 다 돌고 난 결과.
  private enum DrainResult {
    case drained
    /// 사람의 한마디를 기다린다. 차례는 살아 있다.
    case suspended
    /// 더 갈 수 없다.
    case stopped(phase: ConversationTurnResult.Phase, needs: String?, reason: String?)
  }

  public var hasPendingTurn: Bool { pendingTurn != nil }

  /// 이 대화가 방금 읽은 곳. 자동화 제안이 출처를 물려받는 자리다.
  public func lastReadSources(for conversation: String?) -> [AutomationSource] {
    guard let owner = referenceOwner, isAccountCurrent(owner) else { return [] }
    return conversation.flatMap { anchors[$0]?.readSources } ?? []
  }

  /// 이 차례의 복구 상태를 남긴다. **성공했는지 돌려준다** — 원격 쓰기 직전의
  /// 저장이 실패하면 호출부가 실행을 멈춘다(fail closed, §12 PR5).
  ///
  /// 담는 것은 다시 세우기 위해 필요한 것뿐이다(§9.2). 모델 세션·원문·비밀은 담지
  /// 않는다.
  @discardableResult
  private func persistRun(
    _ state: TurnState,
    status: TurnRunRecord.Status,
    pendingStepIdentity: String? = nil,
    approvalFingerprint: String? = nil
  ) -> Bool {
    guard let turnRuns else { return true }
    let revision = (checkpointRevisions[state.requestID] ?? 0) + 1
    let pending =
      pendingStepIdentity.map { [$0] }
      ?? state.steps.map {
        ActionFingerprint.call($0.capability, $0.arguments, binding: $0.binding)
      }
    let record = TurnRunRecord(
      requestID: state.requestID.uuidString,
      accountID: state.account,
      conversationID: state.conversation,
      originDeviceID: originDeviceID,
      status: status,
      stateRevision: revision,
      input: state.input,
      historyCutoff: state.context.historyCutoff,
      pendingStepIdentities: pending,
      effects: state.effects,
      pendingApprovalFingerprint: approvalFingerprint,
      toolExecutions: state.toolExecutions,
      supervisorIterations: state.telemetry.supervisorIterations,
      pccCalls: state.telemetry.pccCalls,
      localExtractions: state.telemetry.localExtractions,
      createdAt: now(), updatedAt: now())
    do {
      try turnRuns.save(record)
      checkpointRevisions[state.requestID] = revision
      return true
    } catch {
      Self.log.error(
        "turn checkpoint failed request=\(state.requestID.uuidString, privacy: .public)")
      return false
    }
  }

  /// journal 쓰기는 차례를 죽이지 않는다 — 원격 쓰기 fail-closed는 persistRun이 맡는다.
  private func journalRun(_ state: TurnState, status: AgentRunRecord.Status) {
    guard let journal else { return }
    do {
      let sessionID = state.conversation ?? ""
      try journal.saveSession(
        AgentSessionRecord(sessionID: sessionID, accountID: state.account))
      try journal.saveRun(
        AgentRunRecord(
          runID: state.requestID.uuidString, sessionID: sessionID, accountID: state.account,
          accountEpoch: state.context.accountEpoch, status: status,
          transcriptRevision: checkpointRevisions[state.requestID] ?? 0))
    } catch {
      Self.log.error(
        "agent journal run failed request=\(state.requestID.uuidString, privacy: .public)")
    }
  }

  private func journalEntry(
    _ state: TurnState, role: AgentTranscriptEntry.Role, text: String, toolCallID: String? = nil
  ) {
    guard let journal else { return }
    let next = (journalSequences[state.requestID] ?? 0) + 1
    journalSequences[state.requestID] = next
    do {
      try journal.appendTranscript(
        AgentTranscriptEntry(
          runID: state.requestID.uuidString, sequence: next, role: role, text: text,
          toolCallID: toolCallID))
    } catch {
      Self.log.error(
        "agent journal transcript failed request=\(state.requestID.uuidString, privacy: .public)")
    }
  }

  private func journalInvocation(
    callID: String, _ state: TurnState, capability: CapabilityID, fingerprint: String,
    invocationState: ToolInvocationRecord.State, arguments: String, receipt: String? = nil,
    receiptID: String? = nil, effectKey: String? = nil
  ) {
    guard let journal else { return }
    do {
      try journal.saveToolInvocation(
        ToolInvocationRecord(
          callID: callID, runID: state.requestID.uuidString, capability: capability,
          fingerprint: fingerprint, state: invocationState, receiptID: receiptID,
          arguments: arguments, receipt: receipt, effectKey: effectKey))
    } catch {
      Self.log.error(
        "agent journal invocation failed request=\(state.requestID.uuidString, privacy: .public)")
    }
  }

  /// `ActionValue`는 Codable이므로 새 인코더를 만들지 않고 그대로 JSON으로 적는다.
  /// secret·토큰·credential은 영속 상태에 두지 않는다(설계 §영속 상태).
  private static func journalArguments(_ arguments: [String: ActionValue]) -> String {
    let filtered = arguments.filter { !Self.isSecretArgumentKey($0.key) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(filtered),
      let text = String(data: data, encoding: .utf8)
    else { return "" }
    return text
  }

  private static func isSecretArgumentKey(_ key: String) -> Bool {
    let folded = key.lowercased().filter { $0.isLetter || $0.isNumber }
    return folded.contains("token") || folded.contains("secret") || folded.contains("password")
      || folded.contains("credential") || folded.contains("authorization")
      || folded == "apikey" || folded == "bearer" || folded == "binding"
  }

  private static func journalReceiptJSON(_ receipt: ActionReceipt) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(receipt) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// 새 분기를 만들지 않는다. 화면 phase → 복구 status → journal status.
  private static func journalStatus(
    for phase: ConversationTurnResult.Phase
  ) -> AgentRunRecord.Status {
    AgentRunRecord.Status(rawValue: Self.runStatus(for: phase).rawValue) ?? .failed
  }


  private func emit(_ event: TurnEvent, _ state: TurnState) {
    eventSequence &+= 1
    emitEvent(TurnEventEnvelope(
      requestID: state.requestID, accountID: state.account,
      conversationID: state.conversation, accountEpoch: state.context.accountEpoch,
      sequence: eventSequence, event: event))
  }

  /// 툴의 진행을 이 차례의 사건으로 옮기는 손잡이.
  ///
  /// 차례의 신원만 미리 떠 둔다 — 진행은 툴의 작업 안에서 오고, 그 자리에서
  /// 차례의 상태를 붙잡고 있으면 그 상태가 바뀌는 동안 읽히게 된다.
  private func progressSink(for state: TurnState) -> ToolProgress.Sink {
    let requestID = state.requestID
    let account = state.account
    let conversation = state.conversation
    let epoch = state.context.accountEpoch
    return { [weak self] capability, done, total in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.eventSequence &+= 1
        self.emitEvent(
          TurnEventEnvelope(
            requestID: requestID, accountID: account, conversationID: conversation,
            accountEpoch: epoch, sequence: self.eventSequence,
            event: .toolProgress(capability, done: done, total: total)))
      }
    }
  }

  private func responseSink(for state: TurnState) -> ModelResponseStream.Sink? {
    guard responseStreamingEnabled() else { return nil }
    let context = state.context
    return { [weak self] text in
      guard let self, self.activeRequestID == context.requestID,
        self.isAccountCurrent(context), !Task.isCancelled
      else { return }
      self.responseSequence &+= 1
      self.onResponseSnapshot(TurnResponseSnapshot(
        requestID: context.requestID, accountID: context.accountID,
        conversationID: context.conversationID, sequence: self.responseSequence,
        text: text))
    }
  }

  private func scopedRecentMessages(_ state: TurnState) -> [ConversationMessage] {
    state.context.recentMessages.filter {
      $0.accountID == state.account && $0.conversationID == state.conversation
    }
  }

  private func eligible(_ state: TurnState) -> Bool {
    !Task.isCancelled && isAccountCurrent(state.context)
  }

  // MARK: 시작

  /// - Parameter archivedItemID: 이 제출이 **이미 보관함에 들어갔는가.** 외부
  ///   데이터(첨부·주소)는 정본 캡처가 저장한 뒤에 이 차례가 돈다
  ///   (`StreamRuntime.submitRecord`). 그때 저장 툴이 손에 남아 있으면 모델이
  ///   같은 것을 한 번 더 저장한다 — `"<주소> 기억해"` 한 번에 기록이 두 건
  ///   남는다.
  public func run(
    _ context: TurnContextSnapshot, attachedItemIDs: [String] = [],
    archivedItemID: String? = nil
  ) async {
    let input = context.input
    let requestID = context.requestID
    let conversation = context.conversationID
    let account = context.accountID
    let registered = context.registeredCapabilities
    guard activeRequestID == nil, pendingTurn == nil else {
      present(ConversationTurnResult(
        requestID: requestID, request: input, phase: .failed,
        headline: copy.failure(reason: "busy"), points: [],
        references: [], readSources: [], processingLocation: .entirelyOnDevice,
        steps: [], telemetry: TurnTelemetry(), context: context))
      return
    }
    guard isAccountCurrent(context), !Task.isCancelled else { return }
    if let owner = referenceOwner,
      owner.accountID != context.accountID || owner.accountEpoch != context.accountEpoch
    {
      anchors.removeAll()
    }
    referenceOwner = context
    activeRequestID = requestID
    defer { activeRequestID = nil }
    eventSequence = 0
    // **등록된 툴 전부를 모델에게 보여 준다.** 문장을 규칙으로 읽어 영역을
    // 좁히던 스케치(`IntentSketch`)는 없앴다 — 규칙이 잘못 읽은 순간 사용자가
    // 말한 일을 모델이 할 방법이 사라지고, 그 실패는 "모델이 못 했다"로 보인다.
    //
    // 이미 보관된 제출에 저장이 겹치는 것은 **가시성이 아니라 멱등**이 막는다:
    // 저장 호출의 열쇠는 정규화된 본문 지문이므로(`ActionFingerprint.call`) 같은
    // 글은 두 번째 호출에서 새 기록을 만들지 않는다.
    let scope = CapabilityScope.compile(registered: registered)

    var state = TurnState(
      requestID: requestID, input: input, conversation: conversation,
      account: account, context: context, attachedItemIDs: attachedItemIDs,
      scope: scope,
      ledger: TurnExecutionLedger(requestID: requestID), startedAt: now())
    emit(.analyzing, state)
    // 정본 사용자 차례와 실행 record를 잇는다. 여기서의 실패는 읽기를 막지 않는다 —
    // 막는 자리는 원격 쓰기 직전이다(§9.3).
    persistRun(state, status: .running)
    journalRun(state, status: .running)
    journalEntry(state, role: .user, text: state.input)
    state.telemetry.profile = "supervised"

    // **긴 입력은 PCC 문을 열지 않는다.** 정상 경로는 정본 캡처가 긴 내용을 기록으로
    // 바꾸고(`attachedItemIDs`) 기기가 읽어 근거로 만드는 것이다(§24). 그 경로가
    // 놓친 입력을 조용히 자르면 잘린 뒤의 지시가 사라지므로, 아무것도 하기 전에
    // 멈춘다 — 자르지 않고 거절한다.
    guard input.count <= PCCContextBudget.standard.requestCharacters else {
      let refusal = ContextCompilationError.requestTooLarge(
        actual: input.count, limit: PCCContextBudget.standard.requestCharacters)
      state.terminations.append(refusal.reason)
      await finish(state, phase: .failed, reason: refusal.reason)
      return
    }

    // A conversation-only host is valid. PCC, not a local intent classifier,
    // decides whether to answer, ask a question, or request an available tool.
    // **도는 차례는 멈출 수 있어야 한다.** `advance`를 자기 task에 담는 이유가
    // 그것이다: `cancelPending`이 그 task를 취소하면 `eligible(state)`를 보는
    // 모든 자리가 차례를 닫는다(§9). 담지 않았던 동안 화면의 **중지**는
    // 승인 대기만 멈췄고, 도는 차례는 그대로 끝까지 갔다 — 실기 2026-09-18
    // (iPhone 15 Pro): 중지를 누른 웹 검색 차례가 9.2초 뒤 답까지 썼다.
    let work = Task { await self.advance(state) }
    runningWork = work
    defer { runningWork = nil }
    await work.value
  }

  /// 승인을 받았다. **남은 단계부터** 이어 간다.
  public func resume(
    _ approval: ActionApprovalRequest, outcome: ActionOutcome
  ) async {
    guard var state = pendingTurn,
      approval.id == state.pendingApprovalID,
      approval.request.turnID == state.requestID,
      approval.request.accountID == state.account,
      approval.request.accountEpoch == state.context.accountEpoch
    else { return }
    guard activeRequestID == nil else { return }
    activeRequestID = state.requestID
    defer { activeRequestID = nil }
    pendingTurn = nil
    state.pendingApprovalID = nil
    let subject = Self.subject(of: approval.request.arguments)
    let resumeIdentity = ActionFingerprint.call(
      approval.request.capability, approval.request.arguments, binding: approval.request.binding)
    let resumeArguments = Self.journalArguments(approval.request.arguments)
    let resumeEffectKey =
      approval.request.capability.isRemoteWrite ? approval.request.effectIdentity : nil
    switch outcome {
    case .completed(let receipt):
      journalInvocation(
        callID: resumeIdentity, state, capability: approval.request.capability,
        fingerprint: resumeIdentity, invocationState: .authorized,
        arguments: resumeArguments, effectKey: resumeEffectKey)
      journalInvocation(
        callID: resumeIdentity, state, capability: approval.request.capability,
        fingerprint: resumeIdentity, invocationState: .completed,
        arguments: resumeArguments, receipt: Self.journalReceiptJSON(receipt),
        receiptID: receipt.requestID.uuidString, effectKey: resumeEffectKey)
      state.ledger.record(receipt, subject: subject)
      state.performed.insert(ActionFingerprint.call(approval.request.capability, approval.request.arguments, binding: approval.request.binding))
      state.toolExecutions += 1
      state.lastProgressIteration = state.iteration
      emit(.capabilityCompleted(approval.request.capability, receipt), state)
      await advance(state)
    case .cancelled:
      journalInvocation(
        callID: resumeIdentity, state, capability: approval.request.capability,
        fingerprint: resumeIdentity, invocationState: .failed,
        arguments: resumeArguments, effectKey: resumeEffectKey)
      state.ledger.record(
        failure: approval.request.capability, reason: "cancelled", subject: subject)
      await finish(state, phase: .failed, reason: "cancelled")
    default:
      journalInvocation(
        callID: resumeIdentity, state, capability: approval.request.capability,
        fingerprint: resumeIdentity, invocationState: .failed,
        arguments: resumeArguments, effectKey: resumeEffectKey)
      let reason = Self.name(outcome)
      state.ledger.record(
        failure: approval.request.capability, reason: reason, subject: subject)
      await finish(state, phase: .failed, reason: reason)
    }
  }

  /// 사람이 거절했다. 차례는 여기서 끝난다.
  public func reject(_ approval: ActionApprovalRequest) async {
    guard var state = pendingTurn,
      approval.id == state.pendingApprovalID,
      approval.request.turnID == state.requestID,
      approval.request.accountID == state.account,
      approval.request.accountEpoch == state.context.accountEpoch
    else { return }
    pendingTurn = nil
    journalRun(state, status: .cancelled)
    state.pendingApprovalID = nil
    state.ledger.record(
      failure: approval.request.capability, reason: "cancelled",
      subject: Self.subject(of: approval.request.arguments))
    await finish(state, phase: .failed, reason: "cancelled")
  }

  /// 사람이 멈췄다. **승인 대기도, 도는 차례도** 여기서 끝난다.
  ///
  /// 종료는 한 문으로만 지난다(`finish`) — 도는 차례는 task를 취소하고, 그
  /// 차례가 자기 자리에서 `eligible(state)`를 보고 스스로 닫는다. 여기서 결과를
  /// 따로 세우면 한 차례에 답이 두 줄 선다.
  public func cancelPending(for requestID: UUID? = nil) async {
    if let state = pendingTurn, requestID == nil || state.requestID == requestID {
      journalRun(state, status: .cancelled)
      pendingTurn = nil
      if let approvalID = state.pendingApprovalID { await dispatcher.reject(approvalID) }
      await finish(state, phase: .cancelled, reason: "cancelled")
      return
    }
    guard let work = runningWork,
      requestID == nil || activeRequestID == requestID
    else { return }
    work.cancel()
  }

  // MARK: 감독 되돌이

  /// `plan(PCC 1회) → execute → assemble`.
  ///
  /// **계획은 한 번이다.** PCC는 필요한 작업 전부를 순서대로 담은 JSON 하나를
  /// 던지고, 그다음부터는 코어가 혼자 돈다 — 앞 단계의 수령증에서 다음 단계의
  /// 자리를 채우고(`resolve`), 되돌릴 수 없는 실행 앞에서 승인을 받고, 끝나면
  /// 결과를 조립한다.
  ///
  /// 되돌이마다 PCC에 다시 묻던 구조(`reviewing`)는 없앴다. 그 구조는 한 차례에
  /// PCC를 2~6번 태웠고, 그 비용으로 얻는 것은 "충분한가"라는 되물음 하나였다.
  /// 값이 모자라면 **계획 단계에서** 물어야 한다(`ActionPlan.needs`) — 실행
  /// 중간에 알아내는 것이 아니라.
  ///
  /// 종료 조건은 명시적이다: 낼 단계가 없다, 실행 deadline, 실패 상한, 사용자
  /// 입력이 필요하다, 승인이 필요하다, 안전 거절.
  private func advance(_ initial: TurnState) async {
    var state = initial

    // 1) **손에 들려 준 기록은 계획보다 먼저 읽는다**(§24).
    //
    //    읽지 않은 첨부가 남아 있는 동안은 계획을 묻지 않는다. 모델은 방금
    //    저장된 기록을 볼 수 없으므로 물을 수밖에 없다 — 실기 2026-09-17
    //    (iPhone, 사용자 지적): 사진을 넣고 `"첨부한 내용을 읽고 알려줘"`를 보낸
    //    차례가 계획 한 번에 `needs`를 받아 `awaitingUser`("값이 하나 더
    //    필요해요")로 닫혔고, 방금 저장한 사진은 아무도 읽지 않았다
    //    (`pcc=1/1 rows=0`). 먼저 읽고, **근거를 들고** 계획을 묻는다.
    //
    //    첨부가 여럿이면 **모두** 읽고 나서 묻는다. 한 장만 읽고 계획을 물으면
    //    나머지 장은 그 계획에 없는 것이 된다.
    while state.steps.isEmpty, let injected = Self.attachedItemStep(state) {
      if let id = injected.arguments["itemID"]?.textValue {
        state.attachmentReads.insert(id)
      }
      state.steps = [injected]
      state.telemetry.interventionReason = "dependency:memory.read"
      switch await drain(&state) {
      case .suspended:
        pendingTurn = state
        return
      case .stopped(let phase, let needs, let reason):
        await finish(state, phase: phase, needs: needs, reason: reason)
        return
      case .drained:
        await compileEvidence(&state)
      }
    }

    // 1.5) **결정론으로 끝나는 차례는 계획을 묻지 않는다**(§Intent Gate).
    //
    //    `"다음 일정 뭐야?"`에 PCC 계획 호출을 쓰는 것은 이 런타임의 목표와
    //    반대다(설계 §결정). 문이 잡으면 단계는 기기 시각으로 만든 읽기 하나뿐이고,
    //    모델은 이 차례에서 한 번도 불리지 않는다. 문이 잡지 못하면 아무 일도
    //    일어나지 않는다 — 아래 계획 경로가 그대로 돈다.
    if state.steps.isEmpty, state.iteration == 0 {
      switch IntentGate.decide(
        input: state.input, scope: state.scope, now: state.context.referenceTime,
        calendar: state.context.calendar)
      {
      case .route(let routed):
        state.steps = routed.steps
        // 결정론 라우터가 사용자의 문장을 그대로 해석한 단계다(`Origin`의 정의).
        // 자격이 붙는 것은 아니다 — 이 문은 읽기 전용만 통과시킨다.
        state.stepOrigin = .userExplicit
        state.deterministicRoute = routed.reason
        state.telemetry.profile = "deterministic"
        state.telemetry.interventionReason = "gate:\(routed.reason)"
      case .escalate(let reason):
        // **승격에는 이유가 있다**(설계 §EscalationPolicy). 이 값이 비어 있는
        // PCC 차례는 사다리를 건너뛴 차례이고, 그것은 계측에서 버그로 읽는다.
        state.telemetry.escalationReason = reason
      }
    }

    // 2) 계획. 승인에서 돌아온 길은 이미 계획을 들고 있으므로 다시 묻지 않는다.
    if state.steps.isEmpty, state.iteration == 0 {
      switch await decide(&state) {
      case .work(let steps):
        state.steps = steps
        state.stepOrigin = .modelPlan
        // 완료 집합과 **같은 술어**로 센다. 한쪽만 넓으면 부작용이 아닌 단계가
        // 영원히 미이행으로 남는다(실기 2026-09-16: 요약이 그렇게 걸렸다).
        state.plannedWrites = Set(
          steps.map(\.capability).filter {
            $0.executionClass == .localWrite || $0.executionClass == .remoteWrite
          })
        state.planReadsPages = steps.contains { $0.capability == .webRead }
      case .complete:
        // **계획이 "할 일 없음"이라고 해서 손에 들려 준 대상이 사라지지 않는다.**
        //
        // 여기서 바로 조립으로 빠지던 동안, 주소를 주고 요약을 시킨 차례가 도구
        // 하나 없이 닫혔고 답은 `"요약은 제공된 내용에 포함되어 있지 않습니다"`였다
        // (실기 2026-09-19, 위키백과 URL + `"요약해줘"`: 같은 대화에서 그 주소를
        // 앞 차례에 읽었다는 문맥을 보고 감독자가 complete를 냈다). 아래 불변식
        // 고리를 그대로 지나게 둔다 — 메울 읽기가 없으면 고리는 첫 바퀴에 조립으로
        // 빠지므로, 할 일이 정말 없는 차례의 행동은 달라지지 않는다.
        //
        // **거부는 예외다.** 안전 판정으로 닫힌 차례에 보정을 잇는 것은 거부한
        // 내용을 다른 모델로 한 번 더 시도하는 일이다(§37) — 그 길은 열지 않는다.
        if state.safetyRefused { return await finalizeAndPresent(state) }
        break
      case .needsUser(let key):
        // PCC가 모자란 값을 말했다. **묻고 닫는다** — 사용자의 답은 다음 차례이고,
        // 그 차례의 계획은 답을 문맥으로 받아 완성된 JSON을 낸다.
        await finish(state, phase: .awaitingUser, needs: key)
        return
      case .stop(let reason):
        await finish(state, phase: .failed, reason: reason)
        return
      }
    }

    // 3) 순차 실행. 여기서 PCC를 부르지 않는다.
    while true {
      guard eligible(state) else {
        await finish(state, phase: .failed, reason: "cancelled")
        return
      }
      if !state.steps.isEmpty {
        switch await drain(&state) {
        case .suspended:
          pendingTurn = state
          return
        case .stopped(let phase, let needs, let reason):
          await finish(state, phase: phase, needs: needs, reason: reason)
          return
        case .drained:
          await compileEvidence(&state)
        }
      }

      // 4) 의미 불변식. **손에 들려 준 대상은 반드시 읽힌다**(§24) — 모델이
      //    엉뚱한 성공 계획을 냈다고 이 요구가 사라지지 않는다. 이 단계들은
      //    규칙이 만드는 계획이 아니라 **빠뜨린 읽기를 메우는 보정**이고, 모델을
      //    다시 부르지 않는다.
      //
      //    첨부는 위의 선행 읽기가 이미 본다. 여기 남겨 두는 이유는 승인에서
      //    이어 간 길이 그 선행 읽기를 지나지 않기 때문이다 — 그 길의 남은
      //    첨부는 이 자리에서 읽힌다.
      if let injected = Self.attachedItemStep(state) {
        if let id = injected.arguments["itemID"]?.textValue {
          state.attachmentReads.insert(id)
        }
        state.steps = [injected]
        state.telemetry.interventionReason = "dependency:memory.read"
        continue
      }

      if let injected = Self.urlInvariantStep(state) {
        state.invariantApplied = true
        state.steps = [injected]
        state.telemetry.interventionReason = "dependency:web.read"
        continue
      }

      //    그리고 **찾았으면 읽는다.** 기록 검색이 돌려주는 줄은 제목과 부제만
      //    들고 본문을 들지 않는다. 그 줄로 답을 쓰면 답은 문서의 내용이 아니라
      //    그 기록에 붙어 있던 자동 요약을 되읽은 문장이 된다 — 졸업증명서를 두고
      //    `"어느학교 졸업이지?"`라고 물었을 때 앱은 문서 맨 위의 문서확인번호를
      //    말했다(실기 재현 2026-09-15 03:12, `1 step done`: 찾기만 하고 읽지 않았다).
      if let injected = Self.recordReadStep(state) {
        state.recordReadApplied = true
        state.steps = [injected]
        state.telemetry.interventionReason = "dependency:memory.read"
        continue
      }

      //    웹도 같다. 검색 결과는 주소와 공급자가 쓴 한 줄이고, 그 줄로 답을 쓰면
      //    열어 보지 않은 페이지에 대해 답한 것이 된다(`searchedPageReadSteps`).
      let injected = await searchedPageReadSteps(&state)
      if !injected.isEmpty {
        state.searchedPageReadAttempts += injected.count
        state.steps = injected
        state.telemetry.interventionReason = "dependency:web.read"
        continue
      }

      //    읽었으면 **요약한다.** 사람이 요약을 말했는데 계획이 읽기에서 끝나면
      //    화면에 요약문이 서지 않는다(실기 2026-09-19).
      if let injected = Self.summaryInvariantStep(state) {
        state.summaryInvariantApplied = true
        state.steps = [injected]
        state.telemetry.interventionReason = "dependency:text.summarize"
        continue
      }

      guard ContinuousClock.now < state.executionDeadline else {
        state.terminations.append("deadline")
        state.incomplete = true
        break
      }
      guard state.unsuccessfulToolExecutions < TurnLimits.maxUnsuccessfulToolExecutions else {
        state.terminations.append("limit:tools")
        state.incomplete = true
        break
      }
      // 낼 단계가 없고 메울 읽기도 없다. 조립으로 간다.
      break
    }

    await finalizeAndPresent(state)
  }

  /// 감독자 한 번의 결과를 런타임의 낱말로.
  private enum Direction {
    case work([PlannedStep])
    case complete
    case needsUser(String)
    case stop(reason: String)
  }

  private func decide(_ state: inout TurnState) async -> Direction {
    // **회수한 근거가 있으면 이 호출은 관찰 뒤의 판단이다**(§11: observe → decide).
    //
    // 되돌이 번호로 갈랐던 동안, 첨부를 먼저 읽은 차례의 첫 호출이 `planning`으로
    // 나갔고 그 설정은 근거를 싣지 않는다 — 모델은 방금 읽은 사진을 보지 못한 채
    // "값이 하나 더 필요해요"로 되물었다(실기 2026-09-17, iPhone).
    let phase: TurnPhase = state.ledger.evidence.isEmpty ? .planning : .reviewing
    emit(phase == .planning ? .planning : .replanning, state)

    // **끝난 일을 범위에서 숨기지 않는다.**
    //
    // 숨겼던 동안 `"두 사람에게 각각 보내줘"`와 `"일정 두 개 만들어줘"`가 반만
    // 일어났다 — 첫 쓰기가 끝나자 그 능력이 사라져 두 번째를 계획할 수 없었다.
    // 중복을 막는 것은 범위가 아니라 호출의 정체다(`ActionFingerprint.call`): 같은 인자는
    // 같은 열쇠로 막히고, 다른 인자는 다른 일이다. 감독자는 무엇이 끝났는지를
    // `<<<completed>>>` 구획으로 본다.
    let scope = state.scope

    // 오케스트레이션은 **언제나 PCC**다. 예산으로 기기 모델에 내려서던 길
    // (`PCCBudget`)은 없앴다 — 사용자가 말한 일을 다른 품질로 몰래 처리하는
    // 길이었고, 그때 계측의 `backend` 칸도 갈라졌다.
    let profile = DynamicTurnProfile.supervising(
      phase: phase, target: .privateCloud, scope: scope)
    let context: CompiledConversationContext
    do {
      let compacted = try ConversationContextCompiler().compileWithCompaction(
        profile: profile,
        userMessage: state.input,
        recentTurns: scopedRecentMessages(state),
        evidence: state.ledger.evidence,
        coverage: state.ledger.coverage,
        anchoredSlots: anchoredSlots(state),
        heldRecords: state.context.heldRecords,
        knownFacts: state.context.knownFacts,
        completed: state.ledger.completedDigest(),
        voice: answerVoice,
        now: state.context.referenceTime,
        calendar: state.context.calendar)
      context = compacted.context
      state.telemetry.compactedEvidenceCount += compacted.droppedEvidenceCount
      // 이 단계가 실제로 실은 글자 수. 설계의 단계별 목표치와 대조하는 값이다.
      state.telemetry.record(
        contextCharacters: context.prompt.count, phase: profile.phase.rawValue)
    } catch {
      // **예산을 넘긴 문맥으로는 부르지 않는다.** 근거를 0개까지 줄여도 여전히
      // 넘쳤거나, 애초에 근거 문제가 아니었다(`requestTooLarge`/
      // `instructionsTooLarge`) — 그건 근거 압축으로 가릴 문제가 아니다.
      state.telemetry.fallbackReason = error.reason
      return .stop(reason: error.reason)
    }

    state.iteration += 1
    state.telemetry.supervisorIterations = state.iteration

    let request = SupervisorRequest(
      context: context, profile: profile, conversationID: state.conversation,
      accountID: state.account)
    let step = await ModelResponseStream.$sink.withValue(responseSink(for: state)) {
      await supervising(request)
    }
    guard eligible(state) else { return .stop(reason: "cancelled") }
    switch step {
    case .decided(let decision, let trail):
      record(trail, in: &state)
      if trail.outcome.pccCompleted { state.pccSupervised = true }
      switch decision.dialogue {
      case .none:
        break
      case .invalid(let reason):
        return .stop(reason: reason)
      case .reply(let text):
        guard !decision.hasWork, decision.plan.needs == nil else {
          return .stop(reason: DialogueResolution.invalidDecisionReason)
        }
        // Documents and device observations still go through the existing
        // evidence-backed finalizer. A conversational reply is not a receipt.
        if state.ledger.hasReceipts { return .complete }
        if let read = Self.urlInvariantStep(state) {
          state.invariantApplied = true
          return .work([read])
        }
        // **손에 든 자료를 읽지 않고 대화로 닫지 않는다.** 앞차례에 건넨 문서를
        // 두고 `"중요한 게 뭐야?"`라고 물은 차례가 `.reply`로 닫히면 그 답은
        // 문서를 본 적이 없다(제보 재현, REMAINING_WORK.ko.md P0). 주소를 주고
        // 읽지 않는 일을 막는 `urlInvariantStep`과 같은 자리이고 같은 근거다.
        if let read = Self.heldRecordStep(state) {
          if let id = read.arguments["itemID"]?.textValue {
            state.attachmentReads.insert(id)
          }
          state.telemetry.interventionReason = "dependency:memory.read"
          return .work([read])
        }
        state.dialogue = .reply(text)
        return .complete
      case .question(let key, let text):
        guard !decision.hasWork, decision.plan.needs == nil else {
          return .stop(reason: DialogueResolution.invalidDecisionReason)
        }
        state.dialogue = .question(key: key, text: text)
        return .needsUser(key)
      }
      if let needs = decision.plan.needs {
        let reads = investigationSteps(decision.plan.steps, in: state)
        if !reads.isEmpty {
          state.investigationNeeds = needs
          return .work(reads)
        }
        return .needsUser(needs)
      }
      guard decision.hasWork else {
        // **아무것도 실행하지 않은 차례를 모델의 말로 닫지 않는다**(§24).
        //
        // `.deep` 추론을 걸었던 실측에서 감독자가 318초를 생각한 뒤 단계 없이
        // `complete`를 냈고, 규칙이 답을 아는 요청이 빈손으로 끝났다. 회수한
        // 것이 하나도 없는데 끝났다고 말하면, 그것은 끝난 것이 아니다.
        if state.ledger.hasReceipts, decision.status == .complete { return .complete }
        return .complete
      }
      return .work(decision.plan.steps)
    case .failed(let disposition, let reason, let trail):
      record(trail, in: &state)
      state.telemetry.fallbackReason = reason
      switch disposition {
      case .surfaceFailure:
        // **안전 판정은 우회하지 않는다**(§37) — 같은 내용을 다른 모델에 다시
        // 내지 않는다. 그러나 그 시점에 기기가 이미 읽어 둔 것은 사용자의 것이고,
        // 차례를 빈손으로 닫을 이유가 아니다(실기 2026-09-17, iPhone: 원천징수
        // 영수증 요약이 `fallback guardrail`로 "하지 못했어요"가 됐다 — 1,886자를
        // 읽은 뒤였다). 남은 일은 **기기 안에서만** 하고, 답 자리에는 거부를 말한다.
        if ModelFailureClassifier.isSafetyJudgment(reason), !state.safetyRefused,
          state.ledger.hasReceipts
        {
          state.safetyRefused = true
          state.terminations.append(reason)
          // Preserve observations already obtained, but do not retry the
          // refused content with a local generative model.
          return .complete
        }
        return .stop(reason: reason)
      case .retry:
        // 감독자가 이미 같은 요청을 한 번 더 냈다. 그래도 답이 없으면 **사실을
        // 말한다** — 규칙이 만든 계획으로 갈아타지 않는다.
        if !state.ledger.hasReceipts, let needs = state.investigationNeeds {
          return .needsUser(needs)
        }
        return .stop(reason: reason)
      }
    }
  }

  /// 누락된 값이 다른 읽기를 막지 않는다. 쓰기는 명확해진 계획에서만 실행한다.
  private func investigationSteps(_ steps: [PlannedStep], in state: TurnState) -> [PlannedStep] {
    steps.compactMap { proposed in
      guard proposed.capability.executionClass == .readOnly,
        state.scope.contains(proposed.capability)
      else { return nil }
      var step = proposed
      guard let resolved = resolve(&step, in: state),
        case .success(let arguments) = CapabilityContract.normalize(resolved, for: step.capability)
      else { return nil }
      var binding = step.binding
      let bindings = binding == nil
        ? Self.connectorBindings(for: step.capability, arguments: arguments, in: state.context) : []
      if binding == nil, !bindings.isEmpty,
        step.capability != .mailSearch, step.capability != .chatSearch
      {
        guard let selected = selectedConnectorBinding(for: step.capability, arguments: arguments,
          candidates: bindings, in: state) else { return nil }
        binding = selected
      }
      if let binding {
        guard !state.attemptedReads.contains(ActionFingerprint.call(step.capability, arguments, binding: binding))
        else { return nil }
      } else {
        if bindings.isEmpty {
          guard !state.attemptedReads.contains(ActionFingerprint.call(step.capability, arguments))
          else { return nil }
        } else {
          guard bindings.contains(where: {
            !state.attemptedReads.contains(ActionFingerprint.call(step.capability, arguments, binding: $0))
          }) else { return nil }
        }
      }
      return PlannedStep(capability: step.capability, arguments: arguments, binding: binding)
    }
  }

  private func selectedConnectorBinding(
    for capability: CapabilityID, arguments: [String: ActionValue],
    candidates: [ConnectorBindingID], in state: TurnState
  ) -> ConnectorBindingID? {
    let remembered = state.conversation.flatMap { anchors[$0] }?.references.values
      .filter { $0.isValid(in: state.context) && $0.allows(capability) }
      .compactMap { $0.source } ?? []
    let sources = (state.ledger.receipts.flatMap { $0.sources } + remembered).filter {
      Self.matchesTarget($0, capability: capability, arguments: arguments)
    }
    let observed = Set(sources.compactMap { source -> ConnectorBindingID? in
      if case .connector(let binding) = source.binding { return binding }
      return nil
    })
    let binding = observed.count == 1 ? observed.first
      : (observed.isEmpty && candidates.count == 1 ? candidates.first : nil)
    guard let binding, candidates.contains(binding) else { return nil }
    return binding
  }

  /// 이 대상에 대해 **우리가 실제로 관측한** revision.
  ///
  /// 관측이 여럿이고 값이 갈리면 nil이다 — 어느 것이 지금인지 모르는 상태를
  /// 하나로 고르지 않는다. 공급자가 revision을 주지 않는 경우도 nil이고, 그때는
  /// Dispatcher가 재확인 없이 지나간다(§4.4).
  ///
  /// 여는 값은 `targetConsistency`다. `isIrreversible`로 여던 동안 수정은 대상을
  /// 다시 보지 않았다 — 승인 카드를 보는 사이 다른 앱이 고친 일정을 우리가
  /// 덮었다(코드 리뷰 2026-09-18 P1).
  private func observedTargetRevision(
    for capability: CapabilityID, arguments: [String: ActionValue], in state: TurnState
  ) -> String? {
    guard capability.targetConsistency == .revisionMustMatch else { return nil }
    let remembered = state.conversation.flatMap { anchors[$0] }?.references.values
      .filter { $0.isValid(in: state.context) }
      .compactMap { $0.source } ?? []
    let revisions = Set(
      (state.ledger.receipts.flatMap { $0.sources } + remembered)
        .filter { Self.matchesTarget($0, capability: capability, arguments: arguments) }
        .compactMap(\.revision))
    return revisions.count == 1 ? revisions.first : nil
  }

  private static func connectorBindings(
    for capability: CapabilityID, arguments: [String: ActionValue], in context: TurnContextSnapshot
  ) -> [ConnectorBindingID] {
    let provider = arguments["provider"]?.textValue
    return context.connectorReadiness.compactMap { snapshot in
      guard snapshot.capabilities.contains(capability),
        provider == nil || provider == snapshot.binding.provider.rawValue
      else { return nil }
      return snapshot.binding
    }
  }

  // MARK: 실행

  /// 한 번에 함께 보낼 **독립 읽기**의 상한. 넷으로 두는 이유: 공급자 두 곳과
  /// Apple 두 곳이 한 질문에 걸리는 것이 흔한 모양이고, 그보다 늘리면 기기의
  /// 네트워크·CPU를 한 차례가 독점한다.
  private static let readFanoutLimit = 4

  /// **앞의 독립 읽기들을 함께 보낸다**(§12 PR 4).
  ///
  /// 묶음에 들어가는 조건은 셋이다: 읽기 전용 실행 분류, 앞 단계 결과가 필요한
  /// 자리가 없음(`unresolved`가 빔), 그리고 어느 연결로 보낼지 이미 정해졌음.
  /// 쓰기·삭제와 선행 결과가 필요한 단계는 절대 들어가지 않는다 — 그것을 함께
  /// 보내면 아직 읽지 않은 값으로 메일을 보내는 일이 생긴다.
  ///
  /// 결과는 **계획 순서대로** 소비된다. 병렬은 기다리는 시간만 줄이고 순서와
  /// 병합 규칙은 바꾸지 않는다(§12 PR 4: 결정론 병합).
  private func prefetchIndependentReads(_ state: inout TurnState) async {
    guard state.prefetchedReads.isEmpty, state.steps.count > 1 else { return }
    var planned: [(identity: String, request: ActionRequest)] = []
    var seen: Set<String> = []

    for step in state.steps.prefix(Self.readFanoutLimit) {
      guard step.capability.executionClass == .readOnly, step.unresolved.isEmpty else { break }
      // 연결 후보가 여럿인 단계는 위 반복이 binding별로 쪼갠다. 쪼개기 전에
      // 보내면 어느 계정으로 물었는지 말할 수 없다.
      if step.binding == nil,
        !Self.connectorBindings(
          for: step.capability, arguments: step.arguments, in: state.context
        ).isEmpty
      {
        break
      }
      var copy = step
      guard var arguments = resolve(&copy, in: state) else { break }
      if case .success(let normalized) = CapabilityContract.normalize(
        arguments, for: step.capability)
      {
        arguments = normalized
      }
      let identity = ActionFingerprint.call(
        step.capability, arguments, binding: step.binding)
      guard !state.performed.contains(identity), !state.attemptedReads.contains(identity),
        seen.insert(identity).inserted
      else { continue }
      planned.append(
        (
          identity: identity,
          request: ActionRequest(
            capability: step.capability, arguments: arguments,
            idempotencyKey: "\(state.requestID.uuidString)#\(identity)",
            origin: state.stepOrigin,
            conversationID: state.conversation, accountID: state.account,
            turnID: state.requestID, accountEpoch: state.context.accountEpoch,
            binding: step.binding)
        ))
    }
    guard planned.count > 1 else { return }

    let dispatcher = dispatcher
    let outcomes = await withTaskGroup(of: (String, ActionOutcome).self) { group in
      for item in planned {
        group.addTask { (item.identity, await dispatcher.dispatch(item.request)) }
      }
      var collected: [String: ActionOutcome] = [:]
      for await (identity, outcome) in group { collected[identity] = outcome }
      return collected
    }
    state.prefetchedReads = outcomes
    state.telemetry.readFanout = max(state.telemetry.readFanout, planned.count)
  }

  /// 계획의 단계를 **순서대로** 돈다. 한 단계가 실패하면 뒤는 돌지 않는다 —
  /// 앞이 실패한 계획의 뒤 단계는 사용자가 의도한 일이 아니다.
  private func drain(_ state: inout TurnState) async -> DrainResult {
    while !state.steps.isEmpty {
      guard eligible(state) else {
        return .stopped(phase: .failed, needs: nil, reason: "cancelled")
      }
      // **독립 읽기는 함께 보낸다**(§12 PR 4). 쓰기와 앞 결과가 필요한 단계는
      // 이 묶음에 들어가지 않는다 — 소비는 아래 반복이 계획 순서대로 한다.
      await prefetchIndependentReads(&state)
      var step = state.steps.removeFirst()
      guard ContinuousClock.now < state.executionDeadline,
        state.unsuccessfulToolExecutions < TurnLimits.maxUnsuccessfulToolExecutions
      else {
        state.terminations.append("limit:tools")
        state.incomplete = true
        state.steps = []
        return .drained
      }
      guard var arguments = resolve(&step, in: state) else {
        // 채울 수 없는 자리를 **먼저 메운다.** 검색이 준 것은 손잡이이므로 원문
        // 자리를 채우지 못한다 — 찾은 페이지를 읽으면 채워진다. 이 보정이 없으면
        // `"찾아서 요약해줘"`가 검색을 성공한 뒤 `"무엇을 요약할까요?"`로 끝난다.
        //
        // 읽기를 **그 단계 앞에** 끼운다. 계획이 끝난 뒤에 메우면 요약과 저장이
        // 이미 지나간 자리이고, 그때 읽은 페이지는 아무 자리도 채우지 못한다.
        if step.unresolved.contains(ResolvableArgument.sourceText.rawValue),
          let injected = await searchedPageReadStep(&state)
        {
          state.searchedPageReadAttempts += 1
          state.steps.insert(contentsOf: [injected, step], at: 0)
          state.telemetry.interventionReason = "dependency:web.read"
          continue
        }
        // 원문 자리를 채울 **기록**이 대화에 있으면 그것을 읽는다. 사람이
        // `"요약해줘"`라고만 말했을 때 가리킨 것은 방금 보여 준 그 파일이고,
        // 그 식별자는 기기가 들고 있다(§24).
        if step.unresolved.contains(ResolvableArgument.sourceText.rawValue),
          let injected = Self.heldRecordStep(state)
        {
          if let id = injected.arguments["itemID"]?.textValue {
            state.attachmentReads.insert(id)
          }
          state.steps.insert(contentsOf: [injected, step], at: 0)
          state.telemetry.interventionReason = "dependency:memory.read"
          continue
        }
        // 그 밖의 빈 자리는 **되묻는다.** 규칙이 만든 다른 길로 갈아타지 않는다 —
        // 사용자가 말한 일과 다른 일을 하게 된다.
        return .stopped(
          phase: .awaitingUser, needs: step.unresolved.first ?? "value", reason: nil)
      }
      if step.binding == nil {
        let candidates = Self.connectorBindings(for: step.capability, arguments: arguments, in: state.context)
        if !candidates.isEmpty {
          if step.capability == .mailSearch || step.capability == .chatSearch {
            state.steps.insert(contentsOf: candidates.map {
              PlannedStep(capability: step.capability, arguments: arguments, binding: $0)
            }, at: 0)
            continue
          }
          guard let binding = selectedConnectorBinding(for: step.capability, arguments: arguments,
            candidates: candidates, in: state) else {
            return .stopped(phase: .awaitingUser, needs: "connectorBinding", reason: nil)
          }
          step = PlannedStep(capability: step.capability, arguments: arguments, binding: binding)
        }
      }
      // identity도 Dispatcher와 같은 정규화 값을 쓴다. invalid 요청은 Dispatcher가 설명한다.
      if case .success(let normalized) = CapabilityContract.normalize(arguments, for: step.capability) {
        arguments = normalized
      }
      // **같은 호출은 한 번만.**
      //
      // 열쇠에 되돌이 번호를 넣지 않는 이유: 넣으면 재계획이 같은 전송을 새
      // 열쇠로 만들어 두 번 보낸다(§12). 인자 지문을 넣는 이유: 넣지 않으면
      // 채널이 다른 두 읽기가 한 호출로 붕괴한다(리뷰 실측).
      let identity = ActionFingerprint.call(step.capability, arguments, binding: step.binding)
      // 이미 똑같이 실행했다. 다시 보내지도, 원장에 두 줄을 남기지도 않는다 —
      // 구제와 재계획이 방금 만든 미리 알림을 한 번 더 만들던 자리다.
      if state.performed.contains(identity) || state.attemptedReads.contains(identity) { continue }
      if step.capability.executionClass == .readOnly { state.attemptedReads.insert(identity) }
      // **자격은 이 자리에서만 붙는다.** 사용자의 문장을 결정론 라우터가 대상·내용
      // 그대로 해석한 단계에만 `userInstruction` 자격을 싣는다(§7.4). 모델이 고른
      // 단계는 자격이 없으므로 되돌릴 수 없는 실행이면 승인 문을 지난다 — 구제가
      // 한 번 돌았다고 그 뒤의 모델 단계가 사용자 권한을 물려받지 않는다.
      var request = ActionRequest(
        capability: step.capability, arguments: arguments,
        idempotencyKey: "\(state.requestID.uuidString)#\(identity)",
        origin: state.stepOrigin,
        conversationID: state.conversation, accountID: state.account,
        turnID: state.requestID, accountEpoch: state.context.accountEpoch,
        binding: step.binding,
        // 계획 시점에 관측한 대상의 revision. Dispatcher가 효과 직전에 다시 본다.
        targetRevision: observedTargetRevision(
          for: step.capability, arguments: arguments, in: state))
      // **자격의 문도 권한에서 나온다.** 여기 있던 `isIrreversible`은 사람이
      // 명시한 일정 생성에 자격을 싣지 않았고(되돌릴 수 있으니), 그래서 그
      // 단계는 승인 문을 한 번 더 지났다 — 경계는 하나여야 한다.
      if state.stepOrigin == .userExplicit, step.capability.requiresAuthorization {
        request = request.with(
          authorization: AuthorizationProof.issue(for: request, source: .userInstruction))
      }
      state.toolExecutions += 1
      emit(.capabilityStarted(step.capability), state)
      // **바깥으로 나가는 쓰기는 기록 없이 나가지 않는다.** 복구 기록을 남길 수
      // 없으면 실행하지 않는다 — 기록 없이 보낸 전송은 다음 재시도에서 두 번째
      // 전송이 된다(§12 PR5 fail closed).
      //
      // 적는 것은 **효과의 정체**다(`effectIdentity`). 차례의 id로 적으면 재시작
      // 뒤의 재전송이 다른 열쇠가 되고, 그 열쇠로는 원장에게 "이미 나갔는가"를
      // 물을 수 없다(코드 리뷰 2026-09-18 P1).
      if step.capability.isRemoteWrite {
        let key = request.effectIdentity
        state.effects.removeAll { $0.key == key }
        state.effects.append(
          TurnEffectCheckpoint(key: key, capability: step.capability, state: .prepared))
        guard persistRun(state, status: .running, pendingStepIdentity: identity) else {
          state.effects.removeAll { $0.key == key }
          state.toolExecutions -= 1
          return .stopped(phase: .failed, needs: nil, reason: "checkpointUnavailable")
        }
      }
      // **시도한 주소를 적는다.** 성공만 적으면 거절당한 주소가 다음 후보 선택에서
      // 다시 1위가 되고, 같은 인자의 재주입은 지문 중복으로 걸러져 차례는 아무것도
      // 읽지 못한 채 끝난다(실기 2026-09-17 P01 `web.read.rejected`).
      //
      // `readURLs`와 나눠 두는 이유: 그 값은 "그 주소를 **읽었는가**"이고, 실패한
      // 시도를 거기에 넣으면 사용자가 준 주소를 못 읽은 차례가 읽은 것으로 통과한다.
      if step.capability == .webRead || step.capability == .webFetch,
        let url = arguments["url"]?.textValue
      {
        state.attemptedURLs.insert(url)
      }
      // 함께 보낸 읽기의 결과가 이미 있으면 그것을 쓴다. 없으면 지금 보낸다.
      //
      // 보내는 동안 **툴의 진행을 화면으로 흘린다**(`ToolProgress`). 조각마다 기기
      // 모델을 부르는 요약은 한 단계가 수십 초를 쓰고, 그 동안 아무것도 서지
      // 않으면 사람은 멈춘 것과 구별할 수 없다(실기 2026-09-17: 131초).
      // prefetch 결과를 쓰는 경로도 실행된 사실이므로 같은 줄을 남긴다.
      let encodedArguments = Self.journalArguments(arguments)
      let effectKey = step.capability.isRemoteWrite ? request.effectIdentity : nil
      journalInvocation(
        callID: identity, state, capability: step.capability, fingerprint: identity,
        invocationState: .running, arguments: encodedArguments, effectKey: effectKey)
      let outcome: ActionOutcome
      if let prefetched = state.prefetchedReads.removeValue(forKey: identity) {
        outcome = prefetched
      } else {
        outcome = await ToolProgress.withSink(progressSink(for: state)) {
          await dispatcher.dispatch(request)
        }
      }
      switch outcome {
      case .completed(let receipt):
        // **무엇을 불렀는지 화면이 말할 수 있게 한다.** 대상은 우리가 보낸
        // 인자에서 온다 — 어댑터가 무엇을 담았는지와 무관한 사실이다.
        state.ledger.record(receipt, subject: Self.subject(of: arguments))
        // **덮지 못한 범위는 읽기의 사실이다.** 쓰기 영수증이 범위를 들고 오면
        // 그 값으로 차례를 "일부만 마쳤다"로 덮던 자리다 — 저장이 성공했는데도
        // 화면이 "일부 작업만 마쳤어요"라고 말했다(실기 2026-09-16, 캡처 저장).
        // 쓰기의 완료·부분은 `effectCompletion`이 따로 말한다(§2.6).
        if step.capability.executionClass == .readOnly,
          receipt.coverage.contains(where: { $0.state != .complete })
        {
          state.incomplete = true
        }
        // **효과는 나갔는데 디스크가 모른다.** 그 차례는 완료가 아니라 재조정이다 —
        // 사용자가 본 "보냈어요"와 원장의 `pending`이 갈라진 채로 닫으면, 다음
        // 복구는 그 전송을 결과 불명으로 막으면서 화면은 성공을 말한다
        // (코드 리뷰 2026-09-18 P1).
        if receipt.ledgerUnsettled {
          state.terminations.append(Self.ledgerUnsettledReason)
        }
        state.performed.insert(identity)
        state.lastProgressIteration = state.iteration
        state.unsuccessfulToolExecutions = 0
        // 읽은 주소는 불변식이 본다. 어댑터가 무엇을 영수증에 담는지와 무관하게
        // **우리가 보낸 인자**가 근거다.
        if step.capability == .webRead || step.capability == .webFetch,
          let url = arguments["url"]?.textValue
        {
          state.readURLs.insert(url)
        }
        // **나간 효과는 디스크에도 나간 것으로 남는다.** 이 저장이 없으면 재시작
        // 뒤 복구가 그 열쇠를 `prepared`로 읽고, 원장을 한 번 더 물어야 알 수
        // 있는 것을 "모른다"로 세운다.
        if step.capability.isRemoteWrite {
          let key = request.effectIdentity
          if let index = state.effects.firstIndex(where: { $0.key == key }) {
            state.effects[index].state = .completed
          }
          persistRun(state, status: .running, pendingStepIdentity: identity)
        }
        let unknown = receipt.ledgerUnsettled
        if unknown {
          journalInvocation(
            callID: identity, state, capability: step.capability, fingerprint: identity,
            invocationState: .outcomeUnknown, arguments: encodedArguments,
            receipt: Self.journalReceiptJSON(receipt), receiptID: receipt.requestID.uuidString,
            effectKey: effectKey)
        } else {
          journalInvocation(
            callID: identity, state, capability: step.capability, fingerprint: identity,
            invocationState: .completed, arguments: encodedArguments,
            receipt: Self.journalReceiptJSON(receipt), receiptID: receipt.requestID.uuidString,
            effectKey: effectKey)
          let toolText = receipt.summary.isEmpty ? step.capability.rawValue : receipt.summary
          journalEntry(state, role: .tool, text: toolText, toolCallID: identity)
        }
        emit(.capabilityCompleted(step.capability, receipt), state)
        // 이 단계의 결과는 여기서 화면에 선다. 뒤에 남은 단계와 마무리 호출을
        // 기다리지 않는다.
        checkpoint(state)
      case .waitingApproval(let approval):
        // 허락을 기다리는 동안 차례를 들고 있는다. 그 단계는 아직 실행되지
        // 않았으므로 실행 수에서 되돌린다.
        state.toolExecutions -= 1
        guard eligible(state) else {
          await dispatcher.reject(approval.id)
          return .stopped(phase: .cancelled, needs: nil, reason: "cancelled")
        }
        state.steps.insert(step, at: 0)
        state.pendingApprovalID = approval.id
        // 승인 대기는 내구성 있는 경계다(§9.3). 재시작 뒤 같은 대상·본문인지
        // 다시 볼 근거로 그 지문을 남긴다.
        persistRun(
          state, status: .awaitingApproval,
          pendingStepIdentity: identity,
          approvalFingerprint: ActionFingerprint.arguments(approval.request.arguments))
        journalInvocation(
          callID: identity, state, capability: step.capability, fingerprint: identity,
          invocationState: .proposed, arguments: encodedArguments, effectKey: effectKey)
        journalRun(state, status: .awaitingApproval)
        emit(.awaitingApproval(approval), state)
        guard eligible(state) else {
          await dispatcher.reject(approval.id)
          state.pendingApprovalID = nil
          return .stopped(phase: .cancelled, needs: nil, reason: "cancelled")
        }
        return .suspended
      case .cancelled:
        state.ledger.record(
          failure: step.capability, reason: "cancelled",
          subject: Self.subject(of: arguments),
          coverage: Self.failedCoverage(request, state: .cancelled, reason: "cancelled"))
        emit(.capabilityFailed(step.capability, reason: "cancelled"), state)
        journalInvocation(
          callID: identity, state, capability: step.capability, fingerprint: identity,
          invocationState: .failed, arguments: encodedArguments, effectKey: effectKey)
        return .stopped(phase: .failed, needs: nil, reason: "cancelled")
      default:
        state.unsuccessfulToolExecutions += 1
        let reason = Self.name(outcome)
        let unknownFailure = Self.reconcilingReasons.contains(where: { reason.lowercased().contains($0) })
        journalInvocation(
          callID: identity, state, capability: step.capability, fingerprint: identity,
          invocationState: unknownFailure ? .outcomeUnknown : .failed,
          arguments: encodedArguments, effectKey: effectKey)
        state.ledger.record(
          failure: step.capability, reason: reason,
          subject: Self.subject(of: arguments),
          coverage: Self.failedCoverage(request, state: .unavailable, reason: reason))
        emit(.capabilityFailed(step.capability, reason: reason), state)
        if step.capability.executionClass == .readOnly {
          state.incomplete = true
          // 앞 결과를 요구하지 않는 관찰은 한 공급자의 실패와 독립적이다.
          let independent = state.steps.filter {
            $0.capability.executionClass == .readOnly && $0.unresolved.isEmpty
          }
          if !independent.isEmpty {
            state.steps = independent
            continue
          }
        }
        // 모델이 고른 툴이 실패했다. 규칙이 아는 길로 갈아타지 않는다.
        // 기존 근거나 조사 전 누락값을 읽기 실패 한 건으로 버리지 않는다.
        if state.ledger.hasReceipts
          || (step.capability.executionClass == .readOnly && state.investigationNeeds != nil)
        {
          state.incomplete = true
          state.steps = []
          return .drained
        }
        return .stopped(phase: .failed, needs: nil, reason: reason)
      }
    }
    return .drained
  }

  /// 앞 단계의 수령증에서 빈 자리를 채운다. 채울 수 없으면 nil — 그때는
  /// 되묻는다. **지어내지 않는다.**
  private func resolve(
    _ step: inout PlannedStep, in state: TurnState
  ) -> [String: ActionValue]? {
    guard !step.unresolved.isEmpty else { return step.arguments }
    var arguments = step.arguments
    var binding = step.binding
    let remembered = state.conversation.flatMap { anchors[$0] }?.references ?? [:]
    for key in step.unresolved {
      guard let slot = ResolvableArgument(rawValue: key) else { return nil }
      let hasObservation = state.ledger.attempts.contains { Self.produces(slot, $0.capability) }
      // A new miss/ambiguity supersedes the old target; never answer a new name with an old contact.
      let reference = hasObservation
        ? Self.reference(slot, ledger: state.ledger, context: state.context)
        : remembered[slot]
      guard let reference, reference.isValid(in: state.context), reference.allows(step.capability)
      else {
        // **이 대화가 손에 들고 있는 기록**이 그 자리를 채울 수 있다(§24).
        //
        // 사람은 `"요약해줘"`·`"이거 뭐야"`라고 말하고 식별자를 말하지 않는다.
        // 그 자리를 모델이 지어내게 하지도, 사용자에게 되묻게 하지도 않는다 —
        // 가리킨 대상은 기기가 들고 있다(실기 2026-09-17, iPhone: 첨부 없는 다음
        // 차례가 "값이 하나 더 필요해요"로 닫혔다).
        if slot == .itemID, let held = state.context.heldRecords.first {
          arguments[key] = .text(held.itemID)
          continue
        }
        return nil
      }
      if let source = reference.source, case .connector(let observed) = source.binding {
        guard binding == nil || binding == observed else { return nil }
        binding = observed
      }
      // **같은 주소를 두 번 읽지 않는다.** 계획이 `web.read`를 여럿 내면 자리마다
      // 같은 1위가 채워지고, 지문이 같은 호출은 접히므로(`ActionFingerprint`)
      // 리서치는 한 장으로 끝난다. 이미 읽은 주소면 **다음 후보**를 준다.
      if slot == .url, let picked = reference.value.textValue,
        state.attemptedURLs.contains(picked)
      {
        guard let next = Self.nextSearchedURL(in: state) else { return nil }
        arguments[key] = .text(next)
        continue
      }
      arguments[key] = reference.value
    }
    step = PlannedStep(capability: step.capability, arguments: arguments, binding: binding)
    return arguments
  }

  /// 아직 읽지 않은 **다음 검색 후보**. 순위는 기기가 정한 그 순위다
  /// (`SearchCandidateSelector`) — 공급자 순서를 그대로 쓰면 두 번째 장이 그
  /// 공급자가 고른 두 번째가 된다.
  ///
  /// 기기 모델을 부르지 않는다. 고르는 판단은 첫 장에서 이미 했고
  /// (`searchedPageReadStep`), 여기서 하는 일은 그 순위를 따라 내려가는 것뿐이다.
  private static func nextSearchedURL(
    in state: TurnState, excluding taken: Set<String>? = nil
  ) -> String? {
    guard let hit = state.ledger.receipts.last(where: { $0.capability == .webSearch })
    else { return nil }
    let skip = taken ?? state.attemptedURLs
    let rows = CapabilitySourceRow.rows(in: hit.details)
    let ranked = SearchCandidateSelector.rank(
      rows, query: state.input, context: Self.privateContext(state))
    return ranked.first { candidate in
      let scheme = URL(string: candidate.url)?.scheme
      guard scheme == "http" || scheme == "https" else { return false }
      return !skip.contains(candidate.url)
    }?.url
  }

  private nonisolated static func produces(_ slot: ResolvableArgument, _ capability: CapabilityID) -> Bool {
    switch slot {
    case .to: return capability == .peopleResolve || capability == .contactsRead
    case .messageID: return capability.domain == "mail"
    case .channelID, .threadTS: return capability.domain == "chat"
    case .threadID, .messageIDHeader: return capability == .mailRead
    case .itemID: return ["memory", "artifact", "content", "recording"].contains(capability.domain)
    case .eventID: return capability.domain == "calendar"
    case .reminderID: return capability.domain == "reminders"
    case .photoID: return capability == .photosSearch
    case .url: return capability == .webSearch
    // 줄일 원문은 **읽은 것**에서 온다. 검색은 읽기가 아니다: 그 줄은 손잡이이고
    // (`CapabilityContract.RowKind.handle`) 본문 자리가 비어 있다. 제목과 스니펫으로
    // 이 자리를 채우면 차례는 페이지를 한 장도 열지 않고 **공급자가 쓴 한 줄**을
    // 요약한다 — 실기 2026-09-17(iPad, 실제 PCC)에서 `"찾아서 요약해서 저장해줘"`가
    // `web.search → text.summarize → memory.save`로 `completed`가 됐고, 저장된
    // 메모는 SERP 스니펫의 요약이었다.
    case .sourceText:
      guard CapabilityContract.contract(for: capability)?.rows != .handle else { return false }
      return capability.executionClass == .readOnly
    // 본문은 **만든 글**에서만 온다. 읽은 원문을 그대로 보내지 않는다.
    case .body: return capability == .textSummarize
    }
  }

  private nonisolated static func reference(
    _ slot: ResolvableArgument, ledger: TurnExecutionLedger, context: TurnContextSnapshot
  ) -> BoundReference? {
    guard let observation = ledger.attempts.last(where: { produces(slot, $0.capability) }),
      observation.succeeded else { return nil }
    let receipts = ledger.receipts
    guard let receipt = receipts.last(where: { $0.capability == observation.capability }) else { return nil }
    let rows = CapabilitySourceRow.rows(in: receipt.details)
    // 후보가 여럿인 수령증에서 대상을 **고르지 않는다** — 잘못 고른 대상에 일어난
    // 일은 되돌릴 수 없다. 두 예외가 있고, 둘 다 "여러 줄이 여러 대상이 아니다":
    //
    // - `chat.read`: 이미 고른 한 스레드의 뿌리와 답글이다.
    // - `web.search`: 같은 질문에 대한 서로 다른 출처이고 **순위가 곧 판단**이다.
    //   고르는 일은 기기에서 끝난다(§14) — 결과 목록을 PCC에 보여 주고 "무엇을
    //   열까"를 되묻지 않는다. 그리고 읽기는 부작용이 없다(`readOnly`).
    //
    // 이 예외가 없던 동안 `web.search → web.read`는 **한 번도 이어지지 않았다**:
    // 결과가 둘 이상이면 이 자리가 nil을 내고 차례는 주소를 되물었다.
    // - `photos.search`: 목록은 **최신순**이고 읽기는 부작용이 없다. 고르지 않으면
    //   `"최근 사진 읽어 줘"`가 보관함 식별자를 되묻는다 — 사람이 줄 수 없는 값이다.
    guard rows.count <= 1 || receipt.capability == .chatRead
      || receipt.capability == .webSearch || receipt.capability == .photosSearch
    else { return nil }
    if receipt.capability == .mailSearch || receipt.capability == .chatSearch {
      let bindings = Set(receipts.filter { $0.capability == receipt.capability }.flatMap { $0.sources.map { $0.binding } })
      guard bindings.count <= 1 else { return nil }
    }
    guard let value = resolvedValue(for: slot.rawValue, in: [receipt]) else { return nil }
    let source = receipt.sources.first
    guard source == nil || source?.accountID == context.accountID else { return nil }
    return BoundReference(
      accountID: context.accountID, accountEpoch: context.accountEpoch,
      conversationID: context.conversationID, producingRequestID: context.requestID,
      capability: receipt.capability, source: source,
      sourceID: source?.id ?? rows.first?.identifier ?? receipt.externalID,
      resolvedAt: receipt.completedAt, kind: slot, value: value)
  }

  /// 자리 하나를 수령증에서 찾는다. **최근 수령증이 이긴다.**
  ///
  /// 닫힌 표다. 여기 없는 자리는 앞 단계에서 채워지지 않고, 사용자에게 되묻는다 —
  /// 받는 사람과 본문이 그렇다.
  nonisolated static func resolvedValue(
    for key: String, in receipts: [ActionReceipt]
  ) -> ActionValue? {
    guard let slot = ResolvableArgument(rawValue: key) else { return nil }
    for receipt in receipts.reversed() {
      let rows = CapabilitySourceRow.rows(in: receipt.details)
      switch slot {
      case .to:
        // 연락처 조회의 결과에서만 주소를 가져온다. 사용자가 이름을 말했고
        // 조회가 한 사람으로 확정된 경우다(`AppleContactsCapability.resolve`).
        guard receipt.capability == .peopleResolve || receipt.capability == .contactsRead
        else { continue }
        if let email = rows.first?.body, email.contains("@") { return .text(email) }
      case .messageID:
        guard receipt.capability.domain == "mail" else { continue }
        if let id = rows.first?.identifier, !id.isEmpty { return .text(id) }
      case .channelID:
        guard receipt.capability.domain == "chat" else { continue }
        if let id = rows.first?.identifier, !id.isEmpty { return .text(id) }
      case .threadTS:
        guard receipt.capability.domain == "chat" else { continue }
        if let ts = rows.first?.timestamp, !ts.isEmpty { return .text(ts) }
      case .threadID, .messageIDHeader:
        guard receipt.capability == .mailRead else { continue }
        if let value = receipt.details[key]?.textValue, !value.isEmpty {
          return .text(value)
        }
      case .itemID:
        guard
          ["memory", "artifact", "content", "recording"].contains(
            receipt.capability.domain)
        else { continue }
        if let id = rows.first?.identifier, !id.isEmpty { return .text(id) }
        if let id = receipt.externalID, !id.isEmpty { return .text(id) }
      case .eventID:
        guard receipt.capability.domain == "calendar" else { continue }
        if let id = rows.first?.identifier, !id.isEmpty { return .text(id) }
      case .reminderID:
        guard receipt.capability.domain == "reminders" else { continue }
        if let id = rows.first?.identifier, !id.isEmpty { return .text(id) }
      case .photoID:
        guard receipt.capability == .photosSearch else { continue }
        if let id = rows.first?.identifier, !id.isEmpty { return .text(id) }
      case .url:
        // 주소는 **검색 결과에서만** 온다. 모델이 채우는 자리가 아니다 —
        // 지어낸 주소는 없는 페이지이거나, 더 나쁘게는 남의 사설망 주소다
        // (`ContentFetchHostPolicy`). `web.search`의 줄은 식별자에 주소를 든다.
        guard receipt.capability == .webSearch else { continue }
        if let candidate = rows.first?.identifier,
          let parsed = URL(string: candidate),
          parsed.scheme == "http" || parsed.scheme == "https"
        {
          return .text(candidate)
        }
      case .sourceText:
        // 손잡이 줄은 재료가 아니다(`produces`). 이 자리에도 같은 표가 서야 한다 —
        // 두 경로가 갈리면 한쪽만 막힌다.
        guard CapabilityContract.contract(for: receipt.capability)?.rows != .handle
        else { continue }
        // 읽은 줄들의 본문을 잇는다. 본문이 없는 줄(일정·미리 알림)은 제목과
        // 부제가 재료다 — 빈 글을 요약 툴에 넘기면 그 툴은 지어낸다.
        let material = rows.compactMap { row -> String? in
          let body = row.body.trimmingCharacters(in: .whitespacesAndNewlines)
          if !body.isEmpty { return body }
          let head = [row.title, row.subtitle].filter { !$0.isEmpty }.joined(separator: " — ")
          return head.isEmpty ? nil : head
        }
        guard !material.isEmpty else { continue }
        return .text(material.joined(separator: "\n\n"))
      case .body:
        guard receipt.capability == .textSummarize,
          let text = receipt.details[SummarizeTool.textDetailKey]?.textValue,
          !text.isEmpty
        else { continue }
        return .text(text)
      }
    }
    return nil
  }

  // MARK: 근거

  /// 수령증 전체에서 근거를 **다시 계산한다.**
  ///
  /// 누적이 아닌 이유: 중복 제거와 점수는 차례 전체에 걸쳐 한 번만 적용돼야
  /// 한다. 되돌이마다 이어 붙이면 같은 Slack 메시지가 검색과 스레드 읽기에서
  /// 두 번 올라온다.
  private func compileEvidence(_ state: inout TurnState) async {
    guard eligible(state), state.ledger.hasReceipts else { return }
    let compacting = state.ledger.attempts.last?.capability
    if let compacting {
      emit(.compacting(compacting), state)
    }
    let compiled = await EvidenceCompiler(query: state.input).compile(
      state.ledger.receipts, budget: state.extractionBudget)
    if let compacting {
      emit(.compacted(compacting), state)
    }
    guard eligible(state) else { return }
    state.evidence = compiled
    state.extractionWaitMilliseconds += compiled.extractionWaitMilliseconds
    state.ledger.replaceEvidence(compiled.evidence)
    state.telemetry.materialCount = compiled.evidence.count
    state.telemetry.localExtractions = compiled.localExtractions
    state.telemetry.retrievedRows = compiled.retrievedRows
  }

  /// 이 대화가 표시한 결과에서 **로컬이 채울 수 있는 자리**를 모델이 읽을 이름으로
  /// 옮긴다(§4.4).
  ///
  /// **값은 옮기지 않는다.** 식별자·계정·thread·revision은 `BoundReference`가 기기에
  /// 들고 있고 `resolve`가 실행 직전에 소비한다 — 그 값을 받은 모델이 할 수 있는
  /// 일은 없고, 받은 값을 사실로 읽어 답에 적는 일만 있었다(`Evidence`의 실측
  /// 주석). 근거에서 식별자를 빼면서 이 구획으로 다시 넣던 것이 그 모순이다.
  private func anchoredSlots(_ state: TurnState) -> [ResolvableArgument] {
    guard let conversation = state.conversation, let anchor = anchors[conversation]
    else { return [] }
    return anchor.references
      .filter { $0.value.isValid(in: state.context) }
      .map(\.key)
      .sorted { $0.rawValue < $1.rawValue }
  }

  /// 이 대화가 **손에 들고 있는 기록**을 읽는 단계(§24).
  ///
  /// `attachedItemStep`과 나눠 두는 이유: 그쪽은 **이 차례에** 건넨 것이고 언제나
  /// 읽는다. 이쪽은 앞차례에 건넨 것이고, 계획이 그것을 가리켰거나 채우지 못한
  /// 자리가 있을 때, 그리고 **대화로 닫히려는 차례**(`.reply`)에도 지난다.
  ///
  /// 대화로 닫는 차례까지 넓힌 이유: 앞차례에 건넨 문서를 두고 `"중요한 게
  /// 뭐야?"`라고 물은 차례가 모델의 `.reply`로 곧장 닫히면 그 답은 문서를 본
  /// 적이 없다(제보 재현, `REMAINING_WORK.ko.md` P0). 비용은 로컬 읽기 1회 +
  /// 기기 추출 최대 `EvidenceCompiler.maximumChunksPerRow`회 + PCC 답 1회고,
  /// 이미 읽은 기록은 `attachmentReads`/`ledger.receipts`가 막아 다시 읽지
  /// 않는다 — `"고마워"` 한마디가 매번 지난 문서를 되읽지는 않는다. 이 비용을
  /// 받아들인 이유는 문서를 든 대화의 후속 질문이 근거 없이 닫히는 실패가 이
  /// 비용보다 크기 때문이다.
  private static func heldRecordStep(_ state: TurnState) -> PlannedStep? {
    guard state.scope.contains(.memoryRead) else { return nil }
    guard
      let held = state.context.heldRecords.first(where: {
        !state.attachmentReads.contains($0.itemID)
      })
    else { return nil }
    // 이미 읽은 기록은 다시 읽지 않는다.
    let alreadyRead = state.ledger.receipts.contains {
      guard $0.capability == .memoryRead else { return false }
      if $0.externalID == held.itemID { return true }
      return CapabilitySourceRow.rows(in: $0.details).first?.identifier == held.itemID
    }
    guard !alreadyRead else { return nil }
    switch CapabilityContract.normalize(["itemID": .text(held.itemID)], for: .memoryRead) {
    case .success(let arguments):
      return PlannedStep(capability: .memoryRead, arguments: arguments)
    case .failure:
      return nil
    }
  }

  /// 주소를 주고 읽어 달라고 했는데 그 주소를 읽지 않았다면, 읽는다(§24).
  ///
  /// 이 불변식이 없으면 모델이 낸 "성공한 엉뚱한 계획"이 결정론 구제를 영원히
  /// 밀어낸다 — 구제는 실패할 때만 도니까.
  /// 방금 건넨 기록을 읽는 단계.
  ///
  /// 첨부를 넣고 물은 문장의 답은 그 기록에 있다. 읽지 않은 기록이 남아 있는
  /// 동안은 계획을 묻지 않는다 - 모델에게 물으면 보관함 **검색**을 고를 수 있고,
  /// 방금 넣은 사진을 검색으로 찾는 일은 성립하지 않는다.
  private static func attachedItemStep(_ state: TurnState) -> PlannedStep? {
    guard
      let itemID = state.attachedItemIDs.first(where: {
        !state.attachmentReads.contains($0)
      })
    else { return nil }
    guard state.scope.contains(.memoryRead) else { return nil }
    switch CapabilityContract.normalize(["itemID": .text(itemID)], for: .memoryRead) {
    case .success(let arguments):
      return PlannedStep(capability: .memoryRead, arguments: arguments)
    case .failure:
      return nil
    }
  }

  /// **읽어 놓고 요약하지 않는 일을 막는다.**
  ///
  /// 사람이 `"요약해줘"`라고 말했는데 계획이 `web.read` 하나로 끝나면, 화면에
  /// 서는 것은 근거 세 줄로 쓴 모델 문장이고 **요약문은 어디에도 없다**(실기
  /// 2026-09-19: 위키백과 URL + `"요약해줘"`가 정확히 그렇게 닫혔다). 계획
  /// 지시문을 늘려 고치는 길은 예산이 이미 한 번 깨진 전례가 있어(`instructionsTooLarge`)
  /// 택하지 않는다 — 읽은 본문이 있고 사람이 요약을 말했다는 두 사실만으로
  /// **코드가 다음 단계를 잇는다.** `urlInvariantStep`·`recordReadStep`과 같은
  /// 자리이고 같은 근거다.
  ///
  /// 낱말로 판정하는 것이 여기서 안전한 이유: 이 단계는 읽기 전용 기기 능력이고
  /// (`text.summarize`는 `.observes`) 바깥을 바꾸지 않는다. 잘못 붙어도 비용은
  /// 기기 요약 한 번이지, 사용자가 시키지 않은 효과가 아니다.
  private static func summaryInvariantStep(_ state: TurnState) -> PlannedStep? {
    guard !state.summaryInvariantApplied, state.scope.contains(.textSummarize) else { return nil }
    guard Self.asksForSummary(state.input) else { return nil }
    // 이미 요약·번역 산출물이 있으면 할 일이 없다.
    guard
      !state.ledger.receipts.contains(where: {
        $0.capability == .textSummarize || $0.capability == .textTranslate
      })
    else { return nil }
    guard !state.steps.contains(where: { $0.capability == .textSummarize }) else { return nil }
    // 줄일 **본문**이 있어야 한다. 읽은 것이 없으면 요약은 지어내기가 된다.
    let hasBody = state.ledger.receipts.contains { receipt in
      CapabilitySourceRow.rows(in: receipt.details).contains { !$0.body.isEmpty }
    }
    guard hasBody else { return nil }
    return PlannedStep(
      capability: .textSummarize, arguments: [:],
      unresolved: [ResolvableArgument.sourceText.rawValue])
  }

  /// 사람이 **요약을 말했는가.** 번역은 여기 넣지 않는다 — 도착 언어가 필요하고,
  /// 그 값을 규칙이 지어내면 사용자가 말하지 않은 언어로 옮긴다.
  private static func asksForSummary(_ input: String) -> Bool {
    let lowered = input.lowercased()
    return ["요약", "정리해", "간추", "summarize", "summary", "tl;dr"]
      .contains { lowered.contains($0) }
  }

  /// 찾은 내 기록을 읽는 단계. **한 차례에 한 번만.**
  ///
  /// 가장 위 줄만 읽는다. 더 필요하면 감독자가 계획한다 - 여기서 여러 건을 읽으면
  /// 문맥이 커지고, 이 자리의 목적은 "하나도 읽지 않는 일"을 막는 것이다.
  private static func recordReadStep(_ state: TurnState) -> PlannedStep? {
    guard !state.recordReadApplied else { return nil }
    // 찾은 것이 있는데 하나도 읽지 않는 일을 막는 자리다. 문장을 규칙으로 읽어
    // 조건을 달지 않는다 — 검색 수령증이 있다는 사실이 곧 읽을 것이 있다는 뜻이다.
    guard
      let hit = state.ledger.receipts.last(where: {
        $0.capability == .memorySearch || $0.capability == .artifactFind
      })
    else { return nil }
    guard let itemID = CapabilitySourceRow.rows(in: hit.details).first?.identifier,
      !itemID.isEmpty
    else { return nil }
    let capability: CapabilityID = hit.capability == .artifactFind ? .artifactRead : .memoryRead
    guard state.scope.contains(capability) else { return nil }
    // 이미 읽은 기록은 다시 읽지 않는다.
    let alreadyRead = state.ledger.receipts.contains {
      guard $0.capability == .memoryRead || $0.capability == .artifactRead else { return false }
      if $0.externalID == itemID { return true }
      return CapabilitySourceRow.rows(in: $0.details).first?.identifier == itemID
    }
    guard !alreadyRead else { return nil }
    switch CapabilityContract.normalize(["itemID": .text(itemID)], for: capability) {
    case .success(let arguments):
      return PlannedStep(capability: capability, arguments: arguments)
    case .failure:
      return nil
    }
  }

  /// 이 회차에 **함께 보낼** 읽기들.
  ///
  /// 보통은 한 장이다. 한 장의 값은 네트워크가 아니라 **기기의 값 뽑기**이고
  /// (실측 2026-09-18, iPhone 15 Pro: 세 장을 읽은 차례 26.2초 중 읽기는 5초,
  /// 나머지는 뽑기와 답), 미리 두 장을 잡으면 첫 장으로 충분한 차례가 필요 없는
  /// 뽑기를 한 번 더 한다.
  ///
  /// 앞 장이 **사실을 한 줄도 주지 않았을 때만** 둘을 함께 낸다: 글을 스크립트가
  /// 그리는 페이지는 다음 장도 그럴 수 있고, 그때 두 번의 기다림을 한 번으로
  /// 접는다(`prefetchIndependentReads`가 병렬로 보낸다).
  private func searchedPageReadSteps(_ state: inout TurnState) async -> [PlannedStep] {
    guard let first = await searchedPageReadStep(&state) else { return [] }
    let facts = state.evidence.evidence.reduce(0) { $0 + $1.facts.count }
    guard facts == 0, state.ledger.receipts.contains(where: { $0.capability == .webRead }),
      state.searchedPageReadAttempts + 2 <= Self.searchedPageReadLimit,
      let chosen = first.arguments["url"]?.textValue
    else { return [first] }
    var taken = state.attemptedURLs
    taken.insert(chosen)
    guard let next = Self.nextSearchedURL(in: state, excluding: taken),
      case .success(let arguments) = CapabilityContract.normalize(
        ["url": .text(next)], for: .webRead)
    else { return [first] }
    return [first, PlannedStep(capability: .webRead, arguments: arguments)]
  }

  /// 찾은 페이지를 읽는 **한 단계**. 무엇을 읽을지는 여기서 고른다.
  ///
  /// 검색이 돌려주는 줄은 주소와 공급자가 쓴 한 줄뿐이다(`RowKind.handle`). 그
  /// 줄로 답을 쓰면 우리가 **열어 보지 않은 페이지**에 대해 답한 것이 된다.
  ///
  /// 실기 2026-09-17(iPad, 실제 PCC): `"애플 PCC 최신 내용 알려줘"`의 계획이
  /// `web.search` 하나였고 차례는 다섯 줄을 찾은 뒤 `partial`로 닫혔다 — 근거
  /// 조각은 0개였다. 모델에게 다시 묻지 않고 여기서 메운다: 찾았다는 사실이 곧
  /// 읽을 것이 있다는 뜻이다(`recordReadStep`과 같은 자리).
  private func searchedPageReadStep(_ state: inout TurnState) async -> PlannedStep? {
    guard state.searchedPageReadAttempts < Self.searchedPageReadLimit else { return nil }
    guard state.scope.contains(.webRead) else { return nil }
    guard let hit = state.ledger.receipts.last(where: { $0.capability == .webSearch })
    else { return nil }
    // **읽기를 멈추는 것은 장 수가 아니라 모인 사실이다.** 계획이 스스로 읽기를
    // 냈다면 깊이는 계획의 것이므로 이 보정은 한 장으로 끝난다. 검색만 하고 끝낸
    // 계획이면 여기서 메우고, 사실이 모일 때까지 다음 후보로 내려간다 — 한 장으로
    // 못 박은 동안 `"이더리움에 대해 리서치해줘"`가 글 없는 `msn.com` 한 장을 읽고
    // `"정보를 찾을 수 없어요"`로 닫혔다(실기 2026-09-18, iPhone 15 Pro).
    //
    // 성공한 수령증으로 판정한다. 시도한 주소로 판정하면 **거절당한 시도**가 읽은
    // 것으로 세어져 그 차례는 아무것도 읽지 못한 채 끝난다(실기 2026-09-17 P01:
    // `web.read.rejected` 하나로 차례가 근거 0개로 닫혔다).
    let read = state.ledger.receipts.contains { $0.capability == .webRead }
    if read {
      guard !state.planReadsPages else { return nil }
      let facts = state.evidence.evidence.reduce(0) { $0 + $1.facts.count }
      guard facts < Self.researchFactFloor else { return nil }
    }
    let rows = CapabilitySourceRow.rows(in: hit.details)
    // **어느 줄을 읽을지는 기기가 고른다.** 공급자 1위를 그대로 읽던 동안
    // `"내 기록의 PCC 메모와 비교해줘"`가 `Pointe Coupée Parish Government`의
    // 연락처 페이지를 읽었다(실기 2026-09-17, iPad) — `PCC`는 애플의 낱말이 아니고
    // 공급자는 우리 사용자의 맥락을 모른다. 그 맥락은 기기에 있다.
    let context = Self.privateContext(state)
    let ranked = SearchCandidateSelector.rank(rows, query: state.input, context: context)
      .filter { candidate in
        let scheme = URL(string: candidate.url)?.scheme
        guard scheme == "http" || scheme == "https" else { return false }
        // 이미 시도한 주소는 건너뛴다. 거절한 사이트를 다시 부르지 않는다.
        return !state.attemptedURLs.contains(candidate.url)
      }
    guard var choice = ranked.first else { return nil }
    // **후보 집합을 남긴다.** 고른 줄만 보면 "잘못 골랐다"와 "고를 것이 없었다"를
    // 가를 수 없다 — 질의가 모호해 애플 페이지가 후보에 아예 없던 차례를
    // 선택기의 실패로 읽게 된다(실기 2026-09-17 P02).
    Self.log.info(
      """
      web.read candidates=\(ranked.count, privacy: .public) \
      scores=\(ranked.prefix(5).map(\.score).map(String.init).joined(separator: ","), privacy: .public) \
      hosts=\(ranked.prefix(5).compactMap { URL(string: $0.url)?.host }.joined(separator: ","), privacy: .public) \
      ambiguous=\(SearchCandidateSelector.isAmbiguous(ranked, informed: !context.isEmpty), privacy: .public)
      """)
    // 점수가 갈렸으면 기기 모델을 부르지 않는다 — 비용만 늘린다. 갈리지 않은
    // 경우는 흔하다: 0점(한국어 문장 대 영문 제목), 동점, 그리고 **사적 맥락이
    // 하나도 맞지 않은 1위**(질의의 약어만 맞은 줄).
    if SearchCandidateSelector.isAmbiguous(ranked, informed: !context.isEmpty) {
      switch await SearchCandidateChoice().pick(
        from: ranked, query: state.input, context: context)
      {
      case .picked(let picked):
        choice = picked
        state.telemetry.localSelections += 1
      case .none:
        // **고를 것이 없다고 답했다.** 읽지 않는다 — 사용자가 묻지 않은 페이지를
        // "최신 웹 내용"으로 말하는 것보다 웹에서 찾지 못했다고 말하는 것이 맞다.
        state.telemetry.localSelections += 1
        state.telemetry.interventionReason = "search:no-relevant-candidate"
        Self.log.info("web.read declined reason=noRelevantCandidate")
        return nil
      case .unavailable:
        break
      }
    }
    guard
      case .success(let arguments) = CapabilityContract.normalize(
        ["url": .text(choice.url)], for: .webRead)
    else { return nil }
    return PlannedStep(capability: .webRead, arguments: arguments)
  }

  /// 후보를 고를 때 쓰는 **사적 맥락.** 이 차례가 기기에서 이미 읽은 내 기록이다.
  ///
  /// 공개 웹으로 나가지 않는다 — 나간 것은 질의뿐이고(`web.search`), 이 값은 이미
  /// 받아 온 줄들을 기기에서 다시 세우는 데만 쓰인다.
  private static func privateContext(_ state: TurnState) -> [String] {
    state.ledger.receipts
      .filter { $0.capability.domain == "memory" || $0.capability.domain == "artifact" }
      .flatMap { CapabilitySourceRow.rows(in: $0.details) }
      .flatMap { [$0.title, $0.subtitle, $0.body] }
      .filter { !$0.isEmpty }
  }

  private static func urlInvariantStep(_ state: TurnState) -> PlannedStep? {
    guard !state.invariantApplied,
      let url = LinkText.firstExplicitURL(in: state.input)
    else { return nil }
    guard state.scope.contains(.webRead) else { return nil }
    // **그 주소**를 읽었는가. 아무 웹 읽기나 있으면 통과하던 동안, 모델이 딴
    // 페이지를 성공적으로 읽은 차례가 사용자가 준 주소를 끝내 읽지 않았다.
    guard !state.readURLs.contains(url.absoluteString) else { return nil }
    guard
      case .success(let arguments) = CapabilityContract.normalize(
        ["url": .text(url.absoluteString)], for: .webRead)
    else { return nil }
    return PlannedStep(capability: .webRead, arguments: arguments)
  }

  /// 아직 하지 않은 단계만. **같은 인자로 성공한 호출**은 걷어낸다.
  ///
  /// 구제는 못 한 일을 하는 길이고, 한 일을 또 하는 길이 아니다. 이 여과가
  /// 없으면 방금 만든 미리 알림을 구제가 한 번 더 만든다(시험 실측).
  private static func pending(
    _ steps: [PlannedStep], performed: Set<String>
  ) -> [PlannedStep] {
    steps.filter { step in
      // 앞 단계에서 채울 자리가 남은 단계는 지문을 계산할 수 없다 — 그런 단계는
      // 통과시키고, 채운 뒤 `drain`이 다시 본다.
      guard step.unresolved.isEmpty else { return true }
      return !performed.contains(ActionFingerprint.call(step.capability, step.arguments, binding: step.binding))
    }
  }

  private static func failedCoverage(_ request: ActionRequest, state: CoverageRecord.State,
    reason: String) -> CoverageRecord? {
    guard request.capability.executionClass == .readOnly else { return nil }
    let binding: SourceBinding
    if let connector = request.binding { binding = .connector(connector) }
    else if request.capability.domain == "web" { binding = .publicWeb }
    else if request.capability.domain == "mail" || request.capability.domain == "chat" { return nil }
    else { binding = .accountLocal(accountID: request.accountID, domain: request.capability.domain) }
    return CoverageRecord(binding: binding, capability: request.capability,
      queryFingerprint: ActionFingerprint.arguments(request.arguments), state: state,
      discoveredCount: 0, readCount: 0, paginationExhausted: false,
      reason: reason.lowercased().contains("authorized") || reason.lowercased().contains("scope")
        ? .permission : .providerFailure)
  }

  private static func matchesTarget(_ source: SourceReference, capability: CapabilityID,
    arguments: [String: ActionValue]) -> Bool {
    switch capability.domain {
    case "mail":
      return source.kind == .mailMessage && arguments["messageID"]?.textValue == source.id
    case "chat":
      guard source.kind == .chatMessage, arguments["channelID"]?.textValue == source.containerID else { return false }
      return arguments["threadTS"]?.textValue.map { $0 == source.id } ?? true
    default: return false
    }
  }

  // MARK: 닫기

  /// 끝난 단계를 **그 자리에서** 화면에 세운다.
  ///
  /// 예전에는 차례가 끝날 때 한 번만 세웠다. 그래서 일정을 이미 만든 뒤에도
  /// 사람은 모델이 답을 쓰는 동안 빈 진행 줄만 봤다 — 한 차례가 PCC 두 번
  /// (계획·마무리)과 도구 실행을 안고 있으니 그 대기가 길다. 쪼개는 방법은
  /// 호출을 줄이는 것이 아니라 **끝난 것을 붙잡지 않는 것**이다.
  ///
  /// 답은 아직 없으므로 결론 줄을 비워 둔다(빈 줄은 답의 자리를 세우지 않는다).
  /// 이 상태는 저장하지 않는다 — 저장은 `finish`가 한 번 한다.
  ///
  /// **회수물은 여기서 세우지 않는다.** 색인이 고른 후보는 아직 판정을 받지
  /// 않았고(`judged`), 판정 전의 후보를 화면에 세우면 의도와 무관한 줄이
  /// 먼저 보인 뒤 사라진다. 진행 중에 보여야 하는 것은 단계와 접근 영수증이다.
  private func checkpoint(_ state: TurnState) {
    present(
      ConversationTurnResult(
        requestID: state.requestID,
        request: state.input,
        phase: .working,
        headline: "",
        points: [],
        references: [],
        readSources: state.evidence.readSources,
        processingLocation: state.usage.location,
        steps: Self.steps(of: state),
        receipts: state.ledger.receipts,
        telemetry: state.telemetry, context: state.context, coverage: state.ledger.coverage))
  }

  /// 화면에 세울 단계 목록. **한 일 + 하려는 일**이다.
  ///
  /// 승인 설계(`P3 · Working · Expanded`)는 계획된 단계를 미리 세우고 하나씩
  /// 채운다. 실행된 것만 세우면 진행 줄은 "몇 개 했다"만 말하고 앞으로 무엇을
  /// 할지는 말하지 않는다 — 실패한 차례에서는 하려던 일이 아예 사라진다(`P5`).
  private static func steps(of state: TurnState) -> [ConversationTurnResult.Step] {
    state.ledger.steps
      + state.steps.map { planned in
        ConversationTurnResult.Step(
          capability: planned.capability, succeeded: false, reason: "",
          subject: Self.subject(of: planned.arguments), pending: true)
      }
  }

  /// 감독이 끝났다. **답은 도구가 닫힌 상태에서 쓴다**(§19).
  private func finalizeAndPresent(_ initial: TurnState) async {
    var state = initial
    guard eligible(state) else {
      await finish(state, phase: .failed, reason: "cancelled")
      return
    }
    if !state.safetyRefused { await compileEvidence(&state) }
    guard eligible(state) else {
      await finish(state, phase: .cancelled, reason: "cancelled")
      return
    }
    guard state.ledger.hasReceipts else {
      if let needs = state.investigationNeeds {
        await finish(state, phase: .awaitingUser, needs: needs)
        return
      }
      if let failed = state.ledger.steps.last(where: { !$0.succeeded }) {
        await finish(state, phase: .failed, reason: failed.reason)
        return
      }
      // 도구가 하나도 돌지 않았다. **그래도 대화는 이어진다** — 인사·잡담·
      // 되묻는 말에 부를 도구가 없고, 그때 차례를 실패로 닫으면 대화가 아니라
      // 오류 화면이 된다(사용자 지시 2026-09-15: siri처럼 주고받아야 한다).
      await converse(state)
      return
    }
    // **약속한 부작용이 일어났는가.** 계획이 전송·생성을 담았는데 수령증이 없으면
    // 그 차례는 완료가 아니다 — 이 검사가 없던 동안 모델이 계획에서 전송을
    // 빼먹고도 답에 "보냈습니다"를 썼다(실기 2026-09-16).
    // 사유는 여기서 적지 않는다. `finish`가 관측된 사실에서 계산한다
    // (`completionReasons`) — 여러 자리에서 한 칸에 덮어쓰던 동안 보정 표시가
    // 실패 사유를 지웠다(실기 2026-09-17 P01).
    if !state.plannedWrites.subtracting(state.ledger.completedWrites).isEmpty {
      state.incomplete = true
    }
    emit(.finalizing, state)

    var headline = ""
    var points: [AnswerPoint] = []
    /// 모델이 답을 **썼는가**. 상태 문구로 물러난 차례와 구별한다.
    var wroteAnswer = false
    // 답이 필요한 차례는 **회수한 자료를 합쳐 말해야 하는 차례**와 감독이 PCC로
    // 넘어간 차례다(§19). 효과가 끝났다는 사실로 이 값을 끄지 않는다 — 보낸
    // 메일의 답이 실패한 것은 숨길 사실이 아니라 적어야 할 사실이고(§2.6,
    // §10.1), 저장만 한 차례가 "일부만 마쳤다"로 보이던 원인은 이 값이 아니라
    // 쓰기 영수증의 범위를 차례의 불완전으로 읽던 위쪽 한 줄이었다.
    let needsAnswer = state.evidence.needsSynthesis || state.pccSupervised
    state.answerRequired = needsAnswer

    // **요약은 답의 재료가 아니라 답 옆에 서는 글이다.**
    //
    // 기기가 조각마다 쓴 요약을 PCC의 재료로 넘기면 두 가지가 일어났다(실기
    // 2026-09-17, iPhone, 세 번 재현): 근거 압축이 조각 열여섯 개를 여섯 개로
    // 접었고, 답은 앞차례의 답을 베끼거나 원문 발췌를 요약처럼 세웠다.
    //
    // 그래서 요약 수령증이 PCC에 싣는 것은 **무엇을 했는가 한 줄**이다(파일 이름과
    // 조각 수 — `SummarizeTool`이 그 줄을 만든다). PCC는 그 한 줄로 "…16조각을
    // 요약했어요"를 쓰고, 요약 본문은 기기에 남아 화면이 그대로 렌더한다
    // (사용자 지시 2026-09-17). 요약문은 이 문맥을 지나지 않는다.

    // **안전 판정 뒤에는 모델을 다시 부르지 않는다**(§37). 그 자리에 서는 것은
    // 거부를 말하는 한 줄이고, 기기가 정리한 글은 수령증에 남아 화면이 문서로
    // 세운다.
    if needsAnswer, !state.evidence.evidence.isEmpty, !state.safetyRefused {
      // 답도 PCC가 쓴다. 근거 크기로 모델을 갈아타지 않는다.
      let profile = DynamicTurnProfile.finalizing(target: .privateCloud)
      let context: CompiledConversationContext?
      do {
        let compacted = try ConversationContextCompiler().compileWithCompaction(
          profile: profile,
          userMessage: state.input,
          recentTurns: scopedRecentMessages(state),
          evidence: state.evidence.evidence,
          coverage: state.ledger.coverage,
          // **고정점을 주지 않는다.** 도구가 닫혀 다음 단계가 없고, 식별자의 쓸모는
          // 다음 단계의 인자 하나뿐이다.
          knownFacts: state.context.knownFacts,
          completed: state.ledger.completedDigest(),
          voice: answerVoice,
          now: state.context.referenceTime,
          calendar: state.context.calendar)
        context = compacted.context
        state.telemetry.compactedEvidenceCount += compacted.droppedEvidenceCount
        state.telemetry.record(
          contextCharacters: compacted.context.prompt.count, phase: profile.phase.rawValue)
      } catch {
        // 효과는 이미 일어났다. 답을 쓰지 못한 사유만 남기고 아래의 호스트 문구로
        // 닫는다 — 자른 문맥으로 PCC를 부르지 않는다.
        state.terminations.append(error.reason)
        context = nil
      }
      if let context {
        let step = await ModelResponseStream.$sink.withValue(responseSink(for: state)) {
          await finalizing(context, profile)
        }
        record(step.trail, in: &state)
        switch step.answer {
        case .written(let written, let supporting, let relevant, _):
          headline = written
          points = Self.clamped(supporting)
          wroteAnswer = true
          // **판정을 통과한 것만 화면에 선다.** 색인이 고른 후보는 추측이고,
          // 추측을 결과로 세우면 사용자가 묻지 않은 것이 답의 자리에 온다
          // (사용자 지적 2026-09-15: 찾지 못한 사람의 자리에 무관한 연락처).
          state.evidence.references = Self.judged(
            state.evidence.references, relevant: relevant,
            evidence: state.evidence.evidence, pointedAt: Self.pointedAt(state))
        case .unavailable(let reason):
          state.telemetry.fallbackReason = reason
          if ModelFailureClassifier.isSafetyJudgment(reason) {
            state.safetyRefused = true
            state.terminations.append(reason)
          }
        }
      }
    }

    if headline.isEmpty {
      // 모델이 답하지 못했다. 그때 세우는 것은 **답이 아니라 상태 한 줄**이다 —
      // 회수한 것의 제목을 답의 항목으로 올리면(옛 `TurnCopy.evidenceLines`)
      // 질문과 무관한 목록이 답으로 읽힌다(실기 2026-09-15). 찾아온 것은 자기
      // 양식(`ChatOutput.list`)으로 답 아래 선다.
      //
      // 판정도 없으므로 **지역 판정으로 내려선다** — 질의와 한 조각도 겹치지
      // 않는 후보는 세우지 않는다.
      // **결정론 문이 잡은 차례는 거르지 않는다.** 창은 기기 시각이 만들었고
      // 돌아온 줄이 곧 답이다 — `"오늘 일정 뭐 있어?"`와 `"치과"`는 한 글자도
      // 겹치지 않으므로, 겹침 판정을 걸면 찾은 일정이 사라진다.
      if state.deterministicRoute == nil {
        state.evidence.references = Self.overlapping(
          state.evidence.references, evidence: state.evidence.evidence,
          query: state.input, pointedAt: Self.pointedAt(state))
      }

      // **회수한 것도 없고 바꾼 것도 없다. 그 차례는 대화로 닫는다.**
      //
      // 여기까지 온 차례는 도구를 불렀지만 아무것도 돌려받지 못했다(빈 검색).
      // 그때 상태 한 줄("찾지 못했어요")을 세우면 `"안녕"`의 답이 "찾지
      // 못했어요"가 된다(실기 2026-09-17, 사용자 지적). 부를 도구가 없던 차례와
      // 같은 자리다 — 대화 모델은 도구가 닫혀 있고 근거가 없으므로 사용자
      // 데이터에 대한 사실을 말할 수 없고, 말할 수 있는 것은 대화 그 자체뿐이다.
      // 결정론 차례는 여기서도 모델로 내려서지 않는다. 물은 것은 대화가 아니라
      // 달력이고, 비어 있으면 "그 창에 일정이 없다"가 정직한 답이다.
      if state.deterministicRoute == nil, !state.incomplete, state.evidence.references.isEmpty,
        state.ledger.completedWrites.isEmpty, !state.safetyRefused {
        switch await conversed(&state) {
        case .written(let written, let supporting):
          await finish(
            state, phase: .completed, headline: written, points: supporting, wroteAnswer: true)
          return
        case .unavailable(let reason):
          // 대화 모델도 열리지 않았다. 아래의 상태 한 줄로 닫고 **사유를 남긴다** —
          // 사유 없는 상태 한 줄은 "왜 답이 없는가"를 지운다.
          if state.telemetry.fallbackReason.isEmpty {
            state.telemetry.fallbackReason = reason
          }
        }
      }
      headline =
        state.safetyRefused
        ? copy.refused()
        : state.incomplete
        ? copy.partial()
        // **결정론 차례는 조회다.** 물은 것이 "무엇이 있는가"이므로 답은 찾았는지
        // 여부다 — `completed`의 "처리했어요"는 일정이 0건인 조회에 붙으면
        // 무엇을 했는지도, 무엇이 없는지도 말하지 않는다(실기 2026-09-19).
        : needsAnswer || state.deterministicRoute != nil
        ? copy.found(hasReferences: !state.evidence.references.isEmpty)
        : copy.completed(
          hasReferences: !state.evidence.references.isEmpty,
          hasReceipts: state.ledger.hasReceipts)
    }
    await finish(
      state, phase: state.incomplete || (needsAnswer && !wroteAnswer) ? .partial : .completed,
      headline: headline, points: points,
      wroteAnswer: wroteAnswer)
  }

  /// 도구가 하나도 돌지 않은 차례를 **대화로** 닫는다.
  ///
  /// User-reported context and stable general knowledge are valid conversation
  /// material. They do not prove access to live records or completion of an action.
  /// A cached PCC reply closes here without invoking another model.
  private func converse(_ initial: TurnState) async {
    var state = initial
    emit(.finalizing, state)
    if case .reply(let text) = state.dialogue {
      // The first PCC response already contains the conversation answer.
      // Do not spend a second PCC call or invoke an on-device model here.
      await finish(state, phase: .completed, headline: text, wroteAnswer: true)
      return
    }
    switch await conversed(&state) {
    case .written(let written, let supporting):
      await finish(
        state, phase: .completed, headline: written, points: supporting, wroteAnswer: true)
    case .unavailable(let reason):
      await finish(state, phase: .failed, reason: reason)
    }
  }

  /// 대화로 쓴 답. 모델을 열지 못한 자리를 **사유와 함께** 돌려준다 — 부르는
  /// 쪽이 상태 한 줄로 내려설 수 있어야 한다.
  private enum ConversedAnswer {
    case written(String, [AnswerPoint])
    case unavailable(String)
  }

  /// 대화 한 줄. `asking`을 주면 **답이 아니라 되물음**을 쓴다(모자란 값의 이름).
  private func conversed(
    _ state: inout TurnState, asking value: String? = nil
  ) async -> ConversedAnswer {
    let profile =
      value.map { DynamicTurnProfile.asking($0, target: .privateCloud) }
      ?? DynamicTurnProfile.conversing(target: .privateCloud)
    let context: CompiledConversationContext
    do {
      context = try ConversationContextCompiler().compile(
        profile: profile, userMessage: state.input,
        recentTurns: scopedRecentMessages(state),
        knownFacts: state.context.knownFacts,
        voice: answerVoice,
        now: state.context.referenceTime,
        calendar: state.context.calendar)
      state.telemetry.record(
        contextCharacters: context.prompt.count, phase: profile.phase.rawValue)
    } catch {
      state.terminations.append(error.reason)
      return .unavailable(error.reason)
    }
    let step = await ModelResponseStream.$sink.withValue(responseSink(for: state)) {
          await finalizing(context, profile)
        }
    record(step.trail, in: &state)
    switch step.answer {
    case .written(let written, let supporting, _, _):
      return .written(written, Array(supporting.prefix(3)))
    case .unavailable(let reason):
      return .unavailable(reason)
    }
  }

  /// 이 호출이 **무엇을 대상으로 했는가.**
  ///
  /// 사용자가 준 값만 본다. 식별자는 화면에 세우지 않는다 — 기록 id·메시지 id는
  /// 사실이 아니라 배선이고, 그것을 줄에 세우면 사용자는 자기가 시킨 일 대신
  /// UUID를 읽는다.
  public static func subject(of arguments: [String: ActionValue]) -> String {
    for key in Self.subjectKeys {
      guard let raw = arguments[key]?.textValue?.trimmingCharacters(
        in: .whitespacesAndNewlines), !raw.isEmpty
      else { continue }
      // **자르기 전에 푼다.** 주소는 퍼센트 인코딩으로 오고(`/wiki/%EA%B2%80…`),
      // 인코딩된 채로 60자에서 자르면 조각난 `%E…`가 남아 어디서도 다시 풀 수
      // 없다 — 화면에 기계의 글자가 그대로 섰다(실기 2026-09-19).
      var value = raw
      while let decoded = value.removingPercentEncoding, decoded != value { value = decoded }
      guard value.count > Self.subjectLimit else { return value }
      return String(value.prefix(Self.subjectLimit)) + "…"
    }
    return ""
  }

  /// 대상을 담는 자리. **순서가 곧 우선순위다** — 제목이 있으면 질의보다 제목이
  /// 그 호출을 더 잘 말한다.
  private static let subjectKeys = [
    "title", "query", "name", "to", "subject", "url", "text",
  ]
  /// 한 줄에 세울 글자 수. 메모 저장의 `text`는 본문 전체일 수 있다.
  private static let subjectLimit = 60

  /// 사용자가 **가리킨** 대상. 이 차례가 읽은 것 중 지시로 읽은 것들이다:
  /// 문장과 함께 건넨 기록, 그리고 문장에 적힌 주소.
  private static func pointedAt(_ state: TurnState) -> Set<String> {
    Set(state.attachedItemIDs).union(state.readURLs)
  }

  /// 모델 판정을 통과한 회수물만.
  ///
  /// 규칙은 하나다: **사용자가 가리킨 대상은 판정 대상이 아니고, 나머지는 전부
  /// 판정을 받는다.** 주소를 읽은 것과 방금 넣은 사진을 읽은 것은 추측이 아니라
  /// 지시다. 그 밖의 모든 줄은 색인·공급자가 고른 후보이고, 점수는 "있다"를
  /// 말하지 "맞다"를 말하지 않는다.
  ///
  /// 능력 이름으로 가르던 판본이 있었다(검색은 추측, 읽기는 지시). 그 규칙은
  /// 새는 구멍이 있다 — 찾은 것을 읽는 불변식(`recordReadStep`)이 내는 읽기는
  /// **색인이 고른 대상**을 읽는 읽기이고, 그 참조가 판정을 우회했다.
  public static func judged(
    _ references: [ToolResultReducer.Reference],
    relevant: [Int],
    evidence: [Evidence],
    pointedAt: Set<String>
  ) -> [ToolResultReducer.Reference] {
    // 번호는 1부터다(`ConversationContextCompiler`). 문맥에 실린 것보다 큰
    // 번호는 아무것도 가리키지 않으므로 버린다.
    let accepted = relevant.compactMap { number -> Evidence? in
      let index = number - 1
      guard evidence.indices.contains(index) else { return nil }
      return evidence[index]
    }
    return references.filter { reference in
      if pointedAt.contains(reference.identifier) { return true }
      return accepted.contains { Self.matches(reference, $0) }
    }
  }

  /// 판정이 없을 때의 **지역 대역**. 질의와 한 조각도 겹치지 않는 후보는 세우지
  /// 않는다 — 모델을 쓸 수 없는 기기에서도 색인 점수가 답이 되지는 않는다.
  ///
  /// 참조의 제목만 보지 않는다. 채팅 줄의 제목은 채널 이름(`dev`)이고 질의와
  /// 겹치는 말은 본문에 있다 — 제목만 보던 규칙은 맞는 결과를 전부 버렸다.
  /// 그래서 판정 대상은 그 줄에서 나온 **근거**다.
  ///
  /// 이 대역은 모델 판정을 흉내내지 않는다. 낱말이 겹치는지만 본다 — 의도와
  /// 맞는지는 모델이 정하고(`judged`), 여기서 하는 일은 아무 관계도 없는 줄을
  /// 답의 자리에서 걷어내는 것뿐이다.
  public static func overlapping(
    _ references: [ToolResultReducer.Reference],
    evidence: [Evidence],
    query: String,
    pointedAt: Set<String> = []
  ) -> [ToolResultReducer.Reference] {
    let terms = EvidenceCompiler.terms(in: query)
    guard !terms.isEmpty else { return references }
    return references.filter { reference in
      if pointedAt.contains(reference.identifier) { return true }
      let matched = evidence.filter { Self.matches(reference, $0) }
      // 판정할 근거가 없는 참조는 남긴다. 상한에 걸려 근거로 옮겨지지 않은
      // 줄이고(`ToolResultReducer.perSourceLimit`), 그 사실은 무관함의 근거가
      // 아니다.
      guard !matched.isEmpty else { return true }
      return matched.contains { Self.mentions($0, terms: terms) }
    }
  }

  /// 이 근거가 질의를 가리키는가. 제목·요약·사실 줄 전부를 본다.
  private static func mentions(_ evidence: Evidence, terms: [String]) -> Bool {
    if let title = evidence.title, EvidenceCompiler.mentions(title, terms: terms) {
      return true
    }
    if let summary = evidence.summary,
      EvidenceCompiler.mentions(summary, terms: terms)
    {
      return true
    }
    return evidence.facts.contains { EvidenceCompiler.mentions($0, terms: terms) }
  }

  /// 이 참조가 그 근거에서 나왔는가.
  ///
  /// `Evidence.id`를 쓰지 않는다 — 기기 모델이 뽑은 근거는 부제를 제목으로
  /// 물려받지 않아서(`EvidenceCompiler.extract`) 같은 줄이 다른 id를 갖는다.
  private static func matches(
    _ reference: ToolResultReducer.Reference, _ evidence: Evidence
  ) -> Bool {
    guard Evidence.Source(domain: reference.capability.domain) == evidence.source
    else { return false }
    if let source = reference.sourceReference, let evidenceSource = evidence.sourceReference {
      return source.identity == evidenceSource.identity
    }
    if let sourceID = evidence.sourceID, !sourceID.isEmpty {
      return sourceID == reference.identifier
    }
    guard let title = evidence.title, !title.isEmpty else { return false }
    return title == reference.title || title == reference.subtitle
  }

  /// **완전함을 깎은 사실들.** 비어 있으면 깎인 것이 없다.
  ///
  /// 문자열 한 칸에 그때그때 적지 않고 여기서 계산하는 이유: 한 차례에 여러 사실이
  /// 함께 성립하고, 적는 자리가 여럿이면 뒤에 적는 쪽이 앞을 지운다. 그 구조가
  /// `phase=partial fallback=invariant:web.read`를 만들었다 — 보정 표시가 사유의
  /// 자리를 차지했고, 그 줄은 왜 부분으로 닫혔는지 말하지 않았다(실기 2026-09-17 P01).
  ///
  /// 근거는 상태가 아니라 **수령증**이다(`Evidence`를 매번 다시 뽑는 것과 같은 방식).
  private static func completionReasons(
    _ state: TurnState, phase: ConversationTurnResult.Phase, wroteAnswer: Bool
  ) -> [String] {
    var reasons: [String] = []
    for termination in state.terminations where !reasons.contains(termination) {
      reasons.append(termination)
    }
    // 읽은 범위가 온전하지 않았다. 자른 페이지·못 읽은 본문·끝내지 못한 쪽 넘김.
    //
    // 원장의 범위를 본다. 수령증에서만 모으면 **실패한 읽기의 범위가 빠진다** —
    // 실패는 수령증을 남기지 않고 범위만 남기므로(`record(failure:coverage:)`),
    // 거절당한 읽기가 사유 없이 사라진다(시험 실측).
    for coverage in state.ledger.coverage
    where coverage.state != .complete || coverage.truncated {
      let detail = coverage.reason?.rawValue ?? coverage.state.rawValue
      let line = "coverage:\(coverage.capability.rawValue):\(detail)"
      if !reasons.contains(line) { reasons.append(line) }
    }
    // 약속한 쓰기가 일어나지 않았다.
    let unkept = state.plannedWrites.subtracting(state.ledger.completedWrites)
    if !unkept.isEmpty {
      reasons.append("unkept:\(unkept.map(\.rawValue).sorted().joined(separator: "+"))")
    }
    // 답이 필요한 차례인데 모델이 쓰지 못했다. 상태 문구는 답이 아니다.
    if state.answerRequired, !wroteAnswer, phase != .awaitingUser {
      reasons.append("answer:unavailable")
    }
    return reasons
  }

  /// 결과를 화면과 저장소에 남긴다. **모든 종료가 이 문을 지난다.**
  private func finish(
    _ initial: TurnState,
    phase: ConversationTurnResult.Phase,
    needs: String? = nil,
    reason: String? = nil,
    headline: String = "",
    points: [AnswerPoint] = [],
    /// 모델이 실제로 답을 썼을 때만 true. 상태 문구는 답이 아니다.
    wroteAnswer: Bool = false
  ) async {
    var state = initial
    if state.evidence.isEmpty, state.ledger.hasReceipts, !state.safetyRefused {
      await compileEvidence(&state)
    }
    let terminalReason = reason ?? state.ledger.attempts.last(where: { !$0.succeeded })?.reason
      ?? state.terminations.first ?? state.telemetry.fallbackReason
    let interrupted = !eligible(state)
    let confirmedWrites = state.ledger.receipts.filter {
      $0.capability.executionClass == .localWrite || $0.capability.executionClass == .remoteWrite
    }
    // **재조정으로 닫아야 하는 사유들.** 결과를 모르는 전송과, 나갔지만 원장에
    // 못 박히지 않은 효과다 — 둘 다 "일어났는지 디스크가 증명하지 못한다"이고,
    // 그 차례를 완료로 닫으면 화면과 정본이 갈라진다.
    let phase: ConversationTurnResult.Phase =
      Self.reconcilingReasons.contains(where: { terminalReason.lowercased().contains($0) })
      ? .reconciling : (interrupted ? (confirmedWrites.isEmpty ? .cancelled : .partial) : phase)
    let wroteAnswer = wroteAnswer && !interrupted && (phase == .completed || phase == .partial)
    let points = wroteAnswer ? points : []
    var line = interrupted && !confirmedWrites.isEmpty
      ? confirmedWrites.map { $0.summary }.joined(separator: "\n") : headline
    switch phase {
    case .awaitingUser:
      // **되물음도 사람의 말이어야 한다.**
      //
      // 모자란 값의 이름은 배선의 낱말이고(`query`·`recipient`), 그 이름에 묶인
      // 고정 문구는 어떤 요청에도 같은 줄을 세운다 — 실기 2026-09-18에는 `"안녕"`,
      // `"연락처 알려줘"`, `"신의존재에게 메시지 보내자"`가 모두 `"무엇을
      // 찾을까요?"`로 닫혔다(사용자 지적). **무엇이 모자란지는 코어가 알고, 그것을
      // 묻는 문장은 모델이 쓴다.** 모델을 열지 못하면 문구 표로 내려선다.
      let missing = needs ?? "value"
      if case .question(let key, let question) = state.dialogue, key == missing {
        line = question
      } else {
        switch await conversed(&state, asking: missing) {
        case .written(let question, _):
          line = question
        case .unavailable:
          line = copy.needs(missing)
        }
      }
    case .failed:
      let cause =
        state.ledger.attempts.last(where: { !$0.succeeded })?.reason
        ?? reason ?? state.terminations.first ?? state.telemetry.fallbackReason
      line = copy.failure(reason: cause)
    case .partial:
      if line.isEmpty {
        line = copy.partial()
      }
    case .reconciling:
      line = copy.failure(reason: "sendOutcomeUnknown")
    case .cancelled:
      line = copy.failure(reason: "cancelled")
    case .completed, .working:
      break
    }
    // **결과가 완료가 아닌 이유를 마지막에 계산한다.** 여러 자리에서 한 칸에
    // 덮어쓰지 않는다 — 보정 표시(`interventionReason`)가 실패 사유를 지우던
    // 구조가 `phase=partial fallback=invariant:web.read`를 만들었다.
    state.telemetry.completionReason = Self.completionReasons(
      state, phase: phase, wroteAnswer: wroteAnswer
    ).joined(separator: " ")

    state.telemetry.toolCount = state.ledger.attempts.count
    state.telemetry.materialCount = state.evidence.evidence.count
    // **물리 호출을 센다.** 재시도도 문맥을 태웠으므로 요청 하나로 접지 않는다.
    // 토큰 총량은 그 호출 전부를 재지 못하면 nil이고, 그 사실을 `tokenMeasuredCalls`
    // 가 말한다 — 부분 합을 총량으로 적지 않는다.
    state.telemetry.pccCalls = state.usage.pccAttempts
    state.telemetry.tokenMeasuredCalls = state.usage.measuredCalls
    state.telemetry.inputCharacters = state.usage.inputCharacters
    state.telemetry.maximumInputCharacters = state.usage.maximumInputCharacters
    state.telemetry.inputTokens = state.usage.inputTokens
    state.telemetry.maximumInputTokens = state.usage.maximumInputTokens
    state.telemetry.cachedInputTokens = state.usage.cachedInputTokens
    state.telemetry.measuredInputTokens = state.usage.measuredInputTokens
    state.telemetry.processingLocation = state.usage.location
    // 기다린 시간은 **영수증에서 계산한다** — 따로 들면 두 값이 갈라진다. 값
    // 뽑기는 영수증을 남기지 않는 목적이라 차례 누적을 여기서 더한다.
    var waits = state.usage.waitByPurpose
    if state.extractionWaitMilliseconds > 0 {
      waits[AdmissionJob.conversationExtraction.rawValue] =
        state.extractionWaitMilliseconds
    }
    state.telemetry.modelWaitMilliseconds =
      state.usage.waitedMilliseconds + state.extractionWaitMilliseconds
    state.telemetry.modelWaitByPurpose = waits
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: " ")
    if state.telemetry.backend.isEmpty {
      state.telemetry.backend = ModelTarget.onDevice.rawValue
    }
    state.telemetry.latencyMilliseconds = Int(
      now().timeIntervalSince(state.startedAt) * 1_000)
    state.telemetry.succeeded = phase == .completed
    state.telemetry.emit()
    state.usage.emit()

    // Keep bounded, scoped references; a new empty/ambiguous observation clears an old target.
    if isAccountCurrent(state.context), let conversation = state.conversation, !state.ledger.attempts.isEmpty {
      let canRemember = eligible(state)
      var anchor = anchors[conversation] ?? ConversationAnchor(updatedAt: now())
      for slot in ResolvableArgument.allCases
      where state.ledger.attempts.contains(where: { Self.produces(slot, $0.capability) }) {
        anchor.references[slot] = canRemember
          ? Self.reference(slot, ledger: state.ledger, context: state.context) : nil
      }
      if state.ledger.attempts.contains(where: { $0.capability.executionClass == .readOnly }) {
        if canRemember {
          let readCapabilities = Set(state.ledger.attempts.lazy.filter {
            $0.succeeded && $0.capability.executionClass == .readOnly
          }.map { $0.capability })
          anchor.readSources = readCapabilities.sorted { $0.rawValue < $1.rawValue }
            .map { AutomationSource(capability: $0, query: state.input) }
        } else {
          anchor.readSources = []
        }
      }
      anchor.updatedAt = now()
      anchors[conversation] = anchor
      // This is an in-memory reference cache, not a limit on conversations or execution.
      if anchors.count > 32, let oldest = anchors.min(by: {
        $0.value.updatedAt == $1.value.updatedAt ? $0.key < $1.key : $0.value.updatedAt < $1.value.updatedAt
      })?.key { anchors[oldest] = nil }
    }

    // 종착은 내구성 있는 경계다(§9.3). 결과 불명은 종착이 아니라 재조정 상태다.
    persistRun(state, status: Self.runStatus(for: phase))
    journalRun(state, status: Self.journalStatus(for: phase))
    // hidden reasoning은 저장하지 않는다 — 화면에 선 headline/points만.
    var answer = line
    if !points.isEmpty {
      let extra = points.map(\.text).joined(separator: "\n")
      if !extra.isEmpty {
        answer = answer.isEmpty ? extra : answer + "\n" + extra
      }
    }
    if !answer.isEmpty {
      journalEntry(state, role: .assistant, text: answer)
    }
    switch phase {
    case .failed, .reconciling:
      emit(.failed(reason: line), state)
    case .cancelled:
      emit(.interrupted, state)
    case .completed, .partial, .awaitingUser, .working:
      emit(.completed, state)
    }
    present(
      ConversationTurnResult(
        requestID: state.requestID,
        request: state.input,
        phase: phase,
        headline: line,
        points: points,
        // 번호 하나가 무엇을 가리키는지 화면이 말할 수 있어야 한다. 순서는 문맥이
        // 센 순서와 같다(`ConversationContextCompiler.evidenceLimit`).
        evidenceNames: state.evidence.evidence
          .prefix(ConversationContextCompiler.evidenceLimit)
          .map { $0.title ?? $0.source.rawValue },
        isSynthesizedAnswer: wroteAnswer,
        references: state.evidence.references,
        readSources: state.evidence.readSources,
        processingLocation: state.usage.location,
        steps: Self.steps(of: state),
        receipts: state.ledger.receipts,
        telemetry: state.telemetry, context: state.context,
        answerAvailability: wroteAnswer ? .available
          : (state.answerRequired ? .unavailable : .notRequired),
        effectCompletion: phase == .reconciling ? .unknown
          : (state.ledger.completedWrites.isEmpty ? .none
            : (state.ledger.attempts.contains(where: {
              !$0.succeeded && ($0.capability.executionClass == .localWrite || $0.capability.executionClass == .remoteWrite)
            }) ? .partial : .completed)), coverage: state.ledger.coverage))
  }

  /// 화면의 단계와 복구 상태는 다른 값이다. 결과 불명은 종착이 아니라
  /// 재조정(`reconciling`)이고, 사용자 확인 대기는 실패가 아니다(§9.4).
  private static func runStatus(
    for phase: ConversationTurnResult.Phase
  ) -> TurnRunRecord.Status {
    switch phase {
    case .completed: return .completed
    case .partial: return .partial
    case .failed: return .failed
    case .cancelled: return .cancelled
    case .reconciling: return .reconciling
    case .awaitingUser: return .awaitingUser
    case .working: return .running
    }
  }

  /// 항목의 상한. **산문은 세 줄, 표는 한 장.**
  ///
  /// 산문 항목이 길면 답이 점 목록으로 읽힌다(사용자 지적 2026-09-18 "너무
  /// 형식적"). 그러나 표는 머리·구분선·행으로 이루어진 **한 덩이**이고, 세 줄로
  /// 자르면 행 하나만 남는다(실기 2026-09-18: 세 모델 비교 표에 M4 한 줄만 섰다).
  static func clamped(_ points: [AnswerPoint]) -> [AnswerPoint] {
    let isTable = points.contains {
      $0.text.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    }
    return Array(points.prefix(isTable ? 9 : 3))
  }

  public static func name(_ outcome: ActionOutcome) -> String {
    switch outcome {
    case .queued: "queued"
    case .routing: "routing"
    case .working: "working"
    case .waitingApproval: "waitingApproval"
    case .completed: "completed"
    case .failed(let reason): reason
    case .cancelled: "cancelled"
    }
  }
}
