import Foundation
import OSLog

/// 능력 하나를 실제로 수행하는 손.
///
/// 구현은 **기존 JustSend 서비스와 Apple 프레임워크를 부른다.** 같은 일을 다시
/// 구현한 새 서비스를 만들지 않는다 — 그렇게 하면 정본 저장 경로가 둘이 된다.
public protocol CapabilityHandler: Sendable {
  var capabilities: Set<CapabilityID> { get }
  /// 인자를 검사하고 실행한다. 뜻이 둘 이상이면 **실행하지 않고**
  /// `ActionError.ambiguous`를 던진다.
  func perform(_ request: ActionRequest) async throws -> ActionReceipt
}

/// 실행 직전, 대상이 그 사이 바뀌지 않았는지 다시 보는 손.
///
/// 답장·수정·삭제의 대상은 계획 시점의 관측에서 온다. 그 사이에 스레드가
/// 옮겨지거나 메시지가 갱신되면 같은 인자가 다른 것을 가리킨다 — 그래서 효과를
/// 내기 전에 한 번 더 묻는다. `nil`은 "공급자가 revision을 주지 않는다"이며
/// 기능 차단 사유가 아니다(§4.4).
public protocol TargetRevisionVerifying: Sendable {
  func currentTargetRevision(for request: ActionRequest) async throws -> String?
}

/// 승인이 필요한지 정하는 규칙.
///
/// 되돌릴 수 없는 실행에는 **확인된 자격**이 필요하다(`AuthorizationProof`).
/// origin은 권한이 아니다 — 모델이 고른 전송은 자격이 없으므로 승인 문을 지나고,
/// 사용자가 대상과 내용을 명시한 지시는 그 자격으로 그대로 실행된다(§7.4).
/// 이미 기록된 효과의 replay는 이 정책에 들어오기 전에 판정한다.
public struct ApprovalPolicy: Sendable {
  public init() {}

  public func requiresApproval(_ request: ActionRequest, at now: Date = Date()) -> Bool {
    guard request.capability.isIrreversible else { return false }
    return !(request.authorization?.authorizes(request, at: now) ?? false)
  }
}

