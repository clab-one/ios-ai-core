import AgentKernel
import XCTest

@testable import AgentOrchestration

/// L0 — **"다시 보내 주세요"는 아무것도 나가지 않았을 때만 말한다.**
///
/// 코드 리뷰 2026-09-18 P1: 판정이 `!record.receiptKeys.isEmpty`였다. 원격 쓰기는
/// 효과가 나가기 **전에** 체크포인트를 적고, 그 뒤에 원장 선점 → 공급자 요청 →
/// 수령증으로 간다. 그래서 전송이 나간 직후 죽은 차례는 수령증이 없고, 화면은
/// "끝나지 않았어요, 다시 보내 주세요"를 세웠다 — 사용자가 그대로 따르면 같은
/// 메일이 두 번 나간다.
///
/// 지금 판정의 근거는 **원장이 아는 그 열쇠의 상태**다.
final class InterruptedTurnTests: XCTestCase {
  private func record(
    status: TurnRunRecord.Status = .running,
    approvalFingerprint: String? = nil,
    effects: [TurnEffectCheckpoint] = []
  ) -> TurnRunRecord {
    TurnRunRecord(
      requestID: UUID().uuidString, accountID: "local", originDeviceID: "device",
      status: status, stateRevision: 1, input: "스티브에게 보고서 보내줘",
      effects: effects, pendingApprovalFingerprint: approvalFingerprint)
  }

  private func effect(_ state: ActionLedgerEntry.State?) -> InterruptedTurn.Effect {
    InterruptedTurn.Effect(key: "v2:key", capability: .mailSend, state: state)
  }

  /// **원장이 `pending`이다 = 보냈는지 모른다.** 다시 보내라고 말하지 않는다.
  func testPendingLedgerEntryIsNotSafeToRetry() {
    let turn = InterruptedTurn(
      record(effects: [TurnEffectCheckpoint(key: "v2:key", capability: .mailSend, state: .prepared)]),
      effects: [effect(.pending)])
    XCTAssertEqual(turn.recovery, .outcomeUnknown)
    XCTAssertFalse(turn.isSafeToRestart)
    XCTAssertEqual(turn.unknownEffectKeys, ["v2:key"])
  }

  /// 나간 것이 확인됐다. 다시 보내지 않고 결과를 확인하게 한다.
  func testCompletedLedgerEntryIsCommitted() {
    let turn = InterruptedTurn(record(), effects: [effect(.completed)])
    XCTAssertEqual(turn.recovery, .committed)
    XCTAssertFalse(turn.isSafeToRestart)
    XCTAssertTrue(turn.unknownEffectKeys.isEmpty)
  }

  /// 열쇠가 원장에 **없다** = 효과는 나가지 않았다. 사람이 다시 보내도 된다.
  func testAbsentLedgerEntryMeansNothingLeft() {
    let turn = InterruptedTurn(record(), effects: [effect(nil)])
    XCTAssertEqual(turn.recovery, .safeToRetry)
    XCTAssertTrue(turn.isSafeToRestart)
  }

  /// 결과를 아는 실패는 다시 보낼 수 있다.
  func testFailedLedgerEntryIsSafeToRetry() {
    let turn = InterruptedTurn(record(), effects: [effect(.failed)])
    XCTAssertEqual(turn.recovery, .safeToRetry)
  }

  /// 허락을 기다리다 멈췄고 나간 것은 없다.
  func testAwaitingApprovalWithoutEffects() {
    let turn = InterruptedTurn(
      record(status: .awaitingApproval, approvalFingerprint: "v1:abc"), effects: [])
    XCTAssertEqual(turn.recovery, .awaitingApproval)
    XCTAssertTrue(turn.wasAwaitingApproval)
    XCTAssertFalse(turn.isSafeToRestart)
  }

  /// **모르는 것이 가장 먼저다.** 하나가 나갔고 하나는 모르면, 그 차례는 모른다.
  func testUnknownOutcomeOutranksEverythingElse() {
    let turn = InterruptedTurn(
      record(status: .awaitingApproval),
      effects: [
        effect(.completed),
        InterruptedTurn.Effect(key: "v2:other", capability: .chatSend, state: .pending),
      ])
    XCTAssertEqual(turn.recovery, .outcomeUnknown)
    XCTAssertEqual(turn.unknownEffectKeys, ["v2:other"])
  }
}
