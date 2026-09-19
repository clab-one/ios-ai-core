import XCTest

@testable import AgentKernel

/// L0 — **권한이 선언되지 않은 능력은 등록되지 않는다.**
///
/// 코드 리뷰 2026-09-18 P1: 코어의 표에 없는 이름은 `.unclassified`로 떨어졌고,
/// 그 값은 승인을 요구하지만 원장을 타지 않고 약속한 쓰기로 세어지지도 않았다.
/// 다른 앱이 `payment.send`를 들고 오면 **사람의 허락만 받은 채 crash-safe하지
/// 않은 외부 전송**이 성립한다. fail safe가 아니라 fail closed여야 한다.
final class CapabilityRegistrationTests: XCTestCase {
  /// 코어가 모르는 이름 + 권한 선언 없음 → **손이 있어도 등록되지 않는다.**
  func testCapabilityWithoutDeclaredAuthorityIsRefused() async {
    let capability = CapabilityID("payment.send.\(UUID().uuidString)")
    let dispatcher = ActionDispatcher(
      ledger: SilentLedger(), currentAccountID: { "local" })
    await dispatcher.register(
      StubHandler(
        capabilities: [capability],
        contracts: [CapabilityContract(capability, required: [.init("amount", .number)])]))

    let registered = await dispatcher.registeredCapabilities()
    let refused = await dispatcher.refusedCapabilities()
    XCTAssertFalse(registered.contains(capability))
    XCTAssertTrue(refused.contains(capability))

    let outcome = await dispatcher.dispatch(
      ActionRequest(
        capability: capability, arguments: ["amount": .number(1000)],
        origin: .modelPlan, accountID: "local"))
    guard case .failed(let reason) = outcome else {
      return XCTFail("등록되지 않은 능력이 실행됐다: \(outcome)")
    }
    XCTAssertTrue(reason.contains("unsupported"), "사유가 다르다: \(reason)")
  }

  /// 계약이 권한을 선언하면 등록된다 — 그리고 그 값에서 승인·원장·실행 등급이 나온다.
  func testDeclaredAuthorityRegistersAndDerivesThePolicy() async {
    let capability = CapabilityID("payment.send.\(UUID().uuidString)")
    let dispatcher = ActionDispatcher(
      ledger: SilentLedger(), currentAccountID: { "local" })
    await dispatcher.register(
      StubHandler(
        capabilities: [capability],
        contracts: [
          CapabilityContract(
            capability, authority: .leavesTheDevice,
            required: [.init("amount", .number)])
        ]))

    let registered = await dispatcher.registeredCapabilities()
    let refused = await dispatcher.refusedCapabilities()
    XCTAssertTrue(registered.contains(capability))
    XCTAssertTrue(refused.isEmpty)
    XCTAssertEqual(capability.authority, .leavesTheDevice)
    XCTAssertTrue(capability.requiresAuthorization)
    XCTAssertTrue(capability.isRemoteWrite, "원격 쓰기가 원장을 타지 않는다")
    XCTAssertEqual(capability.executionClass, .remoteWrite)

    // 승인 문을 지난다. 자격이 없으므로 실행되지 않는다.
    let outcome = await dispatcher.dispatch(
      ActionRequest(
        capability: capability, arguments: ["amount": .number(1000)],
        origin: .modelPlan, accountID: "local"))
    guard case .waitingApproval = outcome else {
      return XCTFail("사람의 허락 없이 실행됐다: \(outcome)")
    }
  }

  /// **권한에 대한 두 개의 답은 그 자체가 사고다.** 코어의 표와 어긋나는 선언은
  /// 싣지 않고, 그 능력은 등록되지 않는다.
  func testDeclarationConflictingWithTheCoreTableIsRefused() async {
    let dispatcher = ActionDispatcher(
      ledger: SilentLedger(), currentAccountID: { "local" })
    await dispatcher.register(
      StubHandler(
        capabilities: [.mailSend],
        contracts: [CapabilityContract(.mailSend, authority: .observes)]))

    let registered = await dispatcher.registeredCapabilities()
    let refused = await dispatcher.refusedCapabilities()
    XCTAssertFalse(registered.contains(.mailSend))
    XCTAssertTrue(refused.contains(.mailSend))
    XCTAssertEqual(CapabilityID.mailSend.authority, .leavesTheDevice, "코어의 표가 덮였다")
  }
}

struct StubHandler: CapabilityHandler {
  let capabilities: Set<CapabilityID>
  let contracts: [CapabilityContract]
  var onPerform: (@Sendable (ActionRequest) throws -> Void)?

  func perform(_ request: ActionRequest) async throws -> ActionReceipt {
    try onPerform?(request)
    return ActionReceipt(
      requestID: request.id, capability: request.capability, summary: "했어요")
  }
}

struct SilentLedger: ActionLedger {
  func replay(_ request: ActionRequest) throws -> ActionLedgerReplay? { nil }
  func claim(_ request: ActionRequest, at date: Date) throws -> ActionLedgerClaim {
    .granted(idempotencyKey: request.effectIdentity)
  }
  func settle(
    idempotencyKey: String, state: ActionLedgerEntry.State, externalID: String?,
    summary: String, at date: Date
  ) throws {}
  func entry(idempotencyKey: String) throws -> ActionLedgerEntry? { nil }
  func forget(idempotencyKey: String) throws {}
  func deleteAll(accountID: String) throws {}
}
