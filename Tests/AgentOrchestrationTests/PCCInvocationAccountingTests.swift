import AgentKernel
import XCTest

@testable import AgentOrchestration

/// **PCC를 몇 번 불렀고 얼마를 태웠는가.**
///
/// 재시도를 내부에서 삼키고 영수증을 한 장만 남기던 동안 `pccCalls`는 물리 요청
/// 수보다 작았고, `estimatedInputCharacters`는 단계마다 덮여 마지막 호출의 크기만
/// 남았다. 문맥 크기가 이 코어의 핵심 지표인데 그 지표가 틀려 있었다.
///
/// 시뮬레이터에는 PCC가 없으므로(§48) 실제 토큰은 이 시험이 만들 수 없다. 그래서
/// 증명하는 것은 **셈**이다:
///
/// 1. 나간 호출 전부가 계측에 들어가는가(재시도 포함).
/// 2. 나가지 않은 호출이 섞이지 않는가(부르기 전에 막힌 차례).
/// 3. 부분 측정을 **총량이라 부르지 않는가.**
@available(iOS 26.0, *)
@MainActor
final class PCCInvocationAccountingTests: XCTestCase {
  private static let now = Date(timeIntervalSince1970: 1_789_610_400)

  // MARK: 1) 부분 측정은 총량이 아니다

  func testPartialMeasurementIsNotReportedAsATotal() {
    var usage = ModelUsageLog()
    usage.record(
      Self.receipt(completed: true, characters: 900, usage: Self.usage(1_000, cached: 250)))
    // iOS 26이거나 응답을 받지 못한 호출. **사용량이 없다** — 0도 아니다.
    usage.record(Self.receipt(completed: false, reason: "timeout", characters: 900))

    XCTAssertEqual(usage.pccAttempts, 2)
    XCTAssertEqual(usage.measuredCalls, 1)
    XCTAssertNil(usage.inputTokens, "하나를 재지 못했는데 부분 합이 총량으로 섰다")
    XCTAssertNil(usage.maximumInputTokens)
    XCTAssertNil(usage.cachedInputTokens)
    // 부분 값은 **이름이 그렇게 붙은 칸**으로만 나온다.
    XCTAssertEqual(usage.measuredInputTokens, 1_000)
    XCTAssertEqual(usage.inputCharacters, 1_800, "글자는 나간 호출 전부가 실었다")
    XCTAssertEqual(usage.maximumInputCharacters, 900)
  }

  /// 짝이 되는 시험. 이것이 없으면 "언제나 nil"도 위 시험을 지난다.
  func testFullyMeasuredCallsReportATotal() {
    var usage = ModelUsageLog()
    usage.record(
      Self.receipt(completed: true, characters: 1_500, usage: Self.usage(1_842, cached: 120)))
    usage.record(
      Self.receipt(
        phase: .finalizing, purpose: AdmissionJob.conversationAnswer.rawValue,
        completed: true, characters: 2_400, usage: Self.usage(2_903, cached: 0)))

    XCTAssertEqual(usage.measuredCalls, 2)
    XCTAssertEqual(usage.inputTokens, 4_745)
    XCTAssertEqual(usage.maximumInputTokens, 2_903)
    XCTAssertEqual(usage.cachedInputTokens, 120)
  }

  // MARK: 2) 나가지 않은 요청은 호출이 아니다

  /// 부르기 전에 막힌 차례도 문맥을 **조립했고** 그 크기가 영수증에 남는다. 그러나
  /// 그 글자는 기기를 떠나지 않았다 — 두 값은 다른 지표다(§36).
  func testNotAttemptedReceiptsAreNotPhysicalCalls() {
    var usage = ModelUsageLog()
    usage.record(
      .notAttempted(
        phase: .finalizing, purpose: AdmissionJob.conversationAnswer.rawValue,
        reason: ModelFailureClassifier.unsupportedReason,
        inputCharacters: 1_800, latencyMilliseconds: 3))

    XCTAssertEqual(usage.pccAttempts, 0, "부르기 전에 막힌 것이 요청으로 세어졌다")
    XCTAssertEqual(usage.inputCharacters, 0, "나가지 않은 문맥의 글자가 합에 섞였다")
    XCTAssertEqual(usage.maximumInputCharacters, 0)
    XCTAssertNil(usage.inputTokens)
    XCTAssertEqual(usage.location, .entirelyOnDevice)
  }

