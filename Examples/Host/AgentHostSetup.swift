import AgentKernel
import AgentOrchestration
import Foundation
import SwiftUI

/// 호스트 한 곳에서 코어를 켜는 **가장 얇은 배선.** 그대로 복사해 이름만 바꿔도 돈다.
///
/// 채우는 자리는 여덟이다. 그 밖의 것 — 계획, 순서, 인자 채움, 승인, 근거 축약,
/// 문맥 조립, 실패의 이름 — 은 전부 코어가 한다.
///
/// ```
/// AgentHost.configure(신원)        ← 앱 init에서 가장 먼저
///   AgentRuntime.boot(설정)
///     submit(차례)  → onEvent/onResult
///     approve/reject(승인)
/// ```
enum AgentHostSetup {

  // MARK: 1) 신원 — 가장 먼저

  /// **`boot`보다 먼저** 설정한다. 로그 서브시스템·Keychain 서비스
  /// (`<bundle>.connector`)·기본값 접두사·근거 인용 스킴·OAuth 리다이렉트 스킴이
  /// 이 값에서 유도되고, `AgentRuntime.isSupported`도 이 값을 읽는다.
  ///
  /// 이미 출하된 앱은 **처음 쓰던 값을 명시로** 넘긴다 — 이름이 바뀌면 저장된
  /// 토큰을 찾지 못한다.
  static let identity = AgentHostIdentity(
    bundleIdentifier: "com.example.myagentapp",
    // 서명에 실린 값과 같아야 한다(`App/App.entitlements`). 갈리면 앱이 죽는다.
    privateCloudComputeEntitled: true)

  // MARK: 2) 문구 — 낱말과 언어는 호스트의 것

  /// 채워야 하는 열쇠는 `TurnCopy.Key.all`이 알려 준다. 그 집합과 이 표를 대조하는
  /// 시험을 쓰면 빠짐이 화면에서 드러나기 전에 잡힌다.
  static let strings: [String: String] = [
    TurnCopy.Key.answerFound: "찾았어요",
    TurnCopy.Key.answerNone: "찾지 못했어요",
    TurnCopy.Key.answerDone: "처리했어요",
    TurnCopy.Key.answerNotConnected: "연결이 없어서 못 했어요",
    TurnCopy.Key.answerFailed: "하지 못했어요",
    TurnCopy.Key.answerUnsupported: "이 기기에서는 지원하지 않아요",
    // 지시 하나가 문맥 예산(2,000자)을 넘었다. **사용자가 줄일 수 있는 실패**다.
    TurnCopy.Key.answerRequestTooLarge: "내용이 너무 길어요. 짧게 나눠 주세요",
    TurnCopy.Key.progressCancelled: "취소했어요",
    TurnCopy.Key.progressReconciling: "보낸 결과를 확인하는 중이에요",
    TurnCopy.Key.progressPartial: "일부만 마쳤어요",
    TurnCopy.Key.needsOther: "값이 하나 더 필요해요",
    "conversation.needs.recipient": "누구에게 보낼까요?",
    "conversation.needs.body": "무슨 내용으로 보낼까요?",
    "conversation.needs.item": "어느 기록을 말하는 걸까요?",
    "conversation.needs.url": "어느 페이지인가요? 주소를 알려주세요",
    "conversation.needs.person": "누구를 말하는 걸까요?",
    "conversation.needs.time": "언제로 할까요?",
    "conversation.needs.title": "제목을 알려주세요",
    "conversation.needs.query": "무엇을 찾을까요?",
    "conversation.needs.channel": "어느 채널에 보낼까요?",
    "conversation.needs.message": "어느 메시지를 말하는 걸까요?",
    "conversation.needs.event": "어느 일정을 말하는 걸까요?",
  ]

  // MARK: 3) 설정 — 자리를 비우면 그 능력이 등록되지 않는다

