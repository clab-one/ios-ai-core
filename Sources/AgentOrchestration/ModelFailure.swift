import AgentKernel
import Foundation
import FoundationModels


/// 모델이 답하지 못했을 때 **무엇을 할 자격이 있는가.**
///
/// 계획·재계획·답 쓰기가 각자 다른 규칙을 들고 있으면, 한 곳을 고칠 때 나머지
/// 둘이 조용히 갈라진다(§37). 그래서 판정은 여기 하나다.
///
/// 가장 중요한 값은 마지막이다. **안전 판정을 다른 모델로 우회하지 않는다.**
/// 가드레일과 거절은 인프라 실패가 아니라 판단이고, 그 판단을 피해 같은 요청을
/// 다른 모델에 넣는 구조는 안전 장치를 무력화하는 구조다.
public enum ModelFailureDisposition: String, Sendable, Equatable {
  /// 일시적·인프라 실패. 기기 모델로 같은 일을 다시 시도해도 된다.
  case retryOnDevice
  /// 모델로는 답이 나오지 않는다. 규칙이 만든 단계가 있으면 그것을 쓴다.
  case useDeterministicRescue
  /// 사용자에게 사실을 말한다. **우회하지 않는다.**
  case surfaceFailure
}

/// 실패 하나를 사유 코드와 처분으로 옮긴다.
public enum ModelFailureClassifier {
  /// `backend`는 **실패한 호출이 돌던 모델**이다. 기기 모델이 실패했다면
  /// `retryOnDevice`는 같은 실패를 한 번 더 하는 일이므로 구제로 접힌다.
  public static func disposition(
    for error: any Error, backend: ModelTarget
  ) -> ModelFailureDisposition {
    let raw = classify(error)
    switch raw {
    case .retryOnDevice:
      return backend == .privateCloud ? .retryOnDevice : .useDeterministicRescue
    default:
      return raw
    }
  }

  /// 로그와 계측에 남길 사유 코드. **원문이나 사용자 글은 담지 않는다.**
  public static func reason(for error: any Error) -> String {
    if #available(iOS 27.0, *), let modern = error as? LanguageModelError {
      switch modern {
      case .guardrailViolation: return "guardrail"
      case .refusal: return "refusal"
      case .contextSizeExceeded: return "context"
      case .rateLimited: return "rateLimited"
      case .unsupportedLanguageOrLocale: return "locale"
      case .unsupportedCapability: return "unsupportedCapability"
      case .unsupportedGenerationGuide: return "unsupportedGuide"
      case .unsupportedTranscriptContent: return "unsupportedTranscript"
      case .timeout: return "timeout"
      @unknown default: return "generation"
      }
    }
    if let legacy = error as? LanguageModelSession.GenerationError {
      switch legacy {
      case .guardrailViolation: return "guardrail"
      case .refusal: return "refusal"
      case .exceededContextWindowSize: return "context"
      case .rateLimited: return "rateLimited"
      case .unsupportedLanguageOrLocale: return "locale"
      case .unsupportedGuide: return "unsupportedGuide"
      case .assetsUnavailable: return "assets"
      case .decodingFailure: return "decoding"
      case .concurrentRequests: return "concurrent"
      @unknown default: return "generation"
      }
    }
    if let action = error as? ActionError, case .unsupported = action {
      return "model.unavailable"
    }
    return "failed"
  }

  /// 모델을 부를 수 없었다(권한·가용성·예산). 던져진 오류가 아니라 **부르기 전의
  /// 판정**이므로 따로 든다.
  public static let unavailableReason = "model.unavailable"

  private static func classify(_ error: any Error) -> ModelFailureDisposition {
    switch reason(for: error) {
    // 안전 판정. 우회 금지.
    case "guardrail", "refusal", "locale", "unsupportedCapability", "unsupportedGuide",
      "unsupportedTranscript":
      return .surfaceFailure
    // 우리 문맥이 너무 크거나 모델 자산이 없다. 다른 모델도 같은 입력을 받는다.
    case "context", "assets", "model.unavailable":
      return .useDeterministicRescue
    // 일시적. 다른 모델로 같은 일을 해볼 수 있다.
    case "rateLimited", "timeout", "concurrent", "decoding", "generation", "failed":
      return .retryOnDevice
    default:
      return .retryOnDevice
    }
  }
}
