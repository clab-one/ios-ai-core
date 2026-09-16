import AgentKernel
import Foundation

/// PCC 한 호출이 받을 수 있는 **글자의 상한**.
///
/// 이 저장소의 정체가 이 값이다. 기기에서 줄이고 뽑는 모든 일은 "PCC에는 결정에
/// 필요한 최소 정보만 간다"를 위한 것이고, 그 문장이 주석이 아니라 규칙이 되려면
/// 상한이 **어디를 지나도 닫혀 있어야** 한다. 문맥을 조립하는 문은 하나이므로
/// (`ConversationContextCompiler.compile`) 그 문에서 이 값을 강제한다.
///
/// **글자는 토큰이 아니다.** 한국어는 대략 한 글자가 한 토큰이고 영어는 세~네
/// 글자가 한 토큰이므로(Apple TN3193), 같은 글자 수가 언어에 따라 서로 다른
/// 토큰을 태운다. 그래서 이 값의 일은 **호출 전 안전 게이트** 하나다. 실제 비용은
/// 호출 뒤에 `LanguageModelSession.Response.usage`가 토큰으로 돌려주고, 그 값이
/// 영수증에 남는다 — 글자를 토큰의 대용으로 쓰지 않는다.
public struct PCCContextBudget: Sendable, Equatable {
  /// 사용자 지시 한 번의 글자 상한.
  ///
  /// **자르지 않는다.** `"이 내용을 수정하지 말고 김철수에게 보내줘"`의 앞에 본문
  /// 4,000자가 붙어 있을 때 뒤를 자르면 지시 자체가 사라진다. 긴 내용의 정상
  /// 경로는 정본 캡처 → `attachedItemIDs` → 기기 읽기 → `Evidence`이고, 이 상한은
  /// 그 경로가 실패했을 때 원문이 PCC로 새는 것을 막는 **마지막 방벽**이다.
  public let requestCharacters: Int
  /// 지시 평면의 상한(`TurnInstructions`). 단계별 상수이고 사용자 글이 아니다.
  public let instructionCharacters: Int
  /// 지시를 뺀 조립 구획 전부의 상한. 구획별 상한의 **합**이다.
  public let assembledCharacters: Int

  public init(requestCharacters: Int, instructionCharacters: Int, assembledCharacters: Int) {
    self.requestCharacters = requestCharacters
    self.instructionCharacters = instructionCharacters
    self.assembledCharacters = assembledCharacters
  }

  /// `CompiledConversationContext.estimatedCharacters`가 넘을 수 없는 값.
  public var totalCharacters: Int {
    instructionCharacters + requestCharacters + assembledCharacters
  }

  // MARK: 구획별 예산

  /// `UntrustedText.forModelContext`가 감싸는 구획의 고정 비용(출처 이름 포함).
  static let dataSectionCharacters = 96
  /// `<<<name>>>` `<<<end>>>` 한 쌍과 줄바꿈.
  static let sectionMarkerCharacters = 24
  /// 이 조립이 세울 수 있는 구획의 최대 수(tools·now·recent·completed·coverage·
  /// anchors·evidence·request).
  static let maximumSections = 8
  /// 최근 차례 한 줄에 붙는 역할 낱말과 줄임표.
  static let recentTurnOverhead = 16
  /// 근거 한 조각 앞에 서는 번호(`[8]\n`).
  static let evidenceNumberCharacters = 8
  /// 고정점 한 줄. 슬롯 이름뿐이다 — **값은 실리지 않는다.**
  static let anchorLineCharacters = 24
  /// 능력 이름 한 줄.
  static let toolLineCharacters = 32
  /// 등록될 수 있는 능력의 수.
  static let toolLines = 48
  /// 시각 한 줄.
  static let clockCharacters = 96

  /// 이 런타임의 예산.
  ///
  /// 조립 상한을 숫자로 적지 않고 **구획 상한에서 계산한다.** 그래야 근거 상한을
  /// 줄이는 날(`Evidence.factLimit`·`evidenceLimit`) 예산이 함께 줄고, 새 구획을
  /// 예산 없이 더하면 시험이 깨진다 — 총량만 손으로 적으면 두 값이 갈라지고,
  /// 갈라진 예산은 예산이 아니다.
  public static let standard = PCCContextBudget(
    requestCharacters: 2_000,
    instructionCharacters: 2_000,
    assembledCharacters: assembled)

  static var assembled: Int {
    let tools = toolLines * toolLineCharacters
    let recent =
      ConversationContextCompiler.recentTurnLimit
      * (ConversationContextCompiler.recentTurnCharacterLimit + recentTurnOverhead)
    let coverage = ConversationContextCompiler.coverageCharacterLimit + dataSectionCharacters
    let anchors = ResolvableArgument.allCases.count * anchorLineCharacters
    let evidence =
      ConversationContextCompiler.evidenceLimit
      * (Evidence.contextCharacterLimit + dataSectionCharacters + evidenceNumberCharacters)
    return tools + clockCharacters + recent
      + ConversationContextCompiler.completedCharacterLimit + coverage + anchors + evidence
      + maximumSections * sectionMarkerCharacters
  }
}

/// 문맥을 세우지 못했다. **PCC를 부르기 전에** 멈춘다.
///
/// 조용히 자르는 선택지를 두지 않는다. 자른 문맥으로 호출하면 사용자가 시킨 일과
/// 다른 일이 계획되고, 그 차이는 어디에도 남지 않는다.
public enum ContextCompilationError: Error, Sendable, Equatable {
  /// 사용자 지시 하나가 상한을 넘었다. 정상 경로(정본 캡처 → 기기 읽기)가 놓친
  /// 입력이다.
  case requestTooLarge(actual: Int, limit: Int)
  /// 조립 결과가 예산을 넘었다. 구획 상한 중 하나가 예산 밖으로 자란 것이므로
  /// **코드의 결함**이고, 사용자에게 고칠 방법이 없다.
  case contextTooLarge(actual: Int, limit: Int)

  /// 계측과 문구가 읽는 열쇠. **이름은 여기 하나다** — 화면 문구가 자기 문자열을
  /// 들면 사유를 바꾸는 날 두 값이 갈라지고, 갈라진 사유는 다른 문장을 세운다.
  public static let requestTooLargeReason = "requestTooLarge"
  public static let contextTooLargeReason = "contextTooLarge"

  public var reason: String {
    switch self {
    case .requestTooLarge: return Self.requestTooLargeReason
    case .contextTooLarge: return Self.contextTooLargeReason
    }
  }
}