  @MainActor
  static func boot(
    tools: [any CapabilityHandler],
    memoryIndex: (any SemanticMemoryIndex)?,
    account: @escaping @Sendable () -> String?,
    onEvent: @escaping @MainActor @Sendable (TurnEventEnvelope) -> Void,
    onResult: @escaping @MainActor @Sendable (ConversationTurnResult) -> Void
  ) async -> AgentRuntime {
    await AgentRuntime.boot(
      AgentRuntimeConfiguration(
        host: identity,
        // 호스트의 손들. 계약 없는 능력은 실행되지 않는다.
        tools: tools,
        // 없으면 `memory.*`가 등록되지 않는다.
        memoryIndex: memoryIndex,
        // 없으면 `text.summarize`가 등록되지 않는다 — 원문을 그대로 보내는
        // 대체 경로는 만들어지지 않는다.
        summaryModel: FoundationSummaryModel(),
        // **공개 웹은 명시로 켠다.** 검색은 사용자 문장을 웹으로 내보내는 유일한
        // 능력이고, 읽기는 이 기기가 바깥이 고른 주소로 요청을 내는 능력이다.
        // 붙여넣은 주소만 읽는 앱은 `webSearch`를 nil로 두면 된다.
        webSearch: .standard,
        webRead: .standard,
        copy: TurnCopy { strings[$0] ?? $0 },
        // 없으면 복구를 포기한다(앱이 죽으면 그 차례는 사라진다).
        turnRuns: nil,
        // **없으면 원격 쓰기를 실행하지 않는다.** 기록 없이 보낸 전송은 다음
        // 재시도에서 두 번째 전송이 된다.
        actionLedger: InMemoryActionLedger(),
        currentAccountID: account,
        // 둘을 비워 두면 계획과 답은 **PCC**다. 대역을 꽂는 자리는 시험용이다.
        supervising: nil,
        finalizing: nil,
        onEvent: onEvent,
        onResult: onResult))
  }

  // MARK: 4) 차례 하나

  @MainActor
  static func submit(
    _ input: String, to runtime: AgentRuntime, account: String, conversation: String,
    recent: [ConversationMessage] = []
  ) async {
    // 열 수 없는 기기에서는 **기능이 없다고 말한다.** 실패로 그리지 않는다.
    guard AgentRuntime.isSupported(for: identity) else { return }
    await runtime.submit(
      TurnContextSnapshot(
        requestID: UUID(), accountID: account, conversationID: conversation,
        input: input, recentMessages: recent,
        registeredCapabilities: await runtime.dispatcher.registeredCapabilities()))
  }

  /// 승인 문을 사람이 눌렀다. **남은 단계부터** 이어 간다.
  @MainActor
  static func approve(_ approval: ActionApprovalRequest, on runtime: AgentRuntime) async {
    let outcome = await runtime.dispatcher.approve(approval.id)
    await runtime.approve(approval, outcome: outcome)
  }
}

/// 메모리 원장. **출하 앱은 이것을 쓰지 않는다** — 앱이 죽으면 기록이 사라지고,
/// 그 순간 "보냈는지 모르는 전송"을 다시 보내게 된다. 정본 저장소(GRDB·SQLite·
/// CoreData)로 바꾸는 것이 이 자리의 숙제다.
final class InMemoryActionLedger: ActionLedger, @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [String: ActionLedgerEntry] = [:]

  func replay(_ request: ActionRequest) throws -> ActionLedgerReplay? {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = entries[request.effectIdentity] else { return nil }
    return entry.state == .completed ? .alreadyCompleted(entry) : .inFlight(entry)
  }

  func claim(_ request: ActionRequest, at date: Date) throws -> ActionLedgerClaim {
    lock.lock()
    defer { lock.unlock() }
    // **열쇠는 효과의 정체다.** 차례의 id로 적으면 재시작 뒤의 재전송이 다른
    // 열쇠가 되고, 그 열쇠로는 "이미 나갔는가"를 물을 수 없다.
    let key = request.effectIdentity
    if let entry = entries[key] {
      switch entry.state {
      case .completed: return .alreadyCompleted(entry)
      // **결과를 모르는 전송은 자동으로 다시 보내지 않는다.**
      case .pending: return .inFlight(entry)
      case .failed: break
      }
    }
    entries[key] = ActionLedgerEntry(
      idempotencyKey: key, accountID: request.accountID,
      capability: request.capability, state: .pending, createdAt: date)
    return .granted(idempotencyKey: key)
  }

  func settle(
    idempotencyKey: String, state: ActionLedgerEntry.State, externalID: String?,
    summary: String, at date: Date
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = entries[idempotencyKey] else { return }
    entries[idempotencyKey] = ActionLedgerEntry(
      idempotencyKey: entry.idempotencyKey, accountID: entry.accountID,
      capability: entry.capability, state: state, externalID: externalID,
      summary: summary, createdAt: entry.createdAt, settledAt: date)
  }

  func entry(idempotencyKey: String) throws -> ActionLedgerEntry? {
    lock.lock()
    defer { lock.unlock() }
    return entries[idempotencyKey]
  }

  func forget(idempotencyKey: String) throws {
    lock.lock()
    defer { lock.unlock() }
    entries[idempotencyKey] = nil
  }

  func deleteAll(accountID: String) throws {
    lock.lock()
    defer { lock.unlock() }
    entries = entries.filter { $0.value.accountID != accountID }
  }
}
