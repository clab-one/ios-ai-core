import AgentKernel
import Foundation
import FoundationModels

/// 한 요청을 **하나의 run으로 소유하는 실행기**(`docs/AGENT_RUNTIME_DESIGN.ko.md`
/// §책임 경계·§Journal과 복구).
///
/// 기존 `TurnRuntime`은 단계마다 새 세션을 만들어 "다음 한 수"를 묻는 감독 루프다.
/// 이 실행기는 그 반대다: 모델 세션 하나가 도구를 직접 물고 돌고, 우리는 그
/// 왕복을 journal에 적는다.
///
/// ## 지금 이 실행기가 맡는 범위
///
/// **읽기 전용 차례만.** 승인이 필요한 능력은 native tool loop에 올리지 않는다 —
/// SDK의 `Tool.call`은 생성 도중 불리므로 승인 대기 지점이 없고, 올리는 순간
/// 사람의 허락 없이 효과가 나갈 길이 열린다(`FoundationToolAdapter`가 그 경계를
/// 강제한다). 쓰기가 필요한 차례는 기존 계획·승인 경로가 계속 맡는다.
///
/// 그래서 이것은 `TurnRuntime`의 **대체가 아니라 병렬 경로**다. 설계가 요구한
/// 순서 그대로다: 새 런타임을 나란히 세우고, 인수 corpus를 지난 뒤에 제어권을
/// 넘긴다. 이름만 바꾼 wrapper를 전환 완료라고 부르지 않는다.
@available(iOS 26.0, *)
public final class AgentRunEngine {
  /// 이 실행이 남긴 것. 화면이 아니라 **호출자가 검증할 값**이다.
  public struct Outcome: Sendable {
    public let runID: String
    public let text: String
    /// 모델이 실제로 부른 도구들. 순서는 호출 순서다.
    public let toolCalls: [CapabilityID]
    /// 모델 응답까지 걸린 시간. 지연을 주장하려면 잰 값이 있어야 한다.
    public let latencyMilliseconds: Int
  }

  public enum Failure: Error, Sendable, Equatable {
    /// 이 기기에서 기기 모델을 쓸 수 없다. 다른 모델로 몰래 갈아타지 않는다.
    case modelUnavailable(String)
    /// 모델 호출 자체가 실패했다. 사유는 SDK가 준 문자열 그대로다.
    case generationFailed(String)
  }

  private let dispatcher: ActionDispatcher
  private let journal: (any AgentRunJournal)?
  private let model: SystemLanguageModel
  private let now: () -> Date

  public init(
    dispatcher: ActionDispatcher,
    journal: (any AgentRunJournal)? = nil,
    model: SystemLanguageModel = SystemLanguageModel.default,
    now: @escaping () -> Date = Date.init
  ) {
    self.dispatcher = dispatcher
    self.journal = journal
    self.model = model
    self.now = now
  }

