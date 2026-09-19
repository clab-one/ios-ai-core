import XCTest

@testable import AgentKernel

/// L0 — **승인 카드는 무엇을 덮는지 말한다.**
///
/// 앞판의 카드는 바뀔 값만 들었다: `제목: 람다 스터디`. 그 값이 무엇을 덮는지는
/// 어디에도 없었으므로 맞는 일정을 고치는 승인과 엉뚱한 일정을 고치는 승인이
/// 화면에서 같아 보였다 — 허락은 대상을 아는 허락이어야 한다.
final class ApprovalPreviewTests: XCTestCase {
  /// 자격 없는 요청. 승인 문에서 멈춘다.
  private func request() -> ActionRequest {
    ActionRequest(
      capability: .calendarUpdate,
      arguments: ["eventID": .text("E1"), "title": .text("람다 스터디")],
      origin: .userExplicit, accountID: "local")
  }

  /// 지금의 값이 승인 요청에 실린다.
  func testApprovalCarriesTheCurrentTargetState() async {
    let dispatcher = ActionDispatcher(ledger: SilentLedger(), currentAccountID: { "local" })
    await dispatcher.register(PreviewingHandler(lines: ["제목: 람가 스터디", "시작: 9월 20일(토) 오후 7:00"]))
    guard case .waitingApproval(let approval) = await dispatcher.dispatch(request()) else {
      return XCTFail("승인 문에서 멈추지 않았다")
    }
    XCTAssertEqual(approval.before, ["제목: 람가 스터디", "시작: 9월 20일(토) 오후 7:00"])
    XCTAssertEqual(approval.preview.subject, "람다 스터디", "바뀔 값이 사라졌다")
  }

  /// **읽기 하나의 실패가 쓰기 전체를 세우지 않는다.** 권한이 없거나 대상이
  /// 사라졌을 때 승인은 그대로 서고, 카드는 바뀔 값만 든다.
  func testApprovalStillStandsWhenTheTargetCannotBeRead() async {
    let dispatcher = ActionDispatcher(ledger: SilentLedger(), currentAccountID: { "local" })
    await dispatcher.register(PreviewingHandler(lines: nil))
    guard case .waitingApproval(let approval) = await dispatcher.dispatch(request()) else {
      return XCTFail("읽기가 실패하자 승인이 사라졌다")
    }
    XCTAssertEqual(approval.before, [])
    XCTAssertEqual(approval.preview.subject, "람다 스터디")
  }

  /// 읽는 손이 없는 툴도 그대로 승인 문을 지난다 — `TargetPreviewing`은 선택이다.
  func testHandlerWithoutAPreviewHandStillRaisesApproval() async {
    let dispatcher = ActionDispatcher(ledger: SilentLedger(), currentAccountID: { "local" })
    await dispatcher.register(BlindHandler())
    guard case .waitingApproval(let approval) = await dispatcher.dispatch(request()) else {
      return XCTFail("승인 문에서 멈추지 않았다")
    }
    XCTAssertEqual(approval.before, [])
  }

  private struct PreviewingHandler: CapabilityHandler, TargetPreviewing {
    let capabilities: Set<CapabilityID> = [.calendarUpdate]
    let contracts: [CapabilityContract] = [
      CapabilityContract(.calendarUpdate, required: [.init("eventID")], optional: [.init("title")])
    ]
    /// `nil`은 읽지 못한 경우다 — 던진다.
    let lines: [String]?

    func currentTargetPreview(for request: ActionRequest) async throws -> [String] {
      guard let lines else { throw ActionError.notAuthorized(request.capability) }
      return lines
    }

    func perform(_ request: ActionRequest) async throws -> ActionReceipt {
      ActionReceipt(requestID: request.id, capability: request.capability, summary: "고쳤어요")
    }
  }

  private struct BlindHandler: CapabilityHandler {
    let capabilities: Set<CapabilityID> = [.calendarUpdate]
    let contracts: [CapabilityContract] = [
      CapabilityContract(.calendarUpdate, required: [.init("eventID")], optional: [.init("title")])
    ]

    func perform(_ request: ActionRequest) async throws -> ActionReceipt {
      ActionReceipt(requestID: request.id, capability: request.capability, summary: "고쳤어요")
    }
  }
}
