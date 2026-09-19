import AgentKernel
import Foundation

/// `docs/REMAINING_WORK.ko.md` "문맥 압축과 기존 호출자 전환": context가 차면
/// 세션을 버리지 않고 transcript를 줄여 작업을 계속한다.
///
/// `ConversationContextCompiler.compile()`은 예산을 넘기면 **언제나 던진다**
/// (`docs/PCCContextBudget.swift` "조용히 자르는 선택지를 두지 않는다") — 그
/// 계약은 바꾸지 않는다. 이 파일은 그 앞에 서는 **재시도 껍데기**다: 던진
/// 이유가 근거 과다일 때만 근거를 줄여 다시 짓고, 그 밖의 이유(사용자 문장
/// 자체가 큼, 지시 평면 예산 붕괴)는 여전히 그대로 실패한다 — 그건 근거를
/// 줄여서 고칠 수 있는 문제가 아니다.
public struct CompactedContext: Sendable {
  public let context: CompiledConversationContext
  /// 이번 호출에서 뺀 근거 조각 수. 0이면 압축이 필요 없었다 — 정상 경로.
  ///
  /// **ledger의 근거는 지워지지 않는다.** 이 값은 "이번 PCC 호출에 보낸 조각
  /// 수"만 줄인 결과다. 원본 근거·receipt·출처 정체는 호출자가 그대로 들고
  /// 있고, 다음 반복에서 다시 전체 근거로 시도한다(§ compileWithCompaction
  /// 문서).
  public let droppedEvidenceCount: Int
}

/// 근거를 0개까지 줄여도 여전히 예산을 넘었거나, 애초에 근거 문제가 아니었다.
public enum ContextCompactionError: Error, Sendable, Equatable {
  case unrecoverable(ContextCompilationError)

  /// 안쪽 사유를 그대로 편다. 호출자는 `compile()`을 직접 부르던 때와 같은
  /// 문구로 실패를 적는다 — 압축을 껴도 사유 문구의 정체는 하나다.
  public var reason: String {
    switch self {
    case .unrecoverable(let inner): return inner.reason
    }
  }
}

extension ConversationContextCompiler {
  /// `compile()`을 부르고, 근거 과다로 실패하면(`assembledTooLarge`/
  /// `contextTooLarge`) **가장 관련도 낮은 조각부터** 하나씩 빼며 다시 짓는다.
  ///
  /// **`evidence`는 이미 관련도 순으로 왔다고 가정한다** — `EvidenceCompiler`가
  /// 그 정렬 계약을 진다(관련도 높은 조각이 앞). 그래서 뒤에서부터 뺀다: 가장
  /// 덜 중요한 조각이 가장 먼저 나간다.
  ///
  /// **`requestTooLarge`/`instructionsTooLarge`는 재시도하지 않는다.** 근거를
  /// 줄여도 사용자 문장 자체나 지시 평면의 크기는 줄지 않는다 — 다른 문제를
  /// 근거 압축으로 가리면 실제 원인이 사라진 것처럼 보인다.
  ///
  /// 루프는 반드시 끝난다: 매 반복마다 `remaining.count`가 하나씩 줄고,
  /// 빈 배열에서도 여전히 실패하면 `.unrecoverable`로 멈춘다.
  public func compileWithCompaction(
    profile: DynamicTurnProfile,
    userMessage: String,
    recentTurns: [ConversationMessage] = [],
    evidence: [Evidence] = [],
    coverage: [CoverageRecord] = [],
    anchoredSlots: [ResolvableArgument] = [],
    heldRecords: [HeldRecord] = [],
    knownFacts: [String] = [],
    earlierSummary: String? = nil,
    completed: String = "",
    voice: String? = nil,
    now: Date = Date(),
    calendar: Calendar
  ) throws(ContextCompactionError) -> CompactedContext {
    var remaining = evidence
    while true {
      do {
        let context = try compile(
          profile: profile, userMessage: userMessage, recentTurns: recentTurns,
          evidence: remaining, coverage: coverage, anchoredSlots: anchoredSlots,
          heldRecords: heldRecords, knownFacts: knownFacts,
          earlierSummary: earlierSummary, completed: completed, voice: voice,
          now: now, calendar: calendar)
        return CompactedContext(
          context: context, droppedEvidenceCount: evidence.count - remaining.count)
      } catch {
        switch error {
        case .assembledTooLarge, .contextTooLarge:
          guard !remaining.isEmpty else { throw ContextCompactionError.unrecoverable(error) }
          remaining.removeLast()
        case .requestTooLarge, .instructionsTooLarge:
          throw ContextCompactionError.unrecoverable(error)
        }
      }
    }
  }
}
