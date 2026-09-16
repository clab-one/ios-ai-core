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
/// 증명하는 것은 **접기**다: 모델 자리가 내놓은 영수증 전부가 계측에 들어가는가,
/// 재지 못한 호출이 0으로 세어지지 않는가.
@available(iOS 26.0, *)
@MainActor
final class PCCInvocationAccountingTests: XCTestCase {
  private static let now = Date(timeIntervalSince1970: 1_789_610_400)

  // MARK: 1) 모아 둔 영수증의 합

  func testUnmeasuredCallsAreNotCountedAsZeroTokens() {
    var usage = ModelUsageLog()
    usage.record(
      Self.receipt(completed: true, characters: 900, usage: Self.usage(1_000, cached: 250)))
    // iOS 26이거나 응답을 받지 못한 호출. **사용량이 없다** — 0이 아니다.
    usage.record(Self.receipt(completed: false, reason: "timeout", characters: 900))

    XCTAssertEqual(usage.pccAttempts, 2)
    XCTAssertEqual(usage.inputTokens, 1_000)
    XCTAssertEqual(usage.maximumInputTokens, 1_000, "재지 못한 호출이 최대값을 0으로 끌어내렸다")
    XCTAssertEqual(usage.cachedInputTokens, 250)
    XCTAssertEqual(usage.inputCharacters, 1_800, "글자는 모든 물리 호출이 실었다")
    XCTAssertEqual(usage.maximumInputCharacters, 900)
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

  // MARK: 2) 차례가 영수증을 하나도 잃지 않는다

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
    XCTAssertEqual(telemetry?.inputTokens, 4_745)
    XCTAssertEqual(telemetry?.maximumInputTokens, 2_903)
    XCTAssertEqual(telemetry?.cachedInputTokens, 120)
    XCTAssertEqual(telemetry?.processingLocation, .pccCompleted)
    // 다시 내서 성공한 차례의 첫 실패도 계측에 남는다.
    XCTAssertEqual(telemetry?.fallbackReason, "rateLimited")
  }

  // MARK: 조립

  private static func usage(_ input: Int, cached: Int) -> ModelTokenUsage {
    ModelTokenUsage(inputTokens: input, cachedInputTokens: cached, outputTokens: 64)
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