  /// 다시 낸 호출이 성공했어도 앞선 실패는 **일어난 일**이다. 처리 위치는 그
  /// 실패로 바뀌지 않는다(§36).
  func testRetriedThenCompletedStillReportsPCCCompleted() {
    var usage = ModelUsageLog()
    usage.record(Self.receipt(completed: false, reason: "rateLimited", characters: 1_500))
    usage.record(
      Self.receipt(completed: true, characters: 1_500, usage: Self.usage(1_842, cached: 120)))

    XCTAssertEqual(usage.pccAttempts, 2)
    XCTAssertEqual(usage.pccCompletions, 1)
    XCTAssertEqual(usage.location, .pccCompleted)
  }

  /// **나가지 않은 요청은 실기가 아니라 여기서 증명된다.**
  ///
  /// 시뮬레이터는 PCC 엔타이틀먼트가 없으므로 `privateCloudSession`이 세션을 세우기
  /// 전에 던진다(§48). 그래서 이 시험은 "세션을 세우는 일과 요청을 내는 일이
  /// 나뉘어 있는가"를 실제 경로로 확인한다 — 답 자리가 계획 자리와 같은 규칙을
  /// 쓰지 않던 동안, 가용성이 계획과 답 사이에 바뀐 차례가 나가지 않은 요청을
  /// `pccCalls`에 더했다.
  func testFinalizerPreflightFailureIsNotAPhysicalCall() async throws {
    let context = try Self.context(profile: .finalizing(target: .privateCloud))
    let outcome = await TurnFinalizer().finalize(
      context, profile: .finalizing(target: .privateCloud))

    XCTAssertEqual(outcome.trail.all.count, 1)
    XCTAssertFalse(outcome.trail.outcome.pccAttempted, "나가지 않은 요청이 시도로 적혔다")
    XCTAssertEqual(Self.log(outcome.trail).pccAttempts, 0)
    XCTAssertEqual(Self.log(outcome.trail).inputCharacters, 0)
    XCTAssertEqual(Self.log(outcome.trail).location, .entirelyOnDevice)
  }

  func testSupervisorPreflightFailureIsNotAPhysicalCall() async throws {
    let profile = DynamicTurnProfile.supervising(
      phase: .planning, target: .privateCloud, scope: Self.scope, iteration: 0)
    let context = try Self.context(profile: profile)
    let result = await TurnSupervisor().decide(
      context, profile: profile, conversationID: "conv", accountID: "acct")

    guard case .failure(let failure) = result else {
      return XCTFail("시뮬레이터에서 계획이 성공했다 — PCC가 없는 환경의 사실과 어긋난다")
    }
    XCTAssertFalse(failure.trail.outcome.pccAttempted, "나가지 않은 요청이 시도로 적혔다")
    XCTAssertEqual(Self.log(failure.trail).pccAttempts, 0)
    XCTAssertEqual(Self.log(failure.trail).location, .entirelyOnDevice)
  }

  // MARK: 3) 차례가 영수증을 하나도 잃지 않는다

  /// 감독 2회(재시도 1회 포함) + 답 1회 = **물리 요청 3건.**
  func testEveryPhysicalCallReachesTelemetry() async {
    var presented: ConversationTurnResult?
    let runtime = makeRuntime(
      supervisorTrail: ModelInvocationTrail(
        outcome: Self.receipt(
          completed: true, characters: 1_500, usage: Self.usage(1_842, cached: 120)),
        discarded: [
          Self.receipt(completed: false, reason: "rateLimited", characters: 1_500)
        ]),
      finalizerTrail: ModelInvocationTrail(
        outcome: Self.receipt(
          phase: .finalizing, purpose: AdmissionJob.conversationAnswer.rawValue,
          completed: true, characters: 2_400, usage: Self.usage(2_903, cached: 0))),
      present: { presented = $0 })

    await runtime.run(Self.snapshot(input: "안녕"))

    let telemetry = presented?.telemetry
    XCTAssertEqual(telemetry?.pccCalls, 3, "재시도가 요청 하나로 접혔다")
    XCTAssertEqual(telemetry?.inputCharacters, 5_400, "합이 아니라 마지막 호출만 남았다")
    XCTAssertEqual(telemetry?.maximumInputCharacters, 2_400)
    // 실패한 첫 시도는 사용량을 받지 못했다 — 그래서 총량은 **모른다.**
    XCTAssertEqual(telemetry?.tokenMeasuredCalls, 2)
    XCTAssertEqual(telemetry?.inputTokens, .some(nil), "재지 못한 호출이 있는데 총량이 섰다")
    XCTAssertEqual(telemetry?.measuredInputTokens, 4_745)
    XCTAssertEqual(telemetry?.processingLocation, .pccCompleted)
    // 다시 내서 성공한 차례의 첫 실패도 계측에 남는다.
    XCTAssertEqual(telemetry?.fallbackReason, "rateLimited")
  }

