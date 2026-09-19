import Foundation

/// 툴이 **자기 안의 진행을 밖으로 말하는 자리.**
///
/// 왜 필요한가: 긴 글의 요약은 조각마다 기기 모델을 부른다. 실기 2026-09-17
/// (iPhone) 한 차례가 131초였고, 그 동안 화면에는 `text.summarize` 한 줄이 서
/// 있었을 뿐이다 — 사람은 멈춘 것과 구별할 수 없다. 정본(JustSend)은 이 자리를
/// 조각 단위로 보여 준다(`SummaryProgress`: "조각 3/11 읽기").
///
/// 손잡이를 **task-local로** 두는 이유: `CapabilityHandler.perform`의 서명을
/// 바꾸지 않는다. 진행을 말하지 않는 툴은 이 타입을 모른 채 그대로 돌고, 말하는
/// 툴은 자기 실행 안에서 부른다. 설치는 실행을 감싸는 자리(`ActionDispatcher`)가
/// 한 번만 한다.
public enum ToolProgress {
  public typealias Sink = @Sendable (CapabilityID, Int, Int) -> Void

  @TaskLocal public static var sink: Sink?

  /// 지금 몇 번째인가. **낱말은 보내지 않는다** — 사람이 읽는 문구는 호스트의
  /// 것이고, 코어가 아는 것은 수량뿐이다.
  public static func report(_ capability: CapabilityID, done: Int, total: Int) {
    sink?(capability, done, total)
  }

  /// 실행 하나를 이 손잡이로 감싼다.
  public static func withSink<T>(
    _ sink: Sink?, operation: () async throws -> T
  ) async rethrows -> T {
    try await $sink.withValue(sink) { try await operation() }
  }
}
