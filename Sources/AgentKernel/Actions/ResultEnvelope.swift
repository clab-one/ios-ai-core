import Foundation

/// 결과 하나가 **어떻게 쓰여야 하는가.**
///
/// 도구가 돌려준 값이 답의 재료인지, 이미 답 자체인지를 값이 스스로 말한다
/// (`docs/AGENT_RUNTIME_DESIGN.ko.md` §ResultEnvelope). 이 구분이 없으면 기기가
/// 이미 만든 글이 모델을 한 번 더 지나고, 모델은 "사용자가 다음과 같이
/// 말했습니다"를 덧붙인다 — 전사·번역·요약에서 그 왕복은 비용과 정확도를 둘 다
/// 잃는다.
///
/// **새 출처 체계가 아니다.** 출처·범위는 기존 `SourceReference`/`CoverageRecord`가
/// 그대로 든다. 이 타입이 더하는 것은 "이 값을 모델에 다시 실을 것인가" 하나다.
public enum ResultFinality: String, Sendable, Codable, Hashable {
  /// 이미 답이다. 사용자가 요청한 결과물 그 자체.
  case `final`
  /// 답의 재료다. 모델이 이것을 읽고 답을 쓴다.
  case evidence
  /// 사람이나 상위 추론이 골라야 하는 갈림길. 후보를 임의로 하나로 줄이지 않는다.
  case needsDecision
}

/// 그 값을 화면에 **어떻게 세우는가.**
public enum PresentationPolicy: String, Sendable, Codable, Hashable {
  /// 글자 하나 바꾸지 않고 그대로. 전사·번역·기기 요약이 여기 있다.
  case verbatim
  /// 앱이 정한 문구 틀에 값을 끼운다.
  case template
  /// 모델이 문장을 만든다.
  case generated
}

/// 이 값을 다루는 데 **모델을 얼마나 쓸 수 있는가.**
public enum IntelligencePolicy: String, Sendable, Codable, Hashable {
  case noModel
  case localOnly
  case localPreferred
  case pccAllowed
  case pccRequired
}

/// 결과의 처리 정책 셋을 한 값으로.
public struct ResultEnvelope: Sendable, Codable, Hashable {
  public let finality: ResultFinality
  public let presentation: PresentationPolicy
  public let intelligence: IntelligencePolicy

  public init(
    finality: ResultFinality, presentation: PresentationPolicy,
    intelligence: IntelligencePolicy
  ) {
    self.finality = finality
    self.presentation = presentation
    self.intelligence = intelligence
  }

  /// 기본값. 도구 대부분은 답의 재료를 돌려준다.
  public static let evidence = ResultEnvelope(
    finality: .evidence, presentation: .generated, intelligence: .pccAllowed)

  /// 기기가 만들어 화면이 그대로 그리는 산출물. 요약 본문이 이미 이렇게 살고
  /// 있었고(`SummarizeTool` → 화면), 그 규칙을 계약으로 올린 것이 이 값이다.
  public static let deviceArtifact = ResultEnvelope(
    finality: .final, presentation: .verbatim, intelligence: .noModel)

  /// **모델 입력에 실으면 안 되는 값인가.**
  ///
  /// 판정은 둘의 곱이다: 이미 답이고(`final`) 글자를 바꾸면 안 된다(`verbatim`).
  /// 둘 중 하나만으로는 부족하다 — `final`이지만 `template`인 값(완료 통지)은
  /// 근거로 실려도 해롭지 않고, `verbatim`이지만 `evidence`인 값(읽은 원문)은
  /// 실려야 답이 선다.
  public var staysOnDevice: Bool {
    finality == .final && presentation == .verbatim
  }
}
