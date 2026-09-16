import AgentKernel
import Foundation


/// 성공한 새 실행이 없는 동안만 적용하는 정체 감지 창.
public enum TurnLimits {
  public static let maxIdleSupervisorIterations = 4
  public static let maxUnsuccessfulToolExecutions = 8
  public static let executionWindow: Duration = .seconds(180)
}

/// PCC 호출 상한(`PCCBudget`)은 없앴다.
///
/// 그 값은 "PCC를 아껄 것"을 전제로 계획·재계획·답쓰기에서 예산을 태우고, 다 쓰면
/// 기기 모델로 내려섰다. 오케스트레이터가 PCC 하나가 된 뒤 그 하강 경로는
/// **사용자가 말한 일을 다른 품질로 몰래 처리하는 길**이 된다. 되돌이 상한은
/// `TurnLimits`가 세고, 그 상한을 넘은 차례는 답을 쓰고 닫는다.

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
  /// **실제로 나간** PCC 호출들이 실은 글자 수의 합과 한 호출의 최대.
  ///
  /// 예전에는 `estimatedInputCharacters` 한 칸이었고, 단계마다 **덮어썼다** —
  /// 감독 3회 + 답 1회를 돈 차례가 기록에 남기는 값은 마지막 호출의 크기였다.
  /// 합만 보면 "호출이 많았다"와 "한 호출이 컸다"를 구별할 수 없으므로 둘을 든다.
  ///
  /// 부르기 전에 막힌 차례는 0이다. 조립한 문맥의 크기와 **기기를 떠난** 문맥의
  /// 크기는 다른 값이고, 이 칸은 뒤쪽이다.
  public var inputCharacters = 0
  public var maximumInputCharacters = 0
  /// **실측 토큰.** 모델이 돌려준 값이고(`Response.usage`) 글자 수의 환산이 아니다.
  ///
  /// **하나라도 재지 못했으면 nil이다.** 부분 합을 총량으로 적으면 재시도가 많은
  /// 차례가 실제보다 작게 잡히고, 그 값으로 뽑은 p50/p95는 문맥 축소 판단의
  /// 근거가 되지 못한다. 부분 값이 필요하면 `measuredInputTokens`를 본다.
  public var inputTokens: Int?
  public var maximumInputTokens: Int?
  public var cachedInputTokens: Int?
  /// 잰 호출만의 합. **부분 값**이라는 사실이 이름에 있다.
  public var measuredInputTokens = 0
  /// **물리** PCC 요청 수. 재시도는 호출이 하나 더인 것이다.
  public var pccCalls = 0
  /// 그중 사용량을 받은 호출 수. `pccCalls`와 다르면 총량은 알 수 없다.
  public var tokenMeasuredCalls = 0
  /// 감독자에게 물은 횟수. 재계획이 실제로 일어났는가를 이 값이 말한다.
  public var supervisorIterations = 0
  /// 기기 모델로 압축한 횟수와 그 분모(§33 Local Compaction Ratio).
  public var localExtractions = 0
  /// 기기 모델이 검색 후보를 고른 횟수. 점수가 갈리지 않았을 때만 오른다 —
  /// 이 값이 매 차례 1이면 결정적 점수가 일을 못 하고 있다는 뜻이다.
  public var localSelections = 0
  public var retrievedRows = 0
  /// 한 차례에서 **함께 보낸 독립 읽기**의 최대 수(§12 PR 4). 이 값이 늘 1이면
  /// fanout이 꺼진 것이고, 그 사실은 지연에만 조용히 나타난다.
  public var readFanout = 0
  /// route-only shadow 평가(`shadowRoute`·`shadowAgreement`)는 없앴다. 규칙이
  /// 골랐을 능력과 모델의 선택을 나란히 적던 값인데, 규칙 라우터 자체를 지웠다.
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
      chars=\(inputCharacters, privacy: .public)/\(maximumInputCharacters, privacy: .public) \
      tokens=\(inputTokens.map(String.init) ?? "unknown", privacy: .public)/\(maximumInputTokens.map(String.init) ?? "unknown", privacy: .public) \
      measured=\(measuredInputTokens, privacy: .public) \
      cached=\(cachedInputTokens.map(String.init) ?? "unknown", privacy: .public) \
      pcc=\(pccCalls, privacy: .public)/\(tokenMeasuredCalls, privacy: .public) \
      iterations=\(supervisorIterations, privacy: .public) \
      compaction=\(localExtractions, privacy: .public)/\(retrievedRows, privacy: .public) \
      fanout=\(readFanout, privacy: .public) \
      wait=\(modelWaitMilliseconds, privacy: .public) \
      waitByPurpose=\(modelWaitByPurpose, privacy: .public) \
      location=\(processingLocation.rawValue, privacy: .public) \
      latency=\(latencyMilliseconds, privacy: .public) \
      fallback=\(fallbackReason, privacy: .public) ok=\(succeeded, privacy: .public)
      """)
  }
}
