import AgentKernel
import Foundation


/// 성공한 새 실행이 없는 동안만 적용하는 정체 감지 창.
public enum TurnLimits {
  public static let maxIdleSupervisorIterations = 4
  public static let maxUnsuccessfulToolExecutions = 8
  public static let executionWindow: Duration = .seconds(180)
}

/// 이 차례에 Private Cloud Compute를 몇 번 쓸 수 있는가.
///
/// 예전 값은 둘이었다(계획 한 번 + 합성 한 번). 감독 loop에서 그 값은 첫
/// 재계획에서 예산을 태우고, 그러면 답을 쓰는 단계가 언제나 기기 모델로
/// 떨어진다 — PCC가 참여한 차례를 PCC가 닫는다는 §19가 그 값에서는 성립하지
/// 않는다. 그래서 상한은 **되돌이 수 + 답 한 번**이다.
public struct PCCBudget: Sendable {
  /// 호출의 목적. 계측이 목적별로 갈라져야 "재계획에 PCC를 너무 쓰는가"를
  /// 판단할 수 있다(§21).
  public enum Purpose: String, Sendable, Hashable {
    case planning
    case replanning
    case finalizing
  }

  public static let perTurnLimit = TurnLimits.maxIdleSupervisorIterations + 1

  public private(set) var spent = 0
  public private(set) var spentByPurpose: [Purpose: Int] = [:]

  private var allowance = Self.perTurnLimit

  public init() {}

  public var remaining: Int { max(0, allowance - spent) }

  /// 새 수령증이 생겼을 때만 조사 창과 최종 답 한 번을 확보한다.
  public mutating func recordProgress() {
    allowance = max(allowance, spent + Self.perTurnLimit)
  }

  public mutating func consume(_ purpose: Purpose = .planning) -> Bool {
    guard remaining > 0 else { return false }
    spent += 1
    spentByPurpose[purpose, default: 0] += 1
    return true
  }
}

/// 이 차례에 대해 **내용 없이** 남기는 값.
///
/// 사용자의 글, 메일 본문, 채널 이름은 담지 않는다. 담는 것은 크기와 횟수와
/// 지연뿐이다 — 그 값들만으로 "PCC를 너무 자주 쓰는가"를 판단할 수 있다.
public struct TurnTelemetry: Sendable, Equatable {
  /// 이 차례가 어느 경로로 갔는가(`supervised`·`deterministic`·`automation`).
  public var profile: String = ""
  /// 마지막으로 답한 모델.
  public var backend: String = ""
  public var toolCount = 0
  /// 근거 조각 수.
  public var materialCount = 0
  public var estimatedInputCharacters = 0
  public var pccCalls = 0
  /// 감독자에게 물은 횟수. 재계획이 실제로 일어났는가를 이 값이 말한다.
  public var supervisorIterations = 0
  /// 기기 모델로 압축한 횟수와 그 분모(§33 Local Compaction Ratio).
  public var localExtractions = 0
  public var retrievedRows = 0
  /// 한 차례에서 **함께 보낸 독립 읽기**의 최대 수(§12 PR 4). 이 값이 늘 1이면
  /// fanout이 꺼진 것이고, 그 사실은 지연에만 조용히 나타난다.
  public var readFanout = 0
  /// route-only shadow 평가(§12 PR 4). `shadowRoute`는 규칙이 골랐을 능력들이고,
  /// `shadowAgreement`는 모델의 선택과 같았는가(`match`·`differs`·`none`)다.
  /// **shadow는 아무것도 실행하지 않는다** — 이 값은 비교 기록일 뿐이다.
  public var shadowRoute: String = ""
  public var shadowAgreement: String = ""
  /// 기기 모델 **입장 줄에서 기다린** 시간의 합과 목적별 나눔(§12 PR 6).
  ///
  /// 지연만 보면 느린 차례의 이유를 알 수 없다. 기기 모델은 하나뿐이고 계획·답·
  /// 값 뽑기가 한 줄에 서므로, 기다린 시간이 지연의 절반일 수 있다.
  public var modelWaitMilliseconds = 0
  /// 목적별 대기 시간(`conversationPlan=120 conversationAnswer=0` 꼴). 내용 없다.
  public var modelWaitByPurpose: String = ""
  public var latencyMilliseconds = 0
  public var fallbackReason: String = ""
  public var succeeded = false
  /// 처리 위치. 화면의 접근 영수증이 이 값에서 나온다(§36).
  public var processingLocation: ProcessingLocation = .entirelyOnDevice

  public init() {}

  private static let log = AgentHost.logger("orchestrator")

  public func emit() {
    Self.log.info(
      """
      turn profile=\(profile, privacy: .public) backend=\(backend, privacy: .public) \
      tools=\(toolCount, privacy: .public) materials=\(materialCount, privacy: .public) \
      input=\(estimatedInputCharacters, privacy: .public) pcc=\(pccCalls, privacy: .public) \
      iterations=\(supervisorIterations, privacy: .public) \
      compaction=\(localExtractions, privacy: .public)/\(retrievedRows, privacy: .public) \
      fanout=\(readFanout, privacy: .public) \
      shadow=\(shadowRoute, privacy: .public)/\(shadowAgreement, privacy: .public) \
      wait=\(modelWaitMilliseconds, privacy: .public) \
      waitByPurpose=\(modelWaitByPurpose, privacy: .public) \
      location=\(processingLocation.rawValue, privacy: .public) \
      latency=\(latencyMilliseconds, privacy: .public) \
      fallback=\(fallbackReason, privacy: .public) ok=\(succeeded, privacy: .public)
      """)
  }
}
