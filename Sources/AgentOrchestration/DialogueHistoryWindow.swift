import Foundation

/// Budgeted conversation context. This selector uses no language model.
/// It never creates a personal fact or treats an assistant sentence as a receipt.
public enum DialogueHistoryWindow {
  public static let maximumMessages = 12
  public static let characterBudget = 2_400

  public struct Entry: Sendable, Equatable {
    /// Used locally to retain whole request/response groups. Not sent to PCC.
    public let turnID: String
    public let role: String
    public let text: String
    /// **언제 말한 줄인가.** `2026-09-15 17:43` 같은 지역 시각 한 조각이고, 빈
    /// 값이면 실리지 않는다.
    ///
    /// 이 값이 없던 동안 대화는 시간이 없는 평면이었다: `"어제 얘기한 그 일정"`,
    /// `"아침에 말한 것"`을 모델이 짚을 근거가 문맥에 하나도 없었다(`<<<now>>>`는
    /// 지금만 말한다). 시각은 사용자 글이 아니라 **우리가 센 값**이므로 데이터
    /// 구획 안의 사실로 함께 간다.
    public let at: String

    public init(turnID: String, role: String, text: String, at: String = "") {
      self.turnID = turnID
      self.role = role
      self.text = text
      self.at = at
    }
  }

  private struct WireEntry: Encodable {
    let role: String
    let text: String
    let at: String?
  }

  private static let omitted = "{\"olderMessagesOmitted\":true}"
  /// 최신 턴 하나가 그 자체로 예산을 넘었다는 표시. 이 표시가 없으면 "조용히
  /// 사라졌다"와 "잘라서라도 실었다"를 구별할 수 없다.
  private static let truncatedMarker = "{\"recentTurnsTruncated\":true}"
  /// 보장 통과에서 한 줄에 남기는 글자 수의 하한. 이보다 작게 줄이면 실제
  /// 남는 문장이 없다.
  private static let minimumTextCharacters = 40

  /// The caller supplies chronological, account/conversation-scoped messages.
  /// Keep a contiguous suffix of complete turns; never cut off a negation at the
  /// end of a message, and never leap over an omitted recent correction.
  /// The budget is measured AFTER JSON escaping, not from source string lengths.
  public static func render(
    _ entries: [Entry], maximumMessages: Int = maximumMessages,
    characterBudget: Int = characterBudget
  ) -> String {
    guard maximumMessages > 0, characterBudget > 0, !entries.isEmpty else { return "" }
    let usable = entries.filter { $0.role == "user" || $0.role == "assistant" }
    guard !usable.isEmpty else { return "" }

    var groups: [[Entry]] = []
    for entry in usable {
      if let last = groups.last?.last, last.turnID == entry.turnID {
        groups[groups.count - 1].append(entry)
      } else {
        groups.append([entry])
      }
    }

    // Reserve both marker lines up front so their addition cannot exceed budget.
    let capacity = max(0, characterBudget - omitted.count - truncatedMarker.count - 2)
    var chosen: [[String]] = []
    var used = 0
    var count = 0
    var didOmit = false
    var didTruncate = false
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    func encode(_ role: String, _ text: String, _ at: String) -> String? {
      guard
        let data = try? encoder.encode(
          WireEntry(role: role, text: text, at: at.isEmpty ? nil : at)),
        let json = String(data: data, encoding: .utf8)
      else { return nil }
      // Preserve the original text in JSON while preventing forged section markers.
      return json.replacingOccurrences(of: "<", with: "\\u003c")
        .replacingOccurrences(of: ">", with: "\\u003e")
    }

    for group in groups.reversed() {
      // A host-side suffix may start with an orphaned assistant message.
      // Do not forward an answer after its user context was omitted.
      guard group.first?.role == "user" else { didOmit = true; break }
      var encoded: [String] = []
      var encodingFailed = false
      for entry in group {
        guard let json = encode(entry.role, entry.text, entry.at) else {
          encodingFailed = true
          break
        }
        encoded.append(json)
      }
      let cost = encoded.reduce(0) { $0 + $1.count + 1 }
      guard !encodingFailed, count + group.count <= maximumMessages,
        used + cost <= capacity
      else { didOmit = true; break }
      chosen.append(encoded)
      used += cost
      count += group.count
    }

    // **최신 턴 혼자 예산을 넘으면 잘라서라도 싣는다.** 위 통과는 턴을 통째로
    // 싣거나 버린다 — 최신 턴 혼자 예산을 넘으면 `chosen`이 비고 창은 표시 한
    // 줄만 남는다(최신 턴이 조용히 사라진다). 대상은 최신 그룹 **하나**뿐이다:
    // 2·3번째 턴의 "통째로 싣거나 버린다" 계약(`testWholeTurnIsKeptOrOmitted`)은
    // 건드리지 않는다 — `chosen`이 비어 있을 때만(=1차 통과가 최신 그룹조차
    // 싣지 못했을 때만) 이 통과가 돈다.
    if chosen.isEmpty, let newest = groups.last, newest.first?.role == "user" {
      let share = max(Self.minimumTextCharacters, capacity / newest.count)
      var encoded: [String] = []
      for entry in newest {
        guard let whole = encode(entry.role, entry.text, entry.at) else {
          didOmit = true
          break
        }
        var json = whole
        var truncated = false
        if whole.count > share {
          // 뒤에서부터 남긴다 — 파일이 선언한 "메시지 끝의 부정을 자르지
          // 않는다" 계약을 지키려면 꼬리를 남겨야 한다.
          var kept = min(entry.text.count, share)
          while true {
            let body = "…" + String(entry.text.suffix(kept))
            guard let candidate = encode(entry.role, body, entry.at) else { break }
            json = candidate
            if json.count <= share || kept <= Self.minimumTextCharacters { break }
            kept = kept * 3 / 4
          }
          truncated = true
        }
        let cost = json.count + 1
        guard count + 1 <= maximumMessages, used + cost <= capacity else {
          didOmit = true
          break
        }
        encoded.append(json)
        used += cost
        count += 1
        if truncated { didTruncate = true }
      }
      if !encoded.isEmpty { chosen = [encoded] }
    }

    var lines = chosen.reversed().flatMap { $0 }
    if didTruncate { lines.insert(truncatedMarker, at: 0) }
    if didOmit { lines.insert(omitted, at: 0) }
    let result = lines.joined(separator: "\n")
    // Only unusually tiny custom budgets reach this branch. No partial JSON escapes.
    guard result.count <= characterBudget else { return "" }
    return result
  }
}
