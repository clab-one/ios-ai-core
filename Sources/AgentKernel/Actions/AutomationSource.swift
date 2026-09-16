import Foundation

/// 어디서 읽는가. 능력 이름으로 든다 — 실행은 대화와 **같은 능력 계층**을 쓴다.
///
/// 코어가 드는 이유: 차례가 읽은 출처가 그다음 자동화의 출처가 된다
/// (`ConversationAnchor.readSources`). 그 이음이 코어 안에 있으므로 출처의 모양도
/// 코어의 것이다. 언제·어떻게 다시 돌릴지(일정·알림)는 호스트의 것이다.
public struct AutomationSource: Codable, Equatable, Sendable {
  public var capability: CapabilityID
  public var query: String
  /// 쓰기 능력의 **대상**(받는 사람·채널). 읽기 출처에서는 빈 값이다.
  ///
  /// 이 자리가 있는 이유는 허가가 대상까지 못 박기 때문이다 — 대상이 없으면
  /// 허가와 맞춰 볼 것이 없고, 맞춰 볼 것이 없는 쓰기는 실행되지 않는다.
  public var target: String

  public init(capability: CapabilityID, query: String, target: String = "") {
    self.capability = capability
    self.query = query
    self.target = target
  }
}
