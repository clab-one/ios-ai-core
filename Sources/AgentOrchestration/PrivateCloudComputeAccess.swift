import AgentKernel
import Foundation
import FoundationModels


/// Private Cloud Compute를 **부를 자격이 있는가.**
///
/// `PrivateCloudComputeLanguageModel().isAvailable`만 보고 부르면 안 된다. 그 값은
/// 기기·계정·지역이 PCC를 받을 수 있는지만 말하고, **우리 앱이 서명으로 그 권한을
/// 들고 있는지는 말하지 않는다.** 권한 없이 세션을 만들면 프레임워크가 예외가 아니라
/// `fatalError`로 프로세스를 끝낸다:
///
/// ```
/// FoundationModels/ErrorConversion.swift:140: Fatal error:
///   Missing entitlement: com.apple.developer.private-cloud-compute
/// ```
///
/// 실측 2026-09-14(iOS 27.0 시뮬레이터): 계획 경로가 PCC를 고른 순간 테스트 호스트가
/// 이 신호로 죽었고, 개별 검사는 전부 통과한 채 런이 `TEST FAILED`로 끝났다.
/// `do/catch`로 감쌀 수 없는 실패이므로 **부르기 전에** 막아야 한다.
public enum PrivateCloudComputeAccess {
  private static let log = AgentHost.logger("orchestrator")

  public static let entitlementKey = "com.apple.developer.private-cloud-compute"

  /// 이 앱의 서명에 PCC 권한이 있는가. **코어가 알 수 없으므로 호스트가 말한다**
  /// (`AgentHostIdentity.isPrivateCloudComputeEntitled`).
  ///
  /// 값이 한 자리뿐인 이유: iOS에는 자기 엔타이틀먼트를 읽는 공개 API가 없다
  /// (`SecTaskCopyValueForEntitlement`는 macOS 전용이고 iOS SDK에 없다). 그래서
  /// 호스트가 넘긴 값과 서명이 갈리면 앱이 죽는다 — 호스트는 그 두 자리를
  /// 대조하는 시험을 들고 있어야 한다(JustSend: `PrivateCloudComputeEntitlementTests`).
  ///
  /// 설정하지 않은 호스트는 **거짓**이다. PCC를 부르지 않는 쪽이 죽지 않는 쪽이다.
  public static var isEntitled: Bool { AgentHost.identity.isPrivateCloudComputeEntitled }

  /// 지금 이 차례에 PCC를 쓸 수 있는가. **권한이 먼저, 가용성이 다음이다.**
  @available(iOS 27.0, *)
  public static func isUsable() -> Bool {
    guard isEntitled else {
      log.info("pcc skipped reason=entitlement")
      return false
    }
    let cloud = PrivateCloudComputeLanguageModel()
    guard cloud.isAvailable else {
      log.info("pcc skipped reason=unavailable")
      return false
    }
    return true
  }
}