  // MARK: 조립

  private static func usage(_ input: Int, cached: Int) -> ModelTokenUsage {
    ModelTokenUsage(inputTokens: input, cachedInputTokens: cached, outputTokens: 64)
  }

  private static let scope = CapabilityScope.compile(registered: [.mailSearch, .mailRead])

  private static func context(
    profile: DynamicTurnProfile
  ) throws -> CompiledConversationContext {
    try ConversationContextCompiler().compile(
      profile: profile, userMessage: "안녕", now: now,
      calendar: Calendar(identifier: .gregorian))
  }

  /// 영수증들을 모아 둔 자리. 계측이 읽는 값은 이 합이다.
  private static func log(_ trail: ModelInvocationTrail) -> ModelUsageLog {
    var usage = ModelUsageLog()
    for receipt in trail.all { usage.record(receipt) }
    return usage
  }

  private static func receipt(
    phase: TurnPhase = .planning,
    purpose: String = AdmissionJob.conversationPlan.rawValue,
    completed: Bool,
    reason: String? = nil,
    characters: Int,
    usage: ModelTokenUsage? = nil
  ) -> ModelInvocationReceipt {
    ModelInvocationReceipt(
      phase: phase, purpose: purpose,
      requestedBackend: .privateCloud, resolvedBackend: .privateCloud,
      pccAttempted: true, pccCompleted: completed,
      onDeviceAttempted: false, onDeviceCompleted: false,
      fallbackReason: reason, inputCharacters: characters,
      latencyMilliseconds: 12, waitedMilliseconds: 0, usage: usage)
  }

  private static func snapshot(input: String) -> TurnContextSnapshot {
    TurnContextSnapshot(
      requestID: UUID(), accountID: "acct", conversationID: "conv", input: input,
      recentMessages: [], submittedAt: now,
      registeredCapabilities: [.mailSearch])
  }

  private func makeRuntime(
    supervisorTrail: ModelInvocationTrail,
    finalizerTrail: ModelInvocationTrail,
    present: @escaping @MainActor (ConversationTurnResult) -> Void
  ) -> TurnRuntime {
    TurnRuntime(
      dispatcher: ActionDispatcher(
        ledger: SilentActionLedger(), currentAccountID: { "acct" }),
      emit: { _ in },
      present: present,
      copy: .keysAsText,
      now: { Self.now },
      supervising: { _ in
        .decided(
          TurnDecision(status: .complete, plan: ActionPlan(steps: [], needs: nil)),
          supervisorTrail)
      },
      finalizing: { _, _ in
        FinalizationStep(
          answer: .written(
            headline: "안녕하세요", points: [], relevant: [], backend: .privateCloud),
          trail: finalizerTrail)
      })
  }
}

// MARK: - 대역

/// 원장 없이는 디스패처를 세울 수 없다. 이 시험은 도구를 돌리지 않는다.
private struct SilentActionLedger: ActionLedger {
  func replay(_ request: ActionRequest) throws -> ActionLedgerReplay? { nil }
  func claim(_ request: ActionRequest, at date: Date) throws -> ActionLedgerClaim {
    .granted(idempotencyKey: request.idempotencyKey)
  }
  func settle(
    idempotencyKey: String, state: ActionLedgerEntry.State, externalID: String?,
    summary: String, at date: Date
  ) throws {}
  func entry(idempotencyKey: String) throws -> ActionLedgerEntry? { nil }
  func deleteAll(accountID: String) throws {}
}
