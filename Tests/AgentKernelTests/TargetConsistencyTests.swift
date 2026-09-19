import XCTest

@testable import AgentKernel

/// L0 — **효과 직전에 대상을 다시 본다.**
///
/// 코드 리뷰 2026-09-18 P1: 재확인의 문이 `isIrreversible`이었다. 그래서
/// `calendar.update`·`reminders.update`는 대상을 다시 보지 않았고, 사람이 승인
/// 카드를 보는 사이 다른 앱에서 고친 일정을 우리가 덮었다. 되돌릴 수 없는지와
/// "그 사이 바뀌었는지"는 다른 물음이다.
final class TargetConsistencyTests: XCTestCase {
  /// 사람이 대상과 내용을 명시한 지시. 자격을 실어 승인 문을 지나게 하고
  /// **그 뒤의 재확인만** 본다 — 승인의 불변식은 다른 시험이 본다.
  private func request(revision: String?) -> ActionRequest {
    let base = ActionRequest(
      capability: .calendarUpdate,
      arguments: ["eventID": .text("E1"), "title": .text("새 제목")],
      origin: .userExplicit, accountID: "local",
      targetRevision: revision)
    return base.with(
      authorization: AuthorizationProof.issue(for: base, source: .userInstruction))
  }

  /// 표가 수정을 재확인 대상으로 든다 — 되돌릴 수 있는 일이어도 그렇다.
  func testUpdatesDemandARevisionMatch() {
    XCTAssertEqual(CapabilityID.calendarUpdate.targetConsistency, .revisionMustMatch)
    XCTAssertEqual(CapabilityID.remindersUpdate.targetConsistency, .revisionMustMatch)
    XCTAssertEqual(CapabilityID.contactsUpdate.targetConsistency, .revisionMustMatch)
    XCTAssertEqual(CapabilityID.calendarDelete.targetConsistency, .revisionMustMatch)
    XCTAssertFalse(CapabilityID.calendarUpdate.isIrreversible, "이 시험의 전제가 사라졌다")
    // 만들기·보내기는 "그 사이 바뀔 대상"이 없다.
    XCTAssertEqual(CapabilityID.calendarCreate.targetConsistency, CapabilityID.TargetConsistency.none)
    XCTAssertEqual(CapabilityID.mailSend.targetConsistency, CapabilityID.TargetConsistency.none)
  }

  /// 관측한 판과 지금이 다르다 → **실행하지 않는다.**
  func testChangedTargetIsNotOverwritten() async {
    let ran = Box()
    let dispatcher = await dispatcher(verifierRevision: "200", ran: ran)
    let outcome = await dispatcher.dispatch(request(revision: "100"))
    guard case .failed(let reason) = outcome else {
      return XCTFail("바뀐 대상을 덮었다: \(outcome)")
    }
    XCTAssertTrue(reason.contains("targetChanged"), "사유가 다르다: \(reason)")
    XCTAssertFalse(ran.value, "실행이 일어났다")
  }

  /// 같으면 지나간다.
  func testUnchangedTargetRuns() async {
    let ran = Box()
    let dispatcher = await dispatcher(verifierRevision: "100", ran: ran)
    let outcome = await dispatcher.dispatch(request(revision: "100"))
    guard case .completed = outcome else { return XCTFail("같은 대상인데 막혔다: \(outcome)") }
    XCTAssertTrue(ran.value)
  }

  /// **볼 손이 없으면 실행하지 않는다.** 여기서 조용히 지나가면 "다시 본다"는
  /// 계약이 손을 달지 않은 툴에서만 사라진다 — 그것이 가장 위험한 실패다.
  func testMissingVerifierRefusesInsteadOfPassing() async {
    let ran = Box()
    let dispatcher = await dispatcher(verifierRevision: nil, ran: ran)
    let outcome = await dispatcher.dispatch(request(revision: "100"))
    guard case .failed(let reason) = outcome else {
      return XCTFail("재확인 없이 실행됐다: \(outcome)")
    }
    XCTAssertTrue(reason.contains("targetVerificationUnavailable"), "사유가 다르다: \(reason)")
    XCTAssertFalse(ran.value, "실행이 일어났다")
  }

  /// 관측한 판이 없으면 지나간다 — 공급자가 revision을 주지 않는 경우이고,
  /// 그 부재는 기능 차단 사유가 아니다(§4.4).
  func testNoObservedRevisionStillRuns() async {
    let ran = Box()
    let dispatcher = await dispatcher(verifierRevision: nil, ran: ran)
    let outcome = await dispatcher.dispatch(request(revision: nil))
    guard case .completed = outcome else { return XCTFail("관측이 없는데 막혔다: \(outcome)") }
    XCTAssertTrue(ran.value)
  }

  // MARK: 조립

  private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
      lock.lock()
      defer { lock.unlock() }
      return flag
    }
    func raise() {
      lock.lock()
      flag = true
      lock.unlock()
    }
  }

  /// 재확인의 손을 **가진** 툴과 없는 툴.
  private struct VerifyingHandler: CapabilityHandler, TargetRevisionVerifying {
    let capabilities: Set<CapabilityID> = [.calendarUpdate]
    let contracts: [CapabilityContract] = [
      CapabilityContract(.calendarUpdate, required: [.init("eventID"), .init("title")])
    ]
    let revision: String
    let ran: Box

    func currentTargetRevision(for request: ActionRequest) async throws -> String? { revision }

    func perform(_ request: ActionRequest) async throws -> ActionReceipt {
      ran.raise()
      return ActionReceipt(
        requestID: request.id, capability: request.capability, summary: "고쳤어요")
    }
  }

  private struct BlindHandler: CapabilityHandler {
    let capabilities: Set<CapabilityID> = [.calendarUpdate]
    let contracts: [CapabilityContract] = [
      CapabilityContract(.calendarUpdate, required: [.init("eventID"), .init("title")])
    ]
    let ran: Box

    func perform(_ request: ActionRequest) async throws -> ActionReceipt {
      ran.raise()
      return ActionReceipt(
        requestID: request.id, capability: request.capability, summary: "고쳤어요")
    }
  }

  /// 자격은 요청이 들고 있다(`request(revision:)`). 여기서는 재확인의 손이
  /// 있는 툴과 없는 툴만 갈아 끼운다.
  private func dispatcher(
    verifierRevision: String?, ran: Box
  ) async -> ActionDispatcher {
    let dispatcher = ActionDispatcher(
      ledger: SilentLedger(), currentAccountID: { "local" })
    if let verifierRevision {
      await dispatcher.register(VerifyingHandler(revision: verifierRevision, ran: ran))
    } else {
      await dispatcher.register(BlindHandler(ran: ran))
    }
    return dispatcher
  }
}
