import Foundation

/// 모델이 답하지 못한 자리의 문장은 **호스트가 쓴다.**
///
/// 그 문장은 언제나 일어난 일만 말한다("찾지 못했어요", "만들었어요") — 하지
/// 않은 일을 말하지 않는다. 어느 문장을 쓸지는 차례의 상태가 정하므로 **판정은
/// 코어의 것**이고, 그 문장의 낱말과 언어는 **호스트의 것**이다.
///
/// 코어가 문구를 들고 있으면 코어를 붙이는 앱마다 자기 말투를 쓸 수 없고, 코어가
/// 판정을 넘기면 실패 사유마다 다른 말을 해야 한다는 규칙이 앱마다 갈라진다 —
/// 연결이 없어서 못 한 일에 "하지 못했어요"만 말하면 사용자는 고칠 방법을 모른다.
public struct TurnCopy: Sendable {
  /// 열쇠 하나를 사용자 언어의 한 줄로 옮긴다. 호스트의 문구 카탈로그를 부른다.
  ///
  /// **호출 시점에 언어를 읽어야 한다.** 설정에서 언어를 바꾼 뒤의 차례는 바뀐
  /// 언어로 말해야 하므로, 만들 때 붙인 언어를 들고 있으면 안 된다.
  private let resolve: @Sendable (String) -> String

  public init(_ resolve: @escaping @Sendable (String) -> String) {
    self.resolve = resolve
  }

  /// 문구를 주지 않는 호스트의 자리. 열쇠를 그대로 돌려준다 — 화면에 열쇠가 서면
  /// **문구를 붙이지 않았다는 사실이 보인다.** 조용히 빈 줄이 되지 않는다.
  public static let keysAsText = TurnCopy { $0 }

  public func found(hasReferences: Bool) -> String {
    resolve(hasReferences ? Key.answerFound : Key.answerNone)
  }

  public func completed(hasReferences: Bool, hasReceipts: Bool) -> String {
    if hasReferences { return resolve(Key.answerFound) }
    guard hasReceipts else { return resolve(Key.answerNone) }
    return resolve(Key.answerDone)
  }

  /// 일부만 마친 차례의 한 줄. 답이 아니라 **상태**다.
  public func partial() -> String { resolve(Key.progressPartial) }

  /// 실패 한 줄. **왜 못 했는지가 다르면 문장도 달라야 한다.**
  public func failure(reason: String) -> String {
    if reason == "cancelled" {
      return resolve(Key.progressCancelled)
    }
    if reason.hasSuffix("sendOutcomeUnknown") {
      return resolve(Key.progressReconciling)
    }
    // **미지원은 실패가 아니다.** 이 기기·계정으로는 에이전트를 열 수 없다는
    // 환경의 사실이고, "하지 못했어요"는 다시 눌러 보라는 말로 읽힌다.
    if reason == ModelFailureClassifier.unsupportedReason {
      return resolve(Key.answerUnsupported)
    }
    if reason.hasPrefix("notAuthorized") || reason == "noCapability" {
      return resolve(Key.answerNotConnected)
    }
    return resolve(Key.answerFailed)
  }

  /// 되물음. 자리마다 다른 문장을 쓴다 — "값이 필요해요"는 사용자가 무엇을
  /// 말해야 하는지 알려 주지 않는다.
  public func needs(_ argument: String) -> String {
    resolve(Key.needs[argument] ?? Key.needsOther)
  }

  /// 호스트가 **채워야 하는 열쇠 목록**.
  ///
  /// 카탈로그에 빠진 열쇠는 화면에서야 드러난다. 목록을 코어가 내놓으면 호스트는
  /// 자기 문구 파일과 대조하는 시험을 쓸 수 있다(JustSend: `LocalizationTests`).
  public enum Key {
    public static let answerFound = "conversation.answer.found"
    public static let answerNone = "conversation.answer.none"
    public static let answerDone = "conversation.answer.done"
    public static let answerNotConnected = "conversation.answer.notConnected"
    public static let answerFailed = "conversation.answer.failed"
    /// 이 기기·계정으로는 에이전트를 열 수 없다. **실패가 아니라 환경의 사실**이다.
    public static let answerUnsupported = "conversation.answer.unsupported"
    public static let progressCancelled = "thread.progress.cancelled"
    public static let progressReconciling = "thread.progress.reconciling"
    public static let progressPartial = "thread.progress.partial"
    public static let needsOther = "conversation.needs.other"

    /// 인자 이름 → 되물음 열쇠.
    ///
    /// 계약이 요구하는 **사용자만 줄 수 있는 자리**는 모두 여기 있어야 한다.
    /// 빠진 이름은 `needsOther`로 떨어지고, 화면은 "값이 하나 더 필요해요"라는
    /// 쓸모없는 문장을 세운다(실기 2026-09-16: PCC가 `url`을 물었고 그 문장이 났다).
    public static let needs: [String: String] = [
      "to": "conversation.needs.recipient",
      "recipient": "conversation.needs.recipient",
      "body": "conversation.needs.body",
      "text": "conversation.needs.body",
      "itemID": "conversation.needs.item",
      "start": "conversation.needs.time",
      "due": "conversation.needs.time",
      "title": "conversation.needs.title",
      "query": "conversation.needs.query",
      "channelID": "conversation.needs.channel",
      "messageID": "conversation.needs.message",
      "eventID": "conversation.needs.event",
      "url": "conversation.needs.url",
      "name": "conversation.needs.person",
    ]

    /// 코어가 부르는 열쇠 전부.
    public static var all: Set<String> {
      Set(
        [
          answerFound, answerNone, answerDone, answerNotConnected, answerFailed,
          answerUnsupported,
          progressCancelled, progressReconciling, progressPartial, needsOther,
        ] + needs.values)
    }
  }
}
