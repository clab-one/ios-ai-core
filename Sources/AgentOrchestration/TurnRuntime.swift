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

  private let dispatcher: ActionDispatcher
  private let emitEvent: @MainActor (TurnEventEnvelope) -> Void
  private var eventSequence: UInt64 = 0
  private var activeRequestID: UUID?
  private let isAccountCurrent: @MainActor (TurnContextSnapshot) -> Bool
  private let present: @MainActor (ConversationTurnResult) -> Void
  /// 상태 문구. 낱말과 언어는 호스트의 것이고, 어느 문구인지는 코어가 정한다.
  private let copy: TurnCopy
  private let now: () -> Date
  /// 차례의 복구 상태. 없으면 복구 기록을 남기지 않는다(§9.1).
  private let turnRuns: (any TurnRunStore)?
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
    now: @escaping () -> Date = Date.init,
    supervising: TurnSupervising? = nil,
    finalizing: TurnFinalizing? = nil,
    /// 차례의 복구 상태 저장소(§9). 없으면 복구 기록을 남기지 않는다 — 조립이
    /// 정본 DB를 세울 수 없는 경우다.
    turnRuns: (any TurnRunStore)? = nil,
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
    self.now = now
    self.turnRuns = turnRuns
    self.originDeviceID = originDeviceID
    self.supervising = supervising ?? Self.liveSupervising
    self.finalizing = finalizing ?? Self.liveFinalizing
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
    public var pendingApprovalID: UUID?
    /// 조사 전 알려진 누락값. 성공한 관찰이 없으면 조회 실패가 질문을 덮지 않는다.
    public var investigationNeeds: String?
    public var stepOrigin: ActionRequest.Origin = .modelPlan
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
    /// 찾은 페이지를 읽으라고 **한 번** 냈는가.
    public var searchedPageReadApplied = false
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
      receiptKeys: state.ledger.receipts.map(\.requestID.uuidString),
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

  private func emit(_ event: TurnEvent, _ state: TurnState) {
    eventSequence &+= 1
    emitEvent(TurnEventEnvelope(
      requestID: state.requestID, accountID: state.account,
      conversationID: state.conversation, accountEpoch: state.context.accountEpoch,
      sequence: eventSequence, event: event))
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
    state.telemetry.profile = "supervised"

    // **긴 입력은 PCC 문을 열지 않는다.** 정상 경로는 정본 캡처가 긴 내용을 기록으로
    // 바꾸고(`attachedItemIDs`) 기기가 읽어 근거로 만드는 것이다(§24). 그 경로가
    // 놓친 입력을 조용히 자르면 잘린 뒤의 지시가 사라지므로, 아무것도 하기 전에
    // 멈춘다 — 자르지 않고 거절한다.
    guard input.count <= PCCContextBudget.standard.requestCharacters else {
      let refusal = ContextCompilationError.requestTooLarge(
        actual: input.count, limit: PCCContextBudget.standard.requestCharacters)
      state.telemetry.fallbackReason = refusal.reason
      await finish(state, phase: .failed, reason: refusal.reason)
      return
    }

    // **할 수 있는 일이 하나도 없으면 모델을 부르지 않는다.** 그리고 그때는
    // "하지 못했어요"가 아니라 **연결이 없다**고 말한다 — 이 자리가 그냥 실패로
    // 접히던 동안, 연결이 없는 기기의 모든 요청이 `model.unavailable`로 끝났다
    // (실측 2026-09-14: `tools=0 latency=1`). 모델은 부른 적조차 없었다.
    guard !scope.isEmpty else {
      state.telemetry.fallbackReason = "noCapability"
      await finish(state, phase: .failed, reason: "noCapability")
      return
    }
    await advance(state)
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
    pendingTurn = nil
    state.pendingApprovalID = nil
    let subject = Self.subject(of: approval.request.arguments)
    switch outcome {
    case .completed(let receipt):
      state.ledger.record(receipt, subject: subject)
      state.performed.insert(ActionFingerprint.call(approval.request.capability, approval.request.arguments, binding: approval.request.binding))
      state.toolExecutions += 1
      state.lastProgressIteration = state.iteration
      emit(.capabilityCompleted(approval.request.capability, receipt), state)
      await advance(state)
    case .cancelled:
      state.ledger.record(
        failure: approval.request.capability, reason: "cancelled", subject: subject)
      await finish(state, phase: .failed, reason: "cancelled")
    default:
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
    state.pendingApprovalID = nil
    state.ledger.record(
      failure: approval.request.capability, reason: "cancelled",
      subject: Self.subject(of: approval.request.arguments))
    await finish(state, phase: .failed, reason: "cancelled")
  }

  public func cancelPending(for requestID: UUID? = nil) async {
    guard let state = pendingTurn,
      requestID == nil || state.requestID == requestID else { return }
    pendingTurn = nil
    if let approvalID = state.pendingApprovalID { await dispatcher.reject(approvalID) }
    await finish(state, phase: .cancelled, reason: "cancelled")
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

    // 1) 계획. 승인에서 돌아온 길은 이미 계획을 들고 있으므로 다시 묻지 않는다.
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
      case .complete:
        return await finalizeAndPresent(state)
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

    // 2) 순차 실행. 여기서 PCC를 부르지 않는다.
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

      // 3) 의미 불변식. **손에 들려 준 대상은 반드시 읽힌다**(§24) — 모델이
      //    엉뚱한 성공 계획을 냈다고 이 요구가 사라지지 않는다. 이 단계들은
      //    규칙이 만드는 계획이 아니라 **빠뜨린 읽기를 메우는 보정**이고, 모델을
      //    다시 부르지 않는다.
      //
      //    먼저 방금 건넨 기록이다. 사진을 넣고 `"이게 뭐야?"`라고 물으면 답은
      //    그 사진을 읽어야 나온다 — 보관함 검색으로 비켜 갈 자리를 만들지 않는다.
      if let injected = Self.attachedItemStep(state) {
        if let id = injected.arguments["itemID"]?.textValue {
          state.attachmentReads.insert(id)
        }
        state.steps = [injected]
        state.telemetry.fallbackReason = "invariant:memory.read"
        continue
      }

      if let injected = Self.urlInvariantStep(state) {
        state.invariantApplied = true
        state.steps = [injected]
        state.telemetry.fallbackReason = "invariant:web.read"
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
        state.telemetry.fallbackReason = "invariant:memory.read"
        continue
      }

      //    웹도 같다. 검색 결과는 주소와 공급자가 쓴 한 줄이고, 그 줄로 답을 쓰면
      //    열어 보지 않은 페이지에 대해 답한 것이 된다(`searchedPageReadStep`).
      if let injected = await searchedPageReadStep(&state) {
        state.searchedPageReadApplied = true
        state.steps = [injected]
        state.telemetry.fallbackReason = "invariant:web.read"
        continue
      }

      guard ContinuousClock.now < state.executionDeadline else {
        state.telemetry.fallbackReason = "deadline"
        state.incomplete = true
        break
      }
      guard state.unsuccessfulToolExecutions < TurnLimits.maxUnsuccessfulToolExecutions else {
        state.telemetry.fallbackReason = "limit:tools"
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
    let phase: TurnPhase = state.iteration == 0 ? .planning : .reviewing
    emit(state.iteration == 0 ? .planning : .replanning, state)

    // **끝난 일을 범위에서 숨기지 않는다.**
    //
    // 숨겼던 동안 `"두 사람에게 각각 보내줘"`와 `"일정 두 개 만들어줘"`가 반만
    // 일어났다 — 첫 쓰기가 끝나자 그 능력이 사라져 두 번째를 계획할 수 없었다.
    // 중복을 막는 것은 범위가 아니라 호출의 정체다(`ActionFingerprint.call`): 같은 인자는
    // 같은 열쇠로 막히고, 다른 인자는 다른 일이다. 감독자는 무엇이 끝났는지를
    // `<<<completed>>>` 구획으로 본다.
    let scope = state.scope
    guard !scope.isEmpty else { return .complete }

    // 오케스트레이션은 **언제나 PCC**다. 예산으로 기기 모델에 내려서던 길
    // (`PCCBudget`)은 없앴다 — 사용자가 말한 일을 다른 품질로 몰래 처리하는
    // 길이었고, 그때 계측의 `backend` 칸도 갈라졌다.
    let profile = DynamicTurnProfile.supervising(
      phase: phase, target: .privateCloud, scope: scope, iteration: state.iteration)
    let context: CompiledConversationContext
    do {
      context = try ConversationContextCompiler().compile(
        profile: profile,
        userMessage: state.input,
        recentTurns: state.context.recentMessages,
        evidence: state.ledger.evidence,
        coverage: state.ledger.coverage,
        anchoredSlots: anchoredSlots(state),
        completed: state.ledger.completedDigest(),
        now: state.context.referenceTime,
        calendar: state.context.calendar)
    } catch {
      // **예산을 넘긴 문맥으로는 부르지 않는다.** 자른 문맥으로 부르면 사용자가
      // 시킨 일과 다른 일이 계획되고, 그 차이는 어디에도 남지 않는다.
      state.telemetry.fallbackReason = error.reason
      return .stop(reason: error.reason)
    }

    state.iteration += 1
    state.telemetry.supervisorIterations = state.iteration

    let step = await supervising(
      SupervisorRequest(
        context: context, profile: profile, conversationID: state.conversation,
        accountID: state.account))
    guard eligible(state) else { return .stop(reason: "cancelled") }
    switch step {
    case .decided(let decision, let trail):
      record(trail, in: &state)
      if trail.outcome.pccCompleted { state.pccSupervised = true }
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
        // 안전 판정은 우회하지 않는다(§37).
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

  /// 이 대상에 대해 **우리가 실제로 관측한** revision. 되돌릴 수 없는 동작에만 쓴다.
  ///
  /// 관측이 여럿이고 값이 갈리면 nil이다 — 어느 것이 지금인지 모르는 상태를
  /// 하나로 고르지 않는다. 공급자가 revision을 주지 않는 경우도 nil이고, 그때는
  /// Dispatcher가 재확인 없이 지나간다(§4.4).
  private func observedTargetRevision(
    for capability: CapabilityID, arguments: [String: ActionValue], in state: TurnState
  ) -> String? {
    guard capability.isIrreversible else { return nil }
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
        state.telemetry.fallbackReason = "limit:tools"
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
          state.searchedPageReadApplied = true
          state.steps.insert(contentsOf: [injected, step], at: 0)
          state.telemetry.fallbackReason = "invariant:web.read"
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
      if state.stepOrigin == .userExplicit, step.capability.isIrreversible {
        request = request.with(
          authorization: AuthorizationProof.issue(for: request, source: .userInstruction))
      }
      state.toolExecutions += 1
      emit(.capabilityStarted(step.capability), state)
      // **바깥으로 나가는 쓰기는 기록 없이 나가지 않는다.** 복구 기록을 남길 수
      // 없으면 실행하지 않는다 — 기록 없이 보낸 전송은 다음 재시도에서 두 번째
      // 전송이 된다(§12 PR5 fail closed).
      if step.capability.isRemoteWrite,
        !persistRun(state, status: .running, pendingStepIdentity: identity)
      {
        state.toolExecutions -= 1
        return .stopped(phase: .failed, needs: nil, reason: "checkpointUnavailable")
      }
      // 함께 보낸 읽기의 결과가 이미 있으면 그것을 쓴다. 없으면 지금 보낸다.
      let outcome: ActionOutcome
      if let prefetched = state.prefetchedReads.removeValue(forKey: identity) {
        outcome = prefetched
      } else {
        outcome = await dispatcher.dispatch(request)
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
        return .stopped(phase: .failed, needs: nil, reason: "cancelled")
      default:
        state.unsuccessfulToolExecutions += 1
        let reason = Self.name(outcome)
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
      else { return nil }
      if let source = reference.source, case .connector(let observed) = source.binding {
        guard binding == nil || binding == observed else { return nil }
        binding = observed
      }
      arguments[key] = reference.value
    }
    step = PlannedStep(capability: step.capability, arguments: arguments, binding: binding)
    return arguments
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
    guard rows.count <= 1 || receipt.capability == .chatRead
      || receipt.capability == .webSearch
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
    if let last = state.ledger.attempts.last?.capability {
      emit(.compacting(last), state)
    }
    let compiled = await EvidenceCompiler(query: state.input).compile(
      state.ledger.receipts, budget: state.extractionBudget)
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

  /// 찾은 페이지를 읽는 단계. **한 차례에 한 번만.**
  ///
  /// 검색이 돌려주는 줄은 주소와 공급자가 쓴 한 줄뿐이다(`RowKind.handle`). 그
  /// 줄로 답을 쓰면 우리가 **열어 보지 않은 페이지**에 대해 답한 것이 된다.
  ///
  /// 실기 2026-09-17(iPad, 실제 PCC): `"애플 PCC 최신 내용 알려줘"`의 계획이
  /// `web.search` 하나였고 차례는 다섯 줄을 찾은 뒤 `partial`로 닫혔다 — 근거
  /// 조각은 0개였다. 모델에게 다시 묻지 않고 여기서 메운다: 찾았다는 사실이 곧
  /// 읽을 것이 있다는 뜻이다(`recordReadStep`과 같은 자리).
  private func searchedPageReadStep(_ state: inout TurnState) async -> PlannedStep? {
    guard !state.searchedPageReadApplied else { return nil }
    guard state.scope.contains(.webRead) else { return nil }
    guard let hit = state.ledger.receipts.last(where: { $0.capability == .webSearch })
    else { return nil }
    // **어느 줄을 읽을지는 기기가 고른다.** 공급자 1위를 그대로 읽던 동안
    // `"내 기록의 PCC 메모와 비교해줘"`가 `Pointe Coupée Parish Government`의
    // 연락처 페이지를 읽었다(실기 2026-09-17, iPad) — `PCC`는 애플의 낱말이 아니고
    // 공급자는 우리 사용자의 맥락을 모른다. 그 맥락은 기기에 있다.
    let rows = CapabilitySourceRow.rows(in: hit.details)
    // **하나라도 읽었으면 끝이다.** 이 자리의 목적은 "찾았는데 하나도 읽지 않는
    // 일"을 막는 것이고, 후보를 전부 읽는 것이 아니다 — 후보 랭킹을 넣자마자
    // 계획대로 1위를 읽은 차례가 2위를 한 번 더 읽었다(시험 실측).
    guard !rows.contains(where: { state.readURLs.contains($0.identifier) }) else {
      return nil
    }
    let context = Self.privateContext(state)
    let ranked = SearchCandidateSelector.rank(rows, query: state.input, context: context)
      .filter { candidate in
        let scheme = URL(string: candidate.url)?.scheme
        return scheme == "http" || scheme == "https"
      }
    guard var choice = ranked.first else { return nil }
    // 점수가 갈렸으면 기기 모델을 부르지 않는다 — 비용만 늘린다. 갈리지 않은
    // 경우(0점·동점)는 흔하다: 한국어 문장과 영문 제목은 낱말이 맞지 않는다.
    if SearchCandidateSelector.isAmbiguous(ranked),
      let picked = await SearchCandidateChoice().pick(
        from: ranked, query: state.input, context: context)
    {
      choice = picked
      state.telemetry.localSelections += 1
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
    await compileEvidence(&state)
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
    let unkept = state.plannedWrites.subtracting(state.ledger.completedWrites)
    if !unkept.isEmpty {
      state.incomplete = true
      if state.telemetry.fallbackReason.isEmpty {
        state.telemetry.fallbackReason =
          "unkept:\(unkept.map(\.rawValue).sorted().joined(separator: "+"))"
      }
    }
    emit(.finalizing, state)

    var headline = ""
    var points: [String] = []
    /// 모델이 답을 **썼는가**. 상태 문구로 물러난 차례와 구별한다.
    var wroteAnswer = false
    // 답이 필요한 차례는 **회수한 자료를 합쳐 말해야 하는 차례**와 감독이 PCC로
    // 넘어간 차례다(§19). 효과가 끝났다는 사실로 이 값을 끄지 않는다 — 보낸
    // 메일의 답이 실패한 것은 숨길 사실이 아니라 적어야 할 사실이고(§2.6,
    // §10.1), 저장만 한 차례가 "일부만 마쳤다"로 보이던 원인은 이 값이 아니라
    // 쓰기 영수증의 범위를 차례의 불완전으로 읽던 위쪽 한 줄이었다.
    let needsAnswer = state.evidence.needsSynthesis || state.pccSupervised
    state.answerRequired = needsAnswer

    if needsAnswer, !state.evidence.evidence.isEmpty {
      // 답도 PCC가 쓴다. 근거 크기로 모델을 갈아타지 않는다.
      let profile = DynamicTurnProfile.finalizing(target: .privateCloud)
      let context: CompiledConversationContext?
      do {
        context = try ConversationContextCompiler().compile(
          profile: profile,
          userMessage: state.input,
          recentTurns: state.context.recentMessages,
          evidence: state.evidence.evidence,
          coverage: state.ledger.coverage,
          // **고정점을 주지 않는다.** 도구가 닫혀 다음 단계가 없고, 식별자의 쓸모는
          // 다음 단계의 인자 하나뿐이다.
          completed: state.ledger.completedDigest(),
          now: state.context.referenceTime,
          calendar: state.context.calendar)
      } catch {
        // 효과는 이미 일어났다. 답을 쓰지 못한 사유만 남기고 아래의 호스트 문구로
        // 닫는다 — 자른 문맥으로 PCC를 부르지 않는다.
        state.telemetry.fallbackReason = error.reason
        context = nil
      }
      if let context {
        let step = await finalizing(context, profile)
        record(step.trail, in: &state)
        switch step.answer {
        case .written(let written, let supporting, let relevant, _):
          headline = written
          points = Array(supporting.prefix(3))
          wroteAnswer = true
          // **판정을 통과한 것만 화면에 선다.** 색인이 고른 후보는 추측이고,
          // 추측을 결과로 세우면 사용자가 묻지 않은 것이 답의 자리에 온다
          // (사용자 지적 2026-09-15: 찾지 못한 사람의 자리에 무관한 연락처).
          state.evidence.references = Self.judged(
            state.evidence.references, relevant: relevant,
            evidence: state.evidence.evidence, pointedAt: Self.pointedAt(state))
        case .unavailable(let reason):
          state.telemetry.fallbackReason = reason
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
      state.evidence.references = Self.overlapping(
        state.evidence.references, evidence: state.evidence.evidence,
        query: state.input, pointedAt: Self.pointedAt(state))
      headline =
        state.incomplete
        ? copy.partial()
        : needsAnswer
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
  /// 여기서 부르는 모델은 도구가 닫혀 있고 근거도 없다(`conversing`). 그래서 이
  /// 답이 말할 수 있는 것은 대화 그 자체뿐이고, 사용자 데이터에 대한 사실은
  /// 말하지 않는다 — 읽은 것이 없으면 아는 것도 없다.
  private func converse(_ initial: TurnState) async {
    var state = initial
    emit(.finalizing, state)
    let profile = DynamicTurnProfile.conversing(target: .privateCloud)
    let context: CompiledConversationContext
    do {
      context = try ConversationContextCompiler().compile(
        profile: profile, userMessage: state.input,
        recentTurns: state.context.recentMessages,
        now: state.context.referenceTime,
        calendar: state.context.calendar)
    } catch {
      state.telemetry.fallbackReason = error.reason
      await finish(state, phase: .failed, reason: error.reason)
      return
    }
    let step = await finalizing(context, profile)
    record(step.trail, in: &state)
    switch step.answer {
    case .written(let written, let supporting, _, _):
      await finish(
        state, phase: .completed, headline: written,
        points: Array(supporting.prefix(3)), wroteAnswer: true)
    case .unavailable(let reason):
      await finish(state, phase: .failed, reason: reason)
    }
  }

  /// 이 호출이 **무엇을 대상으로 했는가.**
  ///
  /// 사용자가 준 값만 본다. 식별자는 화면에 세우지 않는다 — 기록 id·메시지 id는
  /// 사실이 아니라 배선이고, 그것을 줄에 세우면 사용자는 자기가 시킨 일 대신
  /// UUID를 읽는다.
  public static func subject(of arguments: [String: ActionValue]) -> String {
    for key in Self.subjectKeys {
      guard let value = arguments[key]?.textValue?.trimmingCharacters(
        in: .whitespacesAndNewlines), !value.isEmpty
      else { continue }
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

  /// 결과를 화면과 저장소에 남긴다. **모든 종료가 이 문을 지난다.**
  private func finish(
    _ initial: TurnState,
    phase: ConversationTurnResult.Phase,
    needs: String? = nil,
    reason: String? = nil,
    headline: String = "",
    points: [String] = [],
    /// 모델이 실제로 답을 썼을 때만 true. 상태 문구는 답이 아니다.
    wroteAnswer: Bool = false
  ) async {
    var state = initial
    if state.evidence.isEmpty, state.ledger.hasReceipts {
      await compileEvidence(&state)
    }
    let terminalReason = reason ?? state.ledger.attempts.last(where: { !$0.succeeded })?.reason
      ?? state.telemetry.fallbackReason
    let interrupted = !eligible(state)
    let confirmedWrites = state.ledger.receipts.filter {
      $0.capability.executionClass == .localWrite || $0.capability.executionClass == .remoteWrite
    }
    let phase: ConversationTurnResult.Phase = terminalReason.lowercased().contains("sendoutcomeunknown")
      ? .reconciling : (interrupted ? (confirmedWrites.isEmpty ? .cancelled : .partial) : phase)
    let wroteAnswer = wroteAnswer && !interrupted && (phase == .completed || phase == .partial)
    let points = wroteAnswer ? points : []
    var line = interrupted && !confirmedWrites.isEmpty
      ? confirmedWrites.map { $0.summary }.joined(separator: "\n") : headline
    switch phase {
    case .awaitingUser:
      line = copy.needs(needs ?? "value")
    case .failed:
      let cause =
        state.ledger.attempts.last(where: { !$0.succeeded })?.reason
        ?? reason ?? state.telemetry.fallbackReason
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
    if let reason, state.telemetry.fallbackReason.isEmpty {
      state.telemetry.fallbackReason = reason
    }

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
    emit(.completed, state)
    present(
      ConversationTurnResult(
        requestID: state.requestID,
        request: state.input,
        phase: phase,
        headline: line,
        points: points,
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
