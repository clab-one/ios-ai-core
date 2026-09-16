import Foundation

/// **능력의 이름.** 도구 하나가 아니라 "무엇을 할 수 있는가"의 이름이다.
///
/// 공급자 이름을 넣지 않는다(`gmail.search`가 아니라 `mail.search`). 모델에게
/// 공급자별 API를 그대로 펼치면 도구 목록이 계정 수만큼 늘어나고, 계정을 하나
/// 더 연결할 때마다 모델의 문맥이 커진다. 어느 계정으로 보낼지는 코드
/// (`CapabilityRouter`)가 정할 일이고 모델이 정할 일이 아니다.
public struct CapabilityID: Hashable, Sendable, Codable, CustomStringConvertible,
  ExpressibleByStringLiteral
{
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: StringLiteralType) { self.rawValue = value }
  public var description: String { rawValue }

  /// 이름의 앞마디 — 어느 영역인가(`mail`, `calendar`, `memory`…).
  public var domain: String {
    String(rawValue.split(separator: ".").first ?? "")
  }

  // MARK: 기존 JustSend 능력 (새 서비스를 만들지 않고 기존 경로를 부른다)

  public static let memorySearch = CapabilityID("memory.search")
  public static let memorySave = CapabilityID("memory.save")
  public static let memoryRead = CapabilityID("memory.read")

  public static let contentIngest = CapabilityID("content.ingest")
  public static let contentRead = CapabilityID("content.read")
  public static let contentSummarize = CapabilityID("content.summarize")

  public static let recordingStart = CapabilityID("recording.start")
  public static let recordingStop = CapabilityID("recording.stop")
  public static let recordingRead = CapabilityID("recording.read")

  public static let artifactFind = CapabilityID("artifact.find")
  public static let artifactRead = CapabilityID("artifact.read")

  public static let sharePublish = CapabilityID("share.publish")
  public static let shareRevoke = CapabilityID("share.revoke")

  // MARK: Apple 기본 앱

  public static let calendarSearch = CapabilityID("calendar.search")
  public static let calendarCreate = CapabilityID("calendar.create")
  public static let calendarUpdate = CapabilityID("calendar.update")
  public static let calendarDelete = CapabilityID("calendar.delete")

  public static let remindersSearch = CapabilityID("reminders.search")
  public static let remindersCreate = CapabilityID("reminders.create")
  public static let remindersUpdate = CapabilityID("reminders.update")
  public static let remindersComplete = CapabilityID("reminders.complete")
  public static let remindersDelete = CapabilityID("reminders.delete")

  public static let peopleResolve = CapabilityID("people.resolve")
  public static let contactsRead = CapabilityID("contacts.read")
  public static let contactsCreate = CapabilityID("contacts.create")
  public static let contactsUpdate = CapabilityID("contacts.update")

  // MARK: 외부 서비스 (공급자 중립)

  public static let mailSearch = CapabilityID("mail.search")
  public static let mailRead = CapabilityID("mail.read")
  public static let mailSend = CapabilityID("mail.send")
  public static let mailReply = CapabilityID("mail.reply")

  public static let chatSearch = CapabilityID("chat.search")
  public static let chatRead = CapabilityID("chat.read")
  public static let chatSend = CapabilityID("chat.send")
  public static let chatReply = CapabilityID("chat.reply")

  // MARK: 웹 (공급자 중립)
  //
  // **모델이 브라우징하지 않는다.** 런타임이 열고, 기존 파서가 읽고, 축약기가
  // 줄인 뒤 모델에게 경계 있는 데이터만 준다(§10).

  public static let webSearch = CapabilityID("web.search")
  /// 주소 하나를 **정본 기록으로** 들인다. 기존 링크 수집 경로가 그대로 진다.
  public static let webFetch = CapabilityID("web.fetch")
  /// 주소 하나를 읽어 글만 돌려준다. 기록을 만들지 않는다.
  public static let webRead = CapabilityID("web.read")

  public enum ExecutionClass: String, Sendable, Codable {
    case readOnly, localWrite, remoteWrite, interactive
  }

  /// 병렬 관찰은 이 닫힌 읽기 목록에만 허용한다. 모르는 능력은 순차 실행한다.
  public var executionClass: ExecutionClass {
    switch self {
    case .memorySearch, .memoryRead, .contentRead, .recordingRead, .artifactFind, .artifactRead,
      .calendarSearch, .remindersSearch, .peopleResolve, .contactsRead,
      .mailSearch, .mailRead, .chatSearch, .chatRead, .webSearch, .webRead:
      return .readOnly
    case .memorySave, .contentIngest, .contentSummarize, .webFetch,
      .calendarCreate, .calendarUpdate, .calendarDelete,
      .remindersCreate, .remindersUpdate, .remindersComplete, .remindersDelete,
      .contactsCreate, .contactsUpdate:
      return .localWrite
    case .mailSend, .mailReply, .chatSend, .chatReply, .sharePublish, .shareRevoke:
      return .remoteWrite
    default:
      return .interactive
    }
  }

  /// 이 능력이 **되돌릴 수 없는 일**을 하는가.
  ///
  /// 삭제와 외부 전송이 그렇다. 보낸 메일은 회수할 수 없고 지운 일정은 되돌릴
  /// 수 없다 — 그 둘은 모델의 판단만으로 실행되지 않는다(`ApprovalPolicy`).
  public var isIrreversible: Bool {
    switch self {
    case .calendarDelete, .remindersDelete, .mailSend, .mailReply, .chatSend, .chatReply,
      .shareRevoke:
      return true
    default:
      return false
    }
  }

  /// 이 능력이 바깥 세계를 바꾸는가(읽기만 하는가의 반대).
  public var writesOutsideTheApp: Bool {
    switch domain {
    case "calendar", "reminders", "contacts", "mail", "chat":
      return !rawValue.hasSuffix(".search") && !rawValue.hasSuffix(".read")
        && rawValue != CapabilityID.peopleResolve.rawValue
    case "share":
      return true
    default:
      return false
    }
  }
}
