import AgentKernel
import Foundation


/// 능력 등록의 **소유자**.
///
/// 등록이 화면 수명에 달려 있던 동안, 트리에 서지 않은 지면에서는 등록이 한 번도
/// 돌지 않았고 손이 없는 디스패처는 모든 요청을 `noCapability`로 떨어뜨렸다 —
/// 링크를 읽어 요약하는 일도 기억을 찾는 일도 "서비스를 먼저 연결해 주세요"가
/// 됐다(실기 재현 2026-09-14, TestFlight 2.0.0(197)).
///
/// 그래서 **제출 직전에** 확인한다(§3.1). 같은 계정·epoch에서는 한 번만 돌고,
/// 계정이나 epoch가 바뀌면 다시 돈다. 동시 호출은 하나의 등록을 함께 기다리므로
/// 중복 호출이 손을 실행 도중에 바꾸지 않는다.
@MainActor
public final class CapabilityReadiness {
  private struct Scope: Equatable {
    public let accountID: String
    public let epoch: UInt64
  }

  private let accountID: @MainActor () -> String
  private let register: @MainActor () async -> Void
  private var prepared: Scope?
  /// 지금 도는 등록과 **그 등록이 누구의 것인지**. scope를 함께 들지 않으면
  /// 함께 기다린 쪽이 "아직 준비 안 됐다"고 보고 같은 등록을 한 번 더 돌린다.
  private var inflight: (scope: Scope, task: Task<Void, Never>)?

  public init(
    accountID: @escaping @MainActor () -> String,
    register: @escaping @MainActor () async -> Void
  ) {
    self.accountID = accountID
    self.register = register
  }

  private var currentScope: Scope {
    Scope(accountID: accountID(), epoch: AssistantAccountEpoch.current)
  }

  public func ensureRegistered() async {
    let scope = currentScope
    if prepared == scope { return }
    // 같은 scope의 등록이 이미 돌고 있으면 **그것을 기다리는 것으로 끝난다.**
    if let inflight, inflight.scope == scope {
      await inflight.task.value
      return
    }
    let task = Task { @MainActor in await self.register() }
    inflight = (scope, task)
    await task.value
    if inflight?.task == task { inflight = nil }
    // 등록 도중에 계정이 바뀌었다면 그 등록은 이 scope의 것이 아니다. 다음 제출이
    // 새 계정의 손을 다시 등록한다.
    guard scope == currentScope else { return }
    prepared = scope
  }
}
