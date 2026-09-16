import Foundation

public enum ConversationMessageRole: String, Codable, Sendable {
  case user
  case assistant
  case system
  case tool
}

/// 대화 한 줄. **불변이다** — 고친 말은 새 줄이지 같은 줄의 다른 내용이 아니다.
///
/// 코어가 이 값을 소유하는 이유: 차례의 문맥은 최근 줄들에서 나오고
/// (`ConversationContextCompiler`), 차례가 끝나면 사용자 줄과 답 줄이 생긴다
/// (`ConversationTurnTranscript`). 그 둘이 코어에 있는 한 줄의 모양도 코어의 것이다.
///
/// 저장은 **코어의 일이 아니다.** 호스트가 자기 저장소의 규약을 확장으로 붙인다
/// (JustSend: `JustSendKit`이 GRDB 레코드 규약을 더한다). 코어는 스키마도, 표
/// 이름도, 마이그레이션도 모른다.
public struct ConversationMessage: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var accountID: String
  public var conversationID: String
  /// 대화 안의 순서. 0이면 저장소가 정한다 — 0이 아닌 값은 복원이므로 보존된다.
  public var sequence: Int
  /// 이 줄을 만든 차례. 사용자 줄과 답 줄이 **같은 값**을 든다(§4.1).
  public var requestID: String
  public var role: ConversationMessageRole
  public var text: String
  public var createdAt: Date

  public var content: String {
    get { text }
    set { text = newValue }
  }

  public init(
    id: String = UUID().uuidString,
    accountID: String,
    conversationID: String,
    sequence: Int = 0,
    requestID: String,
    role: ConversationMessageRole = .user,
    text: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.accountID = accountID
    self.conversationID = conversationID
    self.sequence = sequence
    self.requestID = requestID
    self.role = role
    self.text = text
    self.createdAt = createdAt
  }

  public init(
    id: String = UUID().uuidString,
    accountID: String,
    conversationID: String,
    sequence: Int = 0,
    requestID: String,
    role: ConversationMessageRole = .user,
    content: String,
    createdAt: Date = Date()
  ) {
    self.init(
      id: id,
      accountID: accountID,
      conversationID: conversationID,
      sequence: sequence,
      requestID: requestID,
      role: role,
      text: content,
      createdAt: createdAt
    )
  }
}

/// 대화 줄의 **결정론적 정체**.
///
/// 차례 하나가 남기는 줄의 id는 계정과 요청에서만 나온다. UUID를 새로 만들면 같은
/// 차례를 두 번 기록할 때 두 줄이 생기고, 그 둘은 화면에서 같은 말을 두 번 한다.
public enum ConversationMessageIdentity {
  public static func messageID(accountID: String, requestID: String) -> String {
    "message-\(accountID)-\(requestID)"
  }
}
