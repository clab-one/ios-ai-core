import AgentKernel
import Foundation

/// 차례 하나가 대화에 남기는 **줄들**.
///
/// 순서는 사용자 → 도구 → 조수다. 사용자 차례는 이미 정본 ingress가 적었으므로
/// (`CanonicalIngressService.persist`) 여기서는 그 뒤의 두 줄만 만든다.
///
/// 식별자를 요청 id에서 **결정론적으로** 만드는 것이 이 타입의 요점이다. 저장소는
/// `(accountID, requestID)`로 멱등을 지키므로(`GRDBConversationRepository`의
/// `existingMessage`), 같은 차례를 다시 마쳐도 — 앱을 다시 띄워 자동화가 같은
/// 실행을 이어받아도 — 대화에 줄이 두 벌 생기지 않는다.
public enum ConversationTurnTranscript {
  /// 도구 줄의 요청 id.
  public static func toolRequestID(_ turnID: String) -> String { "\(turnID):tool" }
  /// 조수 줄의 요청 id.
  public static func assistantRequestID(_ turnID: String) -> String { "\(turnID):assistant" }

  /// 도구 줄에 담는 한 줄. **바깥 글을 담지 않는다** — 담는 것은 무엇을 불렀고
  /// 무엇이 돌아왔는가뿐이다. 회수한 내용의 정본은 Item과 산출물이다(§11).
  public static func digest(_ steps: [ConversationTurnResult.Step]) -> String {
    steps.map { step in
      "\(step.capability.rawValue)=\(step.succeeded ? "ok" : step.reason)"
    }.joined(separator: " ")
  }

  /// 조수 줄의 본문. 결론 한 줄과 항목이 줄바꿈으로 이어진다.
  public static func answer(_ result: ConversationTurnResult) -> String {
    ([result.headline] + result.points.map(\.text))
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: "\n")
  }

  public static func messages(
    for result: ConversationTurnResult,
    accountID: String,
    conversationID: String,
    at date: Date = Date()
  ) -> [ConversationMessage] {
    let turnID = result.requestID.uuidString
    var messages: [ConversationMessage] = []
    if !result.steps.isEmpty {
      let requestID = toolRequestID(turnID)
      messages.append(
        ConversationMessage(
          id: ConversationMessageIdentity.messageID(
            accountID: accountID, requestID: requestID),
          accountID: accountID,
          conversationID: conversationID,
          requestID: requestID,
          role: .tool,
          text: digest(result.steps),
          createdAt: date))
    }
    // 실행 상태는 typed artifact에 남는다. 조수 줄에는 실제 답·되묻기만 남겨
    // artifact를 읽지 못했을 때 상태 문구가 완료된 답으로 승격되지 않게 한다.
    guard result.isSynthesizedAnswer || result.phase == .awaitingUser else { return messages }
    let answerText = answer(result)
    guard !answerText.isEmpty else { return messages }
    let requestID = assistantRequestID(turnID)
    messages.append(
      ConversationMessage(
        id: ConversationMessageIdentity.messageID(accountID: accountID, requestID: requestID),
        accountID: accountID,
        conversationID: conversationID,
        requestID: requestID,
        role: .assistant,
        text: answerText,
        createdAt: date))
    return messages
  }
}