/// **모든 부작용이 지나가는 단 하나의 문.**
///
/// PCC도, 로컬 라우터도 저장소·EventKit·Gmail을 직접 만지지 않는다. 여기를
/// 지나가게 하면 멱등성·승인·계정 경계를 한 자리에서만 지키면 된다.
public actor ActionDispatcher {
  private static let log = Logger(
    subsystem: "dev.hyunminkim.justsend", category: "action-dispatcher")

  private var handlers: [CapabilityID: any CapabilityHandler] = [:]
  private var connectorReadinessProvider: (any ConnectorReadinessProviding)?
  private let policy: ApprovalPolicy
  /// 이미 끝난 실행의 수령증. **같은 열쇠는 다시 실행하지 않고 이 값을 돌려준다.**
  ///
  /// 프로세스 메모리다 — 앱이 죽으면 사라진다. 바깥으로 나간 쓰기의 재시도는
  /// 그래서 이 값이 아니라 원장이 막는다(`ledger`).
  private var receipts: [String: ActionReceipt] = [:]
  /// 승인을 기다리는 요청. 사람이 허락하면 같은 요청이 그대로 실행된다.
  private var pendingApprovals: [UUID: ActionApprovalRequest] = [:]
  private var identities: [String: ActionRequest] = [:]
  /// 실행 시점의 계정. 계정이 바뀐 뒤의 실행은 거절한다.
  private let currentAccountID: @Sendable () -> String?
  /// 바깥으로 나간 쓰기의 내구성 있는 원장. 없으면 **원격 쓰기를 실행하지 않는다** —
  /// 기록 없이 보낸 전송은 다음 재시도에서 두 번째 전송이 된다.
  private let ledger: (any ActionLedger)?

  public init(
    policy: ApprovalPolicy = ApprovalPolicy(),
    ledger: (any ActionLedger)? = nil,
    currentAccountID: @escaping @Sendable () -> String?
  ) {
    self.policy = policy
    self.ledger = ledger
    self.currentAccountID = currentAccountID
  }

  public func register(_ handler: any CapabilityHandler) {
    if let provider = handler as? any ConnectorReadinessProviding {
      connectorReadinessProvider = provider
    }
    for capability in handler.capabilities {
      handlers[capability] = handler
    }
  }

  public func registeredCapabilities() -> Set<CapabilityID> {
    Set(handlers.keys)
  }

  public func connectorReadiness(accountID: String, accountEpoch: UInt64) async -> [ConnectorReadinessSnapshot] {
    guard currentAccountID() == accountID, accountEpoch == AssistantAccountEpoch.current else { return [] }
    return await connectorReadinessProvider?.connectorReadiness(accountID: accountID, accountEpoch: accountEpoch) ?? []
  }

  /// 이 요청이 나갈 연결의 **사람이 읽는 이름**. readiness가 이미 들고 있는 값이다
  /// (`ConnectorReadinessSnapshot.label`, "화면에만 쓴다"). 없으면 nil이고, 승인
  /// 문은 계정 칸을 비운 채 나머지 대상을 보여 준다.
  private func bindingDisplay(
    for request: ActionRequest
  ) async -> ActionApprovalPreview.BindingDisplay? {
    guard let binding = request.binding else { return nil }
    let snapshots = await connectorReadiness(
      accountID: request.accountID, accountEpoch: request.accountEpoch)
    guard let snapshot = snapshots.first(where: { $0.binding == binding }),
      !snapshot.label.isEmpty
    else { return nil }
    return ActionApprovalPreview.BindingDisplay(
      account: snapshot.label, workspace: snapshot.workspaceLabel)
  }

  /// 실행. 승인이 필요하면 **실행하지 않고** 승인 문을 돌려준다.
  ///
  /// 순서가 계약이다: 스키마 → 계정/epoch → 멱등/replay → 손 → 승인. 스키마가 먼저인 이유는
  /// 인자가 모자란 요청은 승인 문을 세울 자격도 없기 때문이다 — 사람에게
  /// "보낼까요?"를 물은 뒤 받는 사람이 없어 실패하면 그 허락은 허공에 준 것이 된다.
  public func dispatch(_ request: ActionRequest) async -> ActionOutcome {
    let validated: ActionRequest
    switch CapabilityContract.normalize(request.arguments, for: request.capability) {
    case .success(let arguments):
      validated = request.with(arguments: arguments)
    case .failure(let violation):
      Self.log.info(
        "contract rejected capability=\(request.capability.rawValue, privacy: .public) reason=\(violation.reason, privacy: .public)"
      )
      return .failed(reason: describe(.invalidArguments(reason: violation.reason)))
    }
    guard isAccountCurrent(validated),
      validated.accountEpoch == AssistantAccountEpoch.current, !Task.isCancelled
    else { return .cancelled }
    if let prior = identities[validated.idempotencyKey],
      prior.accountID != validated.accountID || prior.capability != validated.capability
        || prior.arguments != validated.arguments || prior.binding != validated.binding
    { return .failed(reason: "actionIdentityConflict") }
    identities[validated.idempotencyKey] = validated
    if let receipt = receipts[validated.idempotencyKey] {
      Self.log.info(
        "idempotent hit capability=\(validated.capability.rawValue, privacy: .public)")
      return .completed(receipt)
    }
    if validated.capability.isRemoteWrite {
      guard let ledger else {
        return .failed(reason: describe(.failed(reason: "ledgerUnavailable")))
      }
      do {
        if let replay = try ledger.replay(validated) {
          guard isAccountCurrent(validated),
            validated.accountEpoch == AssistantAccountEpoch.current, !Task.isCancelled
          else { return .cancelled }
          return replayOutcome(replay, request: validated)
        }
      } catch {
        return .failed(reason: describe(.failed(reason: "ledgerUnavailable")))
      }
    }
    guard let handler = handlers[validated.capability] else {
      return .failed(reason: describe(.unsupported(validated.capability)))
    }
    guard isAccountCurrent(validated) else {
      return .failed(reason: describe(.accountChanged))
    }
    if policy.requiresApproval(validated) {
      let now = Date()
      if let approval = pendingApprovals.values.first(where: {
        $0.request == validated && $0.expiresAt > now
      }) { return .waitingApproval(approval) }
      // 승인 문에는 **사람이 읽는 이름**이 간다. 연결 id는 실행이 쓰고 화면에는
      // 내보내지 않는다(§2.7, §10.2). 이름을 찾지 못하면 계정 칸은 빈 채로 둔다.
      let display = await bindingDisplay(for: validated)
      let approval = ActionApprovalRequest(
        request: validated,
        title: validated.capability.rawValue,
        preview: ActionApprovalPreview.make(from: validated, display: display),
        isIrreversible: validated.capability.isIrreversible)
      pendingApprovals[approval.id] = approval
      return .waitingApproval(approval)
    }
    return await execute(validated, with: handler)
  }

  /// 사람이 허락한 뒤의 실행. 승인은 **그 요청 하나**에만 유효하다.
  ///
  /// 허락은 자격으로 바뀐다(`AuthorizationProof.userConfirmation`). 그 자격은 이
  /// 턴·계정·epoch·정규화된 대상 지문에 묶이므로, 승인 뒤 수신자나 본문이 바뀐
  /// 요청은 같은 허락으로 실행되지 않는다(§13 "전송 승인 뒤 수신자/본문 변경").
  public func approve(_ approvalID: UUID) async -> ActionOutcome {
    guard let approval = pendingApprovals.removeValue(forKey: approvalID) else {
      return .failed(reason: describe(.cancelled))
    }
    let request = approval.request
    guard approval.expiresAt > Date(), request.policyVersion == 1,
      request.accountEpoch == AssistantAccountEpoch.current, !Task.isCancelled,
      approval.argumentFingerprint == ActionFingerprint.arguments(request.arguments)
    else { return .cancelled }
    guard let handler = handlers[request.capability] else {
      return .failed(reason: describe(.unsupported(request.capability)))
    }
    guard isAccountCurrent(request) else {
      return .failed(reason: describe(.accountChanged))
    }
    let confirmed = request.with(
      authorization: AuthorizationProof.issue(for: request, source: .userConfirmation))
    return await execute(confirmed, with: handler)
  }

  public func reject(_ approvalID: UUID) {
    pendingApprovals.removeValue(forKey: approvalID)
  }

  private func execute(
    _ request: ActionRequest, with handler: any CapabilityHandler
  ) async -> ActionOutcome {
    guard !Task.isCancelled, isAccountCurrent(request),
      request.accountEpoch == AssistantAccountEpoch.current
    else { return .cancelled }
    // **효과를 내기 전에 대상을 한 번 더 본다.** 계획 시점의 관측과 지금이 다르면
    // 같은 인자가 다른 것을 가리킨다 — 실행하지 않고 재확인으로 돌린다(§PR5).
    if request.capability.isIrreversible, let expected = request.targetRevision,
      let verifier = handler as? any TargetRevisionVerifying
    {
      do {
        let current = try await verifier.currentTargetRevision(for: request)
        if let current, current != expected {
          Self.log.info(
            "target changed capability=\(request.capability.rawValue, privacy: .public)")
          return .failed(reason: describe(.failed(reason: "targetChanged")))
        }
      } catch {
        return .failed(reason: describe(.failed(reason: "targetVerificationUnavailable")))
      }
    }
    var ledgerKey = request.idempotencyKey
    // 바깥으로 나가는 쓰기는 **디스크를 지나** 선점한다.
    if request.capability.isRemoteWrite {
      switch claimRemoteWrite(request) {
      case .alreadyCompleted(let entry):
        return replayOutcome(.alreadyCompleted(entry), request: request)
      case .inFlight(let entry):
        return replayOutcome(.inFlight(entry), request: request)
      case .granted(let key):
        ledgerKey = key
      case .unavailable:
        return .failed(reason: describe(.failed(reason: "ledgerUnavailable")))
      }
    }
    do {
      let receipt = try await ActionExecutionScope.$current.withValue(request) {
        try Task.checkCancellation()
        return try await handler.perform(request)
      }
      // **일어난 일은 일어난 일이다.** 실행 중에 계정이 바뀌었다고 수령증을 버리면
      // 화면은 실패를 말하고, 사용자는 다시 보낸다 — 그래서 메일이 두 번 나간다
      // (리뷰 실측 P2). 수령증은 남기고, 바뀐 사실만 따로 알린다.
      receipts[request.idempotencyKey] = receipt
      settle(request, idempotencyKey: ledgerKey, state: .completed, receipt: receipt)
      guard isAccountCurrent(request) else {
        Self.log.info(
          "receipt kept after account switch capability=\(request.capability.rawValue, privacy: .public)"
        )
        return .completed(receipt)
      }
      return .completed(receipt)
    } catch let error as ActionError {
      Self.log.error(
        "action failed capability=\(request.capability.rawValue, privacy: .public)")
      // **결과를 아는 실패만** 실패로 적는다. 모르는 전송은 `pending`으로 남아
      // 다음 시도를 막는다 — 그것이 이 원장의 존재 이유다.
      if Self.isOutcomeKnown(error) {
        settle(request, idempotencyKey: ledgerKey, state: .failed, receipt: nil)
      }
      return error == .cancelled ? .cancelled : .failed(reason: describe(error))
    } catch {
      // 어댑터의 원문 오류를 그대로 로그에 남기지 않는다 — 토큰·주소가 섞일 수 있다.
      Self.log.error(
        "action threw capability=\(request.capability.rawValue, privacy: .public)")
      return .failed(reason: describe(.failed(reason: "unexpected")))
    }
  }

  private func replayOutcome(_ replay: ActionLedgerReplay, request: ActionRequest) -> ActionOutcome {
    switch replay {
    case .alreadyCompleted(let entry):
      Self.log.info("ledger replay capability=\(request.capability.rawValue, privacy: .public)")
      let receipt = Self.receipt(from: entry, request: request)
      receipts[request.idempotencyKey] = receipt
      return .completed(receipt)
    case .inFlight:
      Self.log.error("ledger in flight capability=\(request.capability.rawValue, privacy: .public)")
      return .failed(reason: describe(.failed(reason: "sendOutcomeUnknown")))
    }
  }

  /// 원장 선점의 결과. 원장이 없거나 쓰기에 실패한 경우를 한 값으로 든다.
  private enum RemoteWriteClaim {
    case granted(String)
    case alreadyCompleted(ActionLedgerEntry)
    case inFlight(ActionLedgerEntry)
    case unavailable
  }

  private func claimRemoteWrite(_ request: ActionRequest) -> RemoteWriteClaim {
    guard let ledger else { return .unavailable }
    do {
      switch try ledger.claim(request, at: Date()) {
      case .granted(let key): return .granted(key)
      case .alreadyCompleted(let entry): return .alreadyCompleted(entry)
      case .inFlight(let entry): return .inFlight(entry)
      }
    } catch {
      return .unavailable
    }
  }

  /// 결과를 원장에 못 박는다. 돌려주는 값은 **적혔는가**다.
  ///
  /// 여기 있던 `try?`가 이 원장에서 가장 위험한 자리였다. 메일은 나갔는데 결과가
  /// 적히지 않으면 그 열쇠는 `pending`으로 남고, 다음 시도는 "보낸 결과를 모른다"로
  /// 막힌다 — 두 번 보내지 않는 쪽으로 안전하게 실패하지만, 사용자는 이미 나간
  /// 메일을 실패로 읽는다. 그래서 한 번 다시 시도하고(대개 순간적인 `SQLITE_BUSY`다),
  /// 그래도 적히지 않으면 **오류로 남긴다** — 이 사실이 없으면 다음 시도가 왜
  /// 막히는지 아무도 알 수 없다.
  @discardableResult
  private func settle(
    _ request: ActionRequest, idempotencyKey: String, state: ActionLedgerEntry.State, receipt: ActionReceipt?
  ) -> Bool {
    guard request.capability.isRemoteWrite, let ledger else { return true }
    for attempt in 0...1 {
      do {
        try ledger.settle(
          idempotencyKey: idempotencyKey, state: state,
          externalID: receipt?.externalID, summary: receipt?.summary ?? "", at: Date())
        return true
      } catch {
        Self.log.error(
          "ledger settle failed capability=\(request.capability.rawValue, privacy: .public) state=\(state.rawValue, privacy: .public) attempt=\(attempt, privacy: .public)"
        )
      }
    }
    return false
  }

  /// 원장에 남은 성공을 수령증으로 되돌린다.
  ///
  /// 원장은 식별자와 한 줄만 든다 — 결과에 딸린 값(검색 개수·제목)은 다시
  /// 만들지 않는다. 재생에서 중요한 것은 "그 전송은 이미 일어났다"는 사실이다.
  private static func receipt(
    from entry: ActionLedgerEntry, request: ActionRequest
  ) -> ActionReceipt {
    ActionReceipt(
      requestID: request.id,
      capability: request.capability,
      externalID: entry.externalID,
      summary: entry.summary.isEmpty
        ? "\(request.capability.rawValue).replayed" : entry.summary,
      completedAt: entry.settledAt ?? entry.createdAt)
  }

  /// 이 실패는 **공급자가 확정한 것인가.**
  ///
  /// 인자 오류와 권한 거절은 요청이 공급자에 닿기 전이나 명시적 거절이다.
  /// 결과를 모르는 전송(`sendOutcomeUnknown`)만 원장에 손대지 않는다.
  private static func isOutcomeKnown(_ error: ActionError) -> Bool {
    switch error {
    case .failed(let reason):
      return !reason.lowercased().contains("sendoutcomeunknown")
    default:
      return true
    }
  }

  private func isAccountCurrent(_ request: ActionRequest) -> Bool {
    guard let active = currentAccountID() else { return true }
    return active == request.accountID
  }

  /// 오류를 사람이 읽을 한 줄로. **비밀은 담지 않는다.**
  private func describe(_ error: ActionError) -> String {
    switch error {
    case .unsupported(let capability): "unsupported:\(capability.rawValue)"
    case .notAuthorized(let capability): "notAuthorized:\(capability.domain)"
    case .ambiguous(let reason): "ambiguous:\(reason)"
    case .invalidArguments(let reason): "invalidArguments:\(reason)"
    case .accountChanged: "accountChanged"
    case .cancelled: "cancelled"
    case .failed(let reason): "failed:\(reason)"
    }
  }

}
