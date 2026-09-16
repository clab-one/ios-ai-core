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
  /// 일시적·인프라 실패. **같은 요청을 PCC에 한 번 더** 낸다.
  case retry
  /// 사용자에게 사실을 말한다. **우회하지 않는다.**
  ///
  /// 규칙이 만든 구제 단계로 물러나던 값(`useDeterministicRescue`)은 없앴다 —
  /// 계획은 모델의 일이고, 규칙이 대신 세운 계획은 사용자가 말하지 않은 일을
  /// 한다. 기기 모델로 갈아타던 값(`retryOnDevice`)도 없앴다: 오케스트레이션은
  /// PCC 하나이고, PCC를 쓸 수 없으면 차례를 열지 않는다.
  case surfaceFailure
}

/// 실패 하나를 사유 코드와 처분으로 옮긴다.
public enum ModelFailureClassifier {
  /// 처분은 **오류 하나로만** 정한다. 어느 모델이 실패했는지는 묻지 않는다 —
  /// 오케스트레이션 호출은 언제나 PCC이고, 갈아탈 다른 모델이 없다.
  public static func disposition(for error: any Error) -> ModelFailureDisposition {
    classify(error)
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
    if let unavailable = error as? AgentModelUnavailable {
      switch unavailable {
      case .privateCloudUnsupported: return unsupportedReason
      case .onDeviceUnavailable: return unavailableReason
      }
    }
    if let action = error as? ActionError, case .unsupported = action {
      return unavailableReason
    }
    return "failed"
  }

  /// 모델을 부를 수 없었다(가용성·자산). 던져진 오류가 아니라 **부르기 전의
  /// 판정**이므로 따로 든다.
  public static let unavailableReason = "model.unavailable"

  /// 이 기기·계정·서명으로는 **PCC를 쓸 수 없다.**
  ///
  /// 실패가 아니라 환경의 사실이다. 화면은 이 값을 "지원하지 않는 기기"로
  /// 옮겨야 하고, 재시도 버튼을 세우면 안 된다 — 다시 눌러도 같은 값이다.
  public static let unsupportedReason = "pcc.unsupported"

  private static func classify(_ error: any Error) -> ModelFailureDisposition {
    switch reason(for: error) {
    // 안전 판정. 우회 금지.
    case "guardrail", "refusal", "locale", "unsupportedCapability", "unsupportedGuide",
      "unsupportedTranscript":
      return .surfaceFailure
    // 우리 문맥이 너무 크거나 모델 자산이 없다. 다시 내도 같은 입력을 받는다.
    case "context", "assets", "model.unavailable", "pcc.unsupported":
      return .surfaceFailure
    // 일시적. 같은 요청을 한 번 더 낸다.
    case "rateLimited", "timeout", "concurrent", "decoding", "generation", "failed":
      return .retry
    default:
      return .retry
    }
  }
}
