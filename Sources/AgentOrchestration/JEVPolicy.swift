import AgentKernel
import FoundationModels
import Foundation

/// JEV(§ `docs/AGENT_RUNTIME_DESIGN.ko.md` "JEV 정책 계약")의 구조화 출력.
///
/// **전용 학습 모델이 아니다.** 이 파일 작성 시점, Mori와 원본 native JustSend
/// 어디에도 전용 JEV 학습 모델·정책 평가셋·보정된 확률 출력은 없다(같은 문서
/// "실제 정책 모델 선택"). 이 타입은 Foundation Models의 온디바이스 guided
/// generation으로 얻는 **좁은 구조화 정책**이고, `GeneratedTurnDecision`
/// (`ActionPlan.swift`)과 같은 관례를 따른다 — 생성 모델이되 실행 계획이 아니라
/// 정책 순위를 낸다.
@available(iOS 26.0, *)
@Generable
public struct GeneratedJEVPolicy {
  @Guide(
    description: "capability names ranked most to least relevant, from the provided list only",
    .maximumCount(6))
  public let rankedCapabilities: [String]
  @Guide(description: "true if the answer requires reading or searching more evidence")
  public let needsRetrieval: Bool
  @Guide(description: "true if the answer requires writing new content, such as a summary or message body")
  public let needsGeneration: Bool
  @Guide(description: "true if a required value is missing and the user must be asked before anything runs")
  public let needsClarification: Bool
  @Guide(description: "true if more tool iterations are needed before a final answer can be written")
  public let needsContinuation: Bool
  @Guide(
    description: "which execution path this turn should take",
    .anyOf(["directTool", "agentLocal", "agentPCC", "clarification"]))
  public let recommendation: String

  public init(
    rankedCapabilities: [String], needsRetrieval: Bool, needsGeneration: Bool,
    needsClarification: Bool, needsContinuation: Bool, recommendation: String
  ) {
    self.rankedCapabilities = rankedCapabilities
    self.needsRetrieval = needsRetrieval
    self.needsGeneration = needsGeneration
    self.needsClarification = needsClarification
    self.needsContinuation = needsContinuation
    self.recommendation = recommendation
  }
}

/// 검증을 지난 JEV 판단. **soft preference**다 — `docs/AGENT_RUNTIME_DESIGN.ko.md`
/// "ToolMenuBuilder": "제한된 정책 예측을 실행 가능성의 최종 판정으로 사용하지
/// 않는다." 순위 밖 capability를 실행에서 막지 않는다, 메뉴 초기 좁힘의 한 입력일
/// 뿐이다.
public struct JEVPolicyDecision: Sendable, Equatable {
  public enum Recommendation: String, Sendable, Equatable {
    case directTool, agentLocal, agentPCC, clarification
  }

  public let rankedCapabilities: [CapabilityID]
  public let needsRetrieval: Bool
  public let needsGeneration: Bool
  public let needsClarification: Bool
  public let needsContinuation: Bool
  public let recommendation: Recommendation
  /// 이 판단이 나온 provider/model version. 빈 문자열이면 안 된다 — 판단
  /// 근거의 유형을 잃으면 나중에 이 순위가 어디서 왔는지 감사할 수 없다.
  public let source: String
  /// **실측 없이는 nil.** 생성 모델이 낸 숫자를 보정된 성공 확률로 쓰지 않는다
  /// (같은 문서 "출력은 다음을 분리한다"). 이 필드에 값을 채우는 자리는 독립
  /// 평가셋으로 보정한 뒤에만 만든다 — 지금은 아무 채움쇠도 두지 않는다.
  public let confidence: Double?

  public init(
    rankedCapabilities: [CapabilityID], needsRetrieval: Bool, needsGeneration: Bool,
    needsClarification: Bool, needsContinuation: Bool, recommendation: Recommendation,
    source: String, confidence: Double? = nil
  ) {
    self.rankedCapabilities = rankedCapabilities
    self.needsRetrieval = needsRetrieval
    self.needsGeneration = needsGeneration
    self.needsClarification = needsClarification
    self.needsContinuation = needsContinuation
    self.recommendation = recommendation
    self.source = source
    self.confidence = confidence
  }
}

/// **정책 실패는 권한 실패가 아니다.** 실패하면 안전한 전체 capability 메뉴와
/// 생성 모델 판단으로 돌아갈 수 있다 — 그러나 그 사실을 감추지 않는다
/// (`docs/AGENT_RUNTIME_DESIGN.ko.md` "JEV 정책 계약").
public enum JEVPolicyOutcome: Sendable, Equatable {
  case decided(JEVPolicyDecision)
  case unavailable(reason: String)
}

/// `GeneratedJEVPolicy` → `JEVPolicyDecision`. `ActionPlanValidator.validate`와
/// 같은 계약: 모델이 범위 밖을 고르면 그 사실은 버릴 이유이지 실행할 이유가
/// 아니다.
public enum JEVPolicyValidator {
  public static func validate(
    _ generated: GeneratedJEVPolicy, allowed: [CapabilityID], source: String
  ) -> JEVPolicyOutcome {
    guard let recommendation = JEVPolicyDecision.Recommendation(rawValue: generated.recommendation)
    else {
      return .unavailable(reason: "unrecognizedRecommendation:\(generated.recommendation)")
    }
    let allowedSet = Set(allowed.map(\.rawValue))
    let ranked = generated.rankedCapabilities
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { allowedSet.contains($0) }
      .map { CapabilityID($0) }
    return .decided(
      JEVPolicyDecision(
        rankedCapabilities: ranked, needsRetrieval: generated.needsRetrieval,
        needsGeneration: generated.needsGeneration,
        needsClarification: generated.needsClarification,
        needsContinuation: generated.needsContinuation, recommendation: recommendation,
        source: source, confidence: nil))
  }
}
