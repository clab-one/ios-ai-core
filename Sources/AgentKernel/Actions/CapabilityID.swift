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

  /// 앞 단계가 읽은 글을 **기기 모델이** 줄인다. 코어가 싣는 툴이다
  /// (`SummarizeTool`) — PCC로 원문을 올려 줄이면 비용과 프라이버시를 둘 다 잃는다.
  public static let textSummarize = CapabilityID("text.summarize")

  /// 앞 단계가 읽은 글을 **기기 모델이** 옮긴다. 코어가 싣는 툴이다
  /// (`TranslateTool`) — PCC로 원문을 올려 옮기면 대화 스크린샷·메일 본문이
  /// 기기를 떠나고, 화면이 그릴 산출물이 모델 근거와 섞인다.
  public static let textTranslate = CapabilityID("text.translate")

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
  /// 장소 하나를 **이름으로** 찾는다. 기기의 지도 검색이 그 자리를 안다 —
  /// 모델이 주소를 지어내는 길을 닫는다.
  public static let placesSearch = CapabilityID("places.search")

  /// 종목 하나의 **지금 시세**를 공급자에게 묻는다. 값은 공급자의 것이고(우리가
  /// 계산하지 않는다) 답에는 공급자 이름이 함께 선다 — 시세는 출처 없이 말할 수
  /// 없는 값이다(사용자 지적 2026-09-18: 시리는 증권 카드로 답한다).
  public static let financeQuote = CapabilityID("finance.quote")
  /// 좌표 하나의 **시간별 예보**를 공급자에게 묻는다. 값은 공급자의 것이고
  /// (우리가 예측하지 않는다) 답에는 발표 시각과 신선도가 함께 선다 — 날씨는
  /// 출처와 시각 없이 말할 수 없는 값이다(사용자 지시 2026-09-18).
  public static let weatherForecast = CapabilityID("weather.forecast")

  // MARK: 기기 안의 것들
  //
  // 애플의 프레임워크가 **앱에게 연** 자리들이다. 이름이 표에 없으면 호스트가
  // 손을 달아도 `.interactive`로 떨어져 승인·원장·완료 집계 밖으로 나간다 —
  // 그래서 능력은 손보다 먼저 이 표에 선다.

  /// 사진 보관함을 **날짜로** 훑는다. 픽셀은 나오지 않는다 — 나오는 것은 어느
  /// 사진이 있는지다.
  public static let photosSearch = CapabilityID("photos.search")
  /// 사진 한 장을 **기기에서 읽어** 글로 만든다(OCR). 원본은 기기를 떠나지 않는다.
  public static let photosRead = CapabilityID("photos.read")
  /// 사람이 고른 파일 하나를 읽어 글만 돌려준다. 고르는 일은 사람이 한다
  /// (iOS에는 앱이 파일 시스템을 훑는 공개 경로가 없다).
  public static let filesRead = CapabilityID("files.read")
  /// 복사판. 사람이 다른 앱에서 들고 온 글을 읽고, 만든 글을 그 자리에 놓는다.
  public static let clipboardRead = CapabilityID("clipboard.read")
  public static let clipboardWrite = CapabilityID("clipboard.write")

  /// 이 능력이 **무엇을 건드리는가.**
  ///
  /// 표가 하나여야 하는 이유는 실측이다. 분류가 세 군데에 흩어져 있던 동안
  /// (`executionClass`·`isIrreversible`·`isRemoteWrite`) 그 셋이 서로 어긋났다:
  /// `share.publish`는 실행 등급으로는 원격 쓰기인데 원장의 표에는 없었고
  /// (`mail`·`chat`·`social`만 있었다) 되돌릴 수 없는 목록에도 없었다 — 손을
  /// 달기만 하면 **승인도 원장도 없는 외부 발행**이 됐다(코드 리뷰 2026-09-18).
  /// 그래서 판정은 이 표 하나에서만 나오고, 나머지는 전부 여기서 유도한다.
  public enum Authority: String, Sendable, Codable {
    /// 읽는다. 아무것도 바뀌지 않는다.
    case observes
    /// **앱 자신의 정본**을 바꾼다(기억·수집한 기록). 사람의 것이 아니다.
    case changesAppState
    /// **사람의 것**을 바꾼다 — 캘린더·미리 알림·연락처·복사판·녹음.
    case changesUserState
    /// 기기 밖으로 나간다. 되돌릴 수 없고, 원장 없이는 실행하지 않는다.
    case leavesTheDevice
    /// 표에 없는 이름. **모르는 것은 위험한 것으로 센다** — 승인을 요구하고
    /// 병렬로 보내지 않는다.
    case unclassified
  }

  /// **코어가 아는 이름**의 권한. 모르는 이름은 `nil`이다 — 그 `nil`이 등록을
  /// 막는다(`ActionDispatcher.register`). 여기서 `.unclassified`를 돌려주면
  /// "모르는 능력"과 "표에 없다고 선언된 능력"을 구별할 수 없다.
  public var declaredAuthority: Authority? {
    switch self {
    case .memorySearch, .memoryRead, .contentRead, .recordingRead, .artifactFind, .artifactRead,
      .calendarSearch, .remindersSearch, .peopleResolve, .contactsRead,
      .mailSearch, .mailRead, .chatSearch, .chatRead, .webSearch, .webRead, .placesSearch,
      .photosSearch, .photosRead, .filesRead, .clipboardRead,
      // 요약은 **부작용이 없다.** 분류가 없던 동안 `.interactive`로 떨어져,
      // "약속한 쓰기"로 세어지고 완료 집합에는 들지 못해 모든 요약 차례가
      // `partial`로 닫혔다(실기 2026-09-16 `unkept:text.summarize`).
      .textSummarize, .textTranslate, .financeQuote, .weatherForecast:
      return .observes
    // 이 앱의 정본. 사람이 지운 적 없는 기록을 우리가 만드는 일이다.
    case .memorySave, .contentIngest, .contentSummarize, .webFetch:
      return .changesAppState
    // **사람의 것.** 되돌릴 수 있는지와 무관하다 — 남의 캘린더에 일정을 넣는
    // 일은 지우는 일과 같은 문을 지나야 한다(코드 리뷰 2026-09-18).
    case .calendarCreate, .calendarUpdate, .calendarDelete,
      .remindersCreate, .remindersUpdate, .remindersComplete, .remindersDelete,
      .contactsCreate, .contactsUpdate, .clipboardWrite,
      .recordingStart, .recordingStop:
      return .changesUserState
    case .mailSend, .mailReply, .chatSend, .chatReply, .sharePublish, .shareRevoke:
      return .leavesTheDevice
    default:
      return nil
    }
  }

  /// 이 능력의 권한. 등록에서 선언한 값이 먼저고, 없으면 코어의 표다.
  ///
  /// 실행에 이르는 능력은 **반드시** 둘 중 하나를 가진다 — 그렇지 않은 이름은
  /// 손이 있어도 등록되지 않는다. `.unclassified`는 그래서 "등록되지 않은
  /// 이름의 값"이고, 그 상태에서도 승인을 요구한다(두 겹으로 막는다).
  public var authority: Authority {
    CapabilityPolicy.shared.authority(for: self) ?? declaredAuthority ?? .unclassified
  }

  /// 손을 달 수 있는가. 권한이 선언되지 않은 이름은 **등록되지 않는다.**
  public var hasDeclaredAuthority: Bool {
    CapabilityPolicy.shared.authority(for: self) != nil || declaredAuthority != nil
  }

  /// 효과를 내기 **직전에** 대상을 다시 볼 것인가.
  ///
  /// 되돌릴 수 없는지와 다른 물음이다. 그 둘을 한 값으로 쓰던 동안
  /// `calendar.update`·`reminders.update`·`contacts.update`는 재확인 없이
  /// 실행됐다 — 사람이 승인 카드를 보는 사이 다른 앱에서 그 일정이 바뀌면,
  /// 우리는 방금 바뀐 내용을 덮는다(코드 리뷰 2026-09-18 P1).
  public enum TargetConsistency: String, Sendable, Codable {
    /// 다시 보지 않는다. 만들기·보내기는 "그 사이 바뀔 대상"이 없다.
    case none
    /// 계획 시점에 관측한 revision과 **같아야** 실행한다. 관측이 없으면(공급자가
    /// revision을 주지 않으면) 지나간다 — 그 부재는 기능 차단 사유가 아니다(§4.4).
    case revisionMustMatch
  }

  public var declaredTargetConsistency: TargetConsistency? {
    switch self {
    case .calendarUpdate, .calendarDelete,
      .remindersUpdate, .remindersComplete, .remindersDelete,
      .contactsUpdate, .mailReply, .chatReply, .shareRevoke:
      return .revisionMustMatch
    default:
      return nil
    }
  }

  public var targetConsistency: TargetConsistency {
    CapabilityPolicy.shared.targetConsistency(for: self) ?? declaredTargetConsistency ?? .none
  }

  /// **사람의 허락이 필요한가.**
  ///
  /// 되돌릴 수 있는지를 권한의 경계로 쓰던 동안 `calendar.create`는 모델의 판단
  /// 하나로 실행됐다. 그 경로의 입력에는 **바깥에서 온 글**이 있다(첨부·웹) —
  /// 지시 평면과 데이터 평면을 가르는 것은 프롬프트의 문장이고, 문장은 경계가
  /// 아니다. 그래서 경계를 값으로 세운다(코드 리뷰 2026-09-18 P1).
  public var requiresAuthorization: Bool {
    switch authority {
    case .observes, .changesAppState: return false
    case .changesUserState, .leavesTheDevice, .unclassified: return true
    }
  }

  public enum ExecutionClass: String, Sendable, Codable {
    case readOnly, localWrite, remoteWrite, interactive
  }

  /// 병렬 관찰은 이 닫힌 읽기 목록에만 허용한다. 모르는 능력은 순차 실행한다.
  /// **표는 하나다** — 이 값은 권한에서 유도된다.
  public var executionClass: ExecutionClass {
    switch authority {
    case .observes: return .readOnly
    case .changesAppState, .changesUserState: return .localWrite
    case .leavesTheDevice: return .remoteWrite
    case .unclassified: return .interactive
    }
  }

  /// 이 능력이 **되돌릴 수 없는 일**을 하는가.
  ///
  /// 삭제와 외부 전송이 그렇다. 이 값은 **권한의 문이 아니다**(그 일은
  /// `requiresAuthorization`이 한다) — 승인 카드가 어떤 낱말로 서야 하는지,
  /// 그리고 대상이 그 사이 바뀌었는지 다시 볼지를 정한다.
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
    authority == .changesUserState || authority == .leavesTheDevice
  }
}
