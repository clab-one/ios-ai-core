import Foundation

/// A PCC decision can be a conversation, a question, or a tool plan.
/// This is a control-plane value, not permission to execute a capability.
public enum DialogueResolution: Sendable, Equatable {
  case none
  case reply(String)
  case question(key: String, text: String)
  case invalid(reason: String)

  public static let maximumResponseCharacters = 6_000
  public static let invalidDecisionReason = "dialogue.invalidDecision"

  /// Inspect the RAW proposal before `ActionPlanValidator` discards invalid steps.
  /// The rule is one sentence: **the model's prose is used only when the decision
  /// carries nothing to execute.** Anything else drops the prose and runs the
  /// existing plan/finalization path, where the answer comes from receipts.
  ///
  /// Why dropping instead of failing: 실기 측정(iPhone 15 Pro, 실제 PCC,
  /// 2026-09-18) 8회 중 1회에서 `"여권 만료일을 …로 기억해줘"`에 대해 모델이
  /// `status=complete` + 1 step + `"…기억할게요."` 문장을 함께 냈다. 그 모양을
  /// 실패로 닫는 동안 `memory.save`는 돌지 않았고 화면에는 `"하지 못했어요"`가
  /// 섰다 — 모델의 잡음이 사용자의 차례를 죽인 것이다. 문장을 버리면 위험은
  /// 남지 않는다: 그 문장은 어디에도 표시되지 않고, 단계는 계약·승인·원장을
  /// 그대로 지난다.
  ///
  /// 무엇이 여전히 닫혀 있는가: 실행할 것을 든 결정의 문장은 **답으로 승격되지
  /// 않는다**(도구만 지우고 성공 문장을 통과시키는 길이 없다), 그리고 읽을 수
  /// 없는 status는 무엇을 하려 했는지 알 수 없으므로 실패로 닫는다.
  public static func resolve(
    status: String, response: String, needs: String, proposedStepCount: Int
  ) -> DialogueResolution {
    let mode = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = needs.trimmingCharacters(in: .whitespacesAndNewlines)
    guard proposedStepCount >= 0 else { return .invalid(reason: invalidDecisionReason) }

    switch mode {
    case "continue", "complete":
      // The legacy execution/finalization path. Prose here is never shown.
      return .none
    case "reply", "clarify":
      // A plan wins over prose. The sentence is dropped, not surfaced.
      guard proposedStepCount == 0, !text.isEmpty,
        text.count <= maximumResponseCharacters
      else { return .none }
      if mode == "reply" {
        return key.isEmpty ? .reply(text) : .none
      }
      // A missing-field name is a bounded label, never a second instruction.
      guard !key.isEmpty, key.count <= 80,
        key.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) })
      else { return .none }
      return .question(key: key, text: text)
    default:
      return .invalid(reason: invalidDecisionReason)
    }
  }
}
