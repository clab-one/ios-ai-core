import AgentKernel
import Foundation
import FoundationModels


/// 앱의 단계 설정을 **실제 SDK 값**으로 옮기는 자리.
///
/// 여기가 한 자리인 이유: FoundationModels의 이 세 값은 iOS 27에서 들어왔고
/// (`ContextOptions`·`GenerationOptions.ToolCallingMode`·`DynamicProfile`), 이 앱은
/// iOS 26에서도 계획하고 답한다. 가용성 분기를 호출부마다 두면 한 곳이 빠진 날
/// 그 기기에서 프로세스가 죽는다.
///
/// **확인한 SDK 사실**(iPhoneSimulator27.0.sdk `FoundationModels.swiftinterface`):
///
/// - `ContextOptions.ReasoningLevel`: `.light` `.moderate` `.deep` `.custom(String)` (iOS 27)
/// - `GenerationOptions.ToolCallingMode`: `.allowed` `.required` `.disallowed` (iOS 27)
/// - `ContextOptions(includeSchemaInPrompt:reasoningLevel:)` (iOS 27)
/// - `GenerationOptions(samplingMode:temperature:maximumResponseTokens:toolCallingMode:)` (iOS 27)
/// - `LanguageModelSession.Profile`·`DynamicProfile`, 수정자 `.model` `.reasoningLevel`
///   `.toolCallingMode` `.historyTransform` (iOS 27)
///
/// 추측으로 쓴 이름은 없다. 값이 더 필요해지면 그때 다시 인터페이스를 읽는다(§38).
@available(iOS 26.0, *)
public enum DynamicProfileAdapter {
  /// 이 단계의 생성 옵션.
  ///
  /// `sampling: .greedy`를 계속 쓴다 — 계획과 답이 같은 입력에 같은 값을 내야
  /// 재시도가 같은 일을 하고, 시험이 값을 못 박을 수 있다.
  public static func generationOptions(for profile: DynamicTurnProfile) -> GenerationOptions {
    if #available(iOS 27.0, *) {
      return GenerationOptions(
        samplingMode: .greedy,
        maximumResponseTokens: profile.maximumResponseTokens,
        toolCallingMode: toolCallingMode(profile.toolCalling))
    }
    return GenerationOptions(
      sampling: .greedy, maximumResponseTokens: profile.maximumResponseTokens)
  }

  /// 이 단계의 문맥 옵션. iOS 26에는 이 값이 없으므로 nil이다 — 그 기기에서는
  /// 추론 수준을 요청하지 않고, 그 사실이 계측에 남는다.
  @available(iOS 27.0, *)
  public static func contextOptions(for profile: DynamicTurnProfile) -> ContextOptions {
    guard let reasoning = profile.reasoning else { return ContextOptions() }
    return ContextOptions(reasoningLevel: reasoningLevel(reasoning))
  }

  /// 응답이 들고 온 **실제 사용량**을 코어의 값으로.
  ///
  /// 확인한 SDK 사실: `LanguageModelSession.Response.usage`(iOS 27)와
  /// `Usage.Input(totalTokenCount:cachedTokenCount:)`·
  /// `Usage.Output(totalTokenCount:reasoningTokenCount:)`.
  ///
  /// 이 자리가 있는 이유는 가용성이다. iOS 26에는 이 타입이 없으므로 호출부마다
  /// 분기를 두면 한 곳이 빠진 날 그 기기에서 프로세스가 죽는다.
  @available(iOS 27.0, *)
  public static func tokenUsage(_ usage: LanguageModelSession.Usage) -> ModelTokenUsage {
    ModelTokenUsage(
      inputTokens: usage.input.totalTokenCount,
      cachedInputTokens: usage.input.cachedTokenCount,
      outputTokens: usage.output.totalTokenCount)
  }

  @available(iOS 27.0, *)
  public static func reasoningLevel(
    _ reasoning: DynamicTurnProfile.Reasoning
  ) -> ContextOptions.ReasoningLevel {
    switch reasoning {
    case .light: .light
    case .moderate: .moderate
    case .deep: .deep
    }
  }

  @available(iOS 27.0, *)
  public static func toolCallingMode(
    _ calling: DynamicTurnProfile.ToolCalling
  ) -> GenerationOptions.ToolCallingMode {
    switch calling {
    case .allowed: .allowed
    case .required: .required
    case .disallowed: .disallowed
    }
  }

  /// 오케스트레이션 세션. **PCC 하나다.**
  ///
  /// 기기 모델로 내려서는 길을 여기 두지 않는다 — 계획과 답을 다른 품질의
  /// 모델이 몰래 대신 쓰면, 사용자는 자기 요청이 어느 모델을 지났는지 알 수
  /// 없고 계측의 `backend` 칸도 거짓이 된다.
  ///
  /// **세션을 단계 사이에 물려주지 않는다.** 프로파일이 바뀔 때 이력이 통째로
  /// 따라가는 문제(§18)에 대한 답이다: 물려줄 이력이 없으면 새어 나갈 이력도
  /// 없다. 각 호출은 그 단계의 지시와, 그 단계가 실을 자격이 있는 문맥만 들고
  /// 새로 선다(`ContextPolicy`). 그래서 `historyTransform`은 쓰지 않는다.
  @available(iOS 27.0, *)
  public static func privateCloudSession(
    instructions: String
  ) throws -> LanguageModelSession {
    guard PrivateCloudComputeAccess.isUsable() else {
      throw AgentModelUnavailable.privateCloudUnsupported
    }
    return LanguageModelSession(
      model: PrivateCloudComputeLanguageModel(), instructions: instructions)
  }

  /// 툴이 기기에서 쓸 세션(근거 추출·요약). 오케스트레이션은 이 문을 쓰지 않는다.
  public static func onDeviceSession(
    instructions: String, model: SystemLanguageModel
  ) throws -> LanguageModelSession {
    guard case .available = model.availability else {
      throw AgentModelUnavailable.onDeviceUnavailable
    }
    return LanguageModelSession(model: model, instructions: instructions)
  }
}

/// 부를 모델이 없다. **오류가 아니라 환경의 사실**이므로 사유를 나눠 든다.
public enum AgentModelUnavailable: Error, Sendable, Equatable {
  /// 이 기기·계정·서명으로는 PCC를 쓸 수 없다. 에이전트는 **열리지 않는다**.
  case privateCloudUnsupported
  /// 기기 모델 자산이 없다. 툴의 지역 처리가 불가능하다.
  case onDeviceUnavailable
}
