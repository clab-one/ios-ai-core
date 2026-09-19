import AgentKernel
import XCTest

@testable import AgentOrchestration

/// `docs/REMAINING_WORK.ko.md` P3 "실행 종료 후 run grant 완전 폐기" ·
/// "계정 전환 후 이전 실행 권한 폐기".
///
/// **승인은 계정 epoch에 묶인다.** 사람이 승인 버튼을 누르기 전에 계정이 바뀌면
/// (로그아웃·전환·재인증), 그 승인은 더 이상 유효한 자격이 아니어야 한다 — 그렇지
/// 않으면 "지민에게 메일 보내줘"를 승인 대기 중에 계정을 바꾼 사람이 방금 로그인한
/// 계정 이름으로 그 메일을 보내게 된다.
///
/// **`AssistantAccountEpoch`는 프로세스 전역 단조 카운터다**(`invalidate()`는 값을
/// 늘리기만 하고 되돌리지 않는다). 이 시험이 그 값을 올려도 다른 시험엔 영향이
/// 없다 — 다른 모든 호출자는 자기 실행 시점의 `AssistantAccountEpoch.current`를
/// 새로 읽어 쓰지, 특정 절대값을 기대하지 않는다(코드베이스 전체 확인: 절대값을
/// 단정하는 시험 없음).
@available(iOS 26.0, *)
@MainActor
final class AccountEpochRevocationTests: XCTestCase {
  private static let now = Date(timeIntervalSince1970: 1_789_610_400)

  /// **핵심 시험.** 승인 문이 선 뒤, 사람이 누르기 전에 계정이 바뀌면(epoch 증가)
  /// 그 승인은 실행되지 않는다 — 효과는 나가지 않고, 원장에도 완료로 남지 않는다.
  func testApprovalIssuedBeforeEpochChangeCannotExecuteAfter() async throws {
    let send = FixtureTool(
      .mailSend, required: [.init("to"), .init("body")], optional: [.init("subject")]
    ) { _ in [] }
    let ledger = ScenarioLedger()
    let dispatcher = ActionDispatcher(ledger: ledger, currentAccountID: { "acct" })
    await dispatcher.register(send)

    final class Box {
      var approvals: [ActionApprovalRequest] = []
      var result: ConversationTurnResult?
    }
    let box = Box()

    let runtime = TurnRuntime(
      dispatcher: dispatcher,
      emit: { envelope in
        if case .awaitingApproval(let approval) = envelope.event {
          box.approvals.append(approval)
        }
      },
      present: { box.result = $0 },
      copy: .keysAsText,
      now: { Self.now },
      supervising: { _ in
        .decided(
          TurnDecision(
            status: .working,
            plan: ActionPlan(
              steps: [
                PlannedStep(
                  capability: .mailSend,
                  arguments: [
                    "to": .text("jimin@example.com"), "body": .text("보낼 글"),
                  ])
              ], needs: nil)),
          ModelInvocationTrail(outcome: Self.receipt(.planning)))
      },
      finalizing: { _, _ in
        FinalizationStep(
          answer: .written(headline: "보냈어요", points: [], relevant: [], backend: .privateCloud),
          trail: ModelInvocationTrail(outcome: Self.receipt(.finalizing)))
      })

    await runtime.run(
      TurnContextSnapshot(
        requestID: UUID(), accountID: "acct", conversationID: "conv",
        input: "지민에게 메일 보내줘", recentMessages: [], submittedAt: Self.now,
        registeredCapabilities: [.mailSend]))

    let pending = try XCTUnwrap(box.approvals.first, "승인 문이 서지 않았다")

    // **계정이 바뀌었다.** 사람이 아직 승인 버튼을 누르지 않은 사이.
    AssistantAccountEpoch.invalidate()

    let outcome = await dispatcher.approve(pending.id)
    await runtime.resume(pending, outcome: outcome)

    // 승인이 실행되지 않았다 — 계정이 바뀐 뒤의 승인은 효과를 내지 않는다.
    if case .completed = outcome {
      XCTFail("계정이 바뀐 뒤에도 이전 승인이 그대로 실행됐다 — 자격이 폐기되지 않았다")
    }
    XCTAssertTrue(send.requests.isEmpty, "계정이 바뀐 뒤에 도구가 실제로 불렸다")

    // 원장에도 완료로 남지 않는다 — "메일을 보냈다"는 사실이 조작되지 않는다.
    let key = "\(pending.request.turnID.uuidString)#" +
      ActionFingerprint.call(pending.request.capability, pending.request.arguments, binding: pending.request.binding)
    let entry = try ledger.entry(idempotencyKey: key)
    XCTAssertNotEqual(
      entry?.state, .completed,
      "계정이 바뀐 뒤의 승인인데 원장에 완료로 남았다 — 다른 계정 이름으로 보낸 것처럼 보일 위험")
  }

  private static func receipt(_ phase: TurnPhase) -> ModelInvocationReceipt {
    ModelInvocationReceipt(
      phase: phase, purpose: AdmissionJob.conversationPlan.rawValue,
      requestedBackend: .privateCloud, resolvedBackend: .privateCloud,
      pccAttempted: true, pccCompleted: true, onDeviceAttempted: false,
      onDeviceCompleted: false, fallbackReason: nil, inputCharacters: 0,
      latencyMilliseconds: 0)
  }
}