  /// 이 요청을 native session 하나로 처리한다.
  ///
  /// - Parameter instructions: 세션 지시문. 도구 설명은 SDK가 스키마에서 만든다 —
  ///   여기에 도구 목록을 글로 다시 적지 않는다(두 벌이 되면 갈라진다).
  public func run(
    _ context: TurnContextSnapshot, instructions: String
  ) async throws -> Outcome {
    let runID = context.requestID.uuidString
    guard case .available = model.availability else {
      let reason = Self.reason(for: model.availability)
      recordRun(context, runID: runID, status: .failed)
      throw Failure.modelUnavailable(reason)
    }

    recordSession(context)
    recordRun(context, runID: runID, status: .running)
    appendEntry(runID: runID, sequence: 0, role: .user, text: context.input)

    let recorder = JournalToolRecorder(journal: journal, runID: runID, startingSequence: 1)
    let toolContext = NativeToolContext(
      accountID: context.accountID, conversationID: context.conversationID,
      turnID: context.requestID, accountEpoch: context.accountEpoch)
    let contracts = CapabilityContract.registered
      .filter { context.registeredCapabilities.contains($0.key) }
      .map(\.value)
    let tools = AgentModelSession.tools(
      contracts: contracts, descriptions: [:], dispatcher: dispatcher,
      context: toolContext, observer: recorder)

    let session = LanguageModelSession(model: model, tools: tools, instructions: instructions)
    let started = ContinuousClock.now
    do {
      let response = try await session.respond(to: context.input)
      // 초 단위로만 재면 1초 미만 호출이 전부 0으로 보인다 — 줄였는지 늘렸는지
      // 말할 수 없는 값은 계측이 아니다.
      let duration = started.duration(to: .now).components
      let elapsed = Int(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
      let text = response.content
      appendEntry(
        runID: runID, sequence: await recorder.nextSequence(), role: .assistant, text: text)
      recordRun(context, runID: runID, status: .completed)
      return Outcome(
        runID: runID, text: text, toolCalls: await recorder.calledCapabilities,
        latencyMilliseconds: elapsed)
    } catch {
      recordRun(context, runID: runID, status: .failed)
      throw Failure.generationFailed(String(describing: error))
    }
  }

  // MARK: journal

  private func recordSession(_ context: TurnContextSnapshot) {
    guard let journal, let sessionID = context.conversationID else { return }
    do {
      try journal.saveSession(
        AgentSessionRecord(sessionID: sessionID, accountID: context.accountID, createdAt: now()))
    } catch {
      // journal 실패는 실행을 죽이지 않는다 — 기존 `TurnRuntime`과 같은 규칙이다.
    }
  }

  private func recordRun(
    _ context: TurnContextSnapshot, runID: String, status: AgentRunRecord.Status
  ) {
    guard let journal else { return }
    do {
      try journal.saveRun(
        AgentRunRecord(
          runID: runID, sessionID: context.conversationID ?? "", accountID: context.accountID,
          accountEpoch: context.accountEpoch, status: status,
          transcriptRevision: status == .running ? 1 : 2, createdAt: now()))
    } catch {}
  }

  private func appendEntry(
    runID: String, sequence: Int, role: AgentTranscriptEntry.Role, text: String
  ) {
    guard let journal else { return }
    do {
      try journal.appendTranscript(
        AgentTranscriptEntry(
          runID: runID, sequence: sequence, role: role, text: text, createdAt: now()))
    } catch {}
  }

  private static func reason(for availability: SystemLanguageModel.Availability) -> String {
    switch availability {
    case .available: return "available"
    case .unavailable(let cause): return String(describing: cause)
    @unknown default: return "unknown"
    }
  }
}

/// SDK의 도구 왕복을 **journal의 줄로** 옮기는 자리.
///
/// SDK는 call ID를 주지 않는다(설계 §현재 확인된 사실). 그래서 `FoundationToolAdapter`가
/// 인자 지문으로 만든 id를 그대로 열쇠로 쓴다 — 같은 인자의 두 번째 호출이 같은
/// 열쇠가 되는 것은 원장의 멱등 계약과 같은 모양이고, 그 사실이 journal에서도
/// 읽힌다.
@available(iOS 26.0, *)
actor JournalToolRecorder: NativeToolObserver {
  private let journal: (any AgentRunJournal)?
  private let runID: String
  private var sequence: Int
  private(set) var calledCapabilities: [CapabilityID] = []
  /// 시작할 때 적어 둔 정규화 인자. 끝날 때 같은 열쇠로 다시 쓰므로 여기 없으면
  /// 완료 기록이 인자를 빈 값으로 **덮는다** — 실측(2026-09-19 시뮬레이터 실행)에서
  /// 그 자리가 비어 돌아왔다. 재실행 판정의 근거가 사라지는 자리다.
  private var argumentsByCall: [String: String] = [:]

  init(journal: (any AgentRunJournal)?, runID: String, startingSequence: Int) {
    self.journal = journal
    self.runID = runID
    self.sequence = startingSequence
  }

  func nextSequence() -> Int {
    sequence += 1
    return sequence
  }

  func toolStarted(callID: String, capability: CapabilityID, arguments: [String: ActionValue]) {
    calledCapabilities.append(capability)
    let encoded = Self.encode(arguments)
    argumentsByCall[callID] = encoded
    save(
      ToolInvocationRecord(
        callID: callID, runID: runID, capability: capability,
        fingerprint: callID, state: .running,
        arguments: encoded))
  }

  func toolFinished(callID: String, capability: CapabilityID, outcome: ActionOutcome) {
    let state: ToolInvocationRecord.State
    var receipt: String?
    var receiptID: String?
    switch outcome {
    case .completed(let value):
      state = value.ledgerUnsettled ? .outcomeUnknown : .completed
      receipt = Self.encode(value)
      receiptID = value.requestID.uuidString
    default:
      state = .failed
    }
    save(
      ToolInvocationRecord(
        callID: callID, runID: runID, capability: capability, fingerprint: callID,
        state: state, receiptID: receiptID, arguments: argumentsByCall[callID] ?? "",
        receipt: receipt))
    let text = receipt ?? capability.rawValue
    sequence += 1
    append(
      AgentTranscriptEntry(
        runID: runID, sequence: sequence, role: .tool, text: text, toolCallID: callID))
  }

  private func save(_ record: ToolInvocationRecord) {
    do { try journal?.saveToolInvocation(record) } catch {}
  }

  private func append(_ entry: AgentTranscriptEntry) {
    do { try journal?.appendTranscript(entry) } catch {}
  }

  private static func encode(_ arguments: [String: ActionValue]) -> String {
    guard let data = try? JSONEncoder().encode(arguments),
      let text = String(data: data, encoding: .utf8)
    else { return "" }
    return text
  }

  private static func encode(_ receipt: ActionReceipt) -> String? {
    guard let data = try? JSONEncoder().encode(receipt) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
