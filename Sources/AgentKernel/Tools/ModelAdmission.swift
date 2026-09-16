import Foundation

/// 기기 모델 앞의 줄에서 **어느 목적으로 기다리는가.**
///
/// 값이 이름 하나인 이유는 목적 목록이 코어의 것이 아니기 때문이다. 코어는 차례가
/// 쓰는 세 목적을 들고, 호스트는 자기 목적(요약·제목·색인 등)을 확장으로 더한다 —
/// 코어의 enum에 남의 목적을 적으면 호스트가 늘 때마다 코어를 고쳐야 한다.
///
/// 이름은 **지표의 열쇠**다(`ModelInvocationReceipt.purpose`). 바꾸면 이전 실행의
/// 지표와 이어지지 않는다.
public struct AdmissionJob: Hashable, Sendable, CustomStringConvertible,
  ExpressibleByStringLiteral
{
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: StringLiteralType) { self.rawValue = value }
  public var description: String { rawValue }

  /// 대화 입력의 행동 계획(`TurnSupervisor`).
  public static let conversationPlan = AdmissionJob("conversationPlan")
  /// 답을 쓰는 단계(`TurnFinalizer`). 계획과 **이름을 나눈다** — 같은 줄에 서지만
  /// 지표에서 갈라져야 "계획이 오래 걸렸다"와 "답이 오래 걸렸다"를 구별한다.
  public static let conversationAnswer = AdmissionJob("conversationAnswer")
  /// 회수한 원문에서 값을 뽑는 단계(`EvidenceCompiler`). 차례당 상한이 따로 있다.
  public static let conversationExtraction = AdmissionJob("conversationExtraction")
}

/// 입장 줄에서 기다린 시간을 **호출자에게 돌려주는** 상자.
///
/// 입장 제어의 몸통은 `@Sendable` 클로저 안에서 돌기 때문에 지역 변수에 적을 수
/// 없다. 값은 입장 순간 한 번 적히고 완료 뒤 한 번 읽힌다 — 자물쇠 하나로 충분하다.
public final class AdmissionWait: @unchecked Sendable {
  private let lock = NSLock()
  private var waited = 0

  public init() {}

  public func record(_ milliseconds: Int) {
    lock.lock()
    waited = milliseconds
    lock.unlock()
  }

  public var milliseconds: Int {
    lock.lock()
    defer { lock.unlock() }
    return waited
  }
}

/// 살아 있는 모델 호출을 **한 줄로 세우는 문**.
///
/// 기기 모델은 하나다. 둘이 동시에 돌면 둘 다 느려지고, 셋이면 셋 다 느려진다 —
/// 그래서 순서를 정한다. 도착 순서를 지키는 이유는 뒤에 온 짧은 호출이 앞에 온
/// 긴 호출을 계속 앞지르면 앞의 호출이 영원히 끝나지 않기 때문이다.
///
/// 기다리는 동안 취소된 호출은 **줄에서 빠지고 모델을 부르지 않는다.** 취소를
/// 무시하면 사용자가 화면을 닫은 뒤에도 기기 모델이 돌아 배터리를 쓴다.
actor AdmissionGate {
  private var busy = false
  private var waiting: [UUID] = []
  private var resumers: [UUID: CheckedContinuation<Void, any Error>] = [:]

  func run<T>(operation: @Sendable () async throws -> T) async throws -> T {
    try await acquire()
    do {
      let value = try await operation()
      release()
      return value
    } catch {
      release()
      throw error
    }
  }

  private func acquire() async throws {
    try Task.checkCancellation()
    if !busy, waiting.isEmpty {
      busy = true
      return
    }
    let ticket = UUID()
    waiting.append(ticket)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        resumers[ticket] = continuation
      }
    } onCancel: {
      Task { await self.abandon(ticket) }
    }
  }

  /// 소유권을 다음 차례로 **넘긴다.** `busy`를 내리는 것은 줄이 빈 순간 하나뿐이다.
  private func release() {
    while let next = waiting.first {
      waiting.removeFirst()
      if let continuation = resumers.removeValue(forKey: next) {
        continuation.resume()
        return
      }
    }
    busy = false
  }

  /// 기다리다 취소된 호출을 줄에서 뺀다. 소유권은 아직 없으므로 `busy`는 그대로다.
  private func abandon(_ ticket: UUID) {
    waiting.removeAll { $0 == ticket }
    resumers.removeValue(forKey: ticket)?.resume(throwing: CancellationError())
  }
}

/// 기기 상태가 **부를 만한가**를 기다리는 자리.
///
/// 발열·저전력 알림을 기다리다 시간이 지나면 깨어난다. 알림만 기다리면 알림이
/// 오지 않는 기기에서 영원히 서고, 시간만 기다리면 상태가 풀린 뒤에도 남은
/// 시간을 전부 잔다.
private final class AdmissionConditionWaiter: @unchecked Sendable {
  private let center = NotificationCenter.default
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, any Error>?
  private var observers: [NSObjectProtocol] = []
  private var timeoutTask: Task<Void, Never>?
  private var finished = false

  func waitUntilChange(timeout: Duration) async throws {
    try Task.checkCancellation()
    try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        install(continuation, timeout: timeout)
        // 설치 뒤에 다시 본다. 설치 사이에 상태가 풀렸으면 기다릴 것이 없다.
        if !DeviceConditions.current().isUnsafe {
          finish()
        }
      }
    }, onCancel: {
      cancel()
    })
  }

  private func install(
    _ continuation: CheckedContinuation<Void, any Error>,
    timeout: Duration
  ) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return
    }
    self.continuation = continuation
    observers = [
      center.addObserver(
        forName: ProcessInfo.thermalStateDidChangeNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in self?.finish() },
      center.addObserver(
        forName: .NSProcessInfoPowerStateDidChange,
        object: nil,
        queue: nil
      ) { [weak self] _ in self?.finish() },
    ]
    timeoutTask = Task { [weak self] in
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      self?.finish()
    }
    lock.unlock()
  }

  private func cancel() {
    finish(with: CancellationError())
  }

  private func finish(with error: (any Error)? = nil) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let continuation = self.continuation
    self.continuation = nil
    let observers = self.observers
    self.observers.removeAll()
    let timeoutTask = self.timeoutTask
    self.timeoutTask = nil
    lock.unlock()

    timeoutTask?.cancel()
    for observer in observers {
      center.removeObserver(observer)
    }
    guard let continuation else { return }
    if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume()
    }
  }
}

/// 지금 기기가 모델을 부를 만한가.
struct DeviceConditions: Sendable {
  let thermalState: ProcessInfo.ThermalState
  let lowPowerMode: Bool

  var isUnsafe: Bool {
    thermalState == .serious || thermalState == .critical || lowPowerMode
  }

  static func current() -> DeviceConditions {
    let process = ProcessInfo.processInfo
    return DeviceConditions(
      thermalState: process.thermalState,
      lowPowerMode: process.isLowPowerModeEnabled
    )
  }
}

/// 줄에서 기다리다 입장을 **거부당한** 호출. 줄 밖에서 상태를 다시 본다.
private struct DeferredAdmission: Error {}

public enum ModelAdmissionError: Error, CustomStringConvertible, Sendable {
  case conditionWaitTimedOut(job: String, timeout: Duration)

  public var description: String {
    switch self {
    case .conditionWaitTimedOut(let job, let timeout):
      return "model admission timed out after \(timeout) while waiting for \(job)"
    }
  }
}

/// 살아 있는 모델 호출이 지나가는 **단 하나의 문**.
///
/// 두 가지를 한 자리에서 한다: 호출을 직렬화하고, 기기가 뜨겁거나 저전력일 때
/// 기다린다. 이 둘을 각 호출자가 따로 하면 어떤 경로는 게이트를 지나고 어떤
/// 경로는 지나지 않는다 — 그러면 발열 정책이 경로마다 다르다는 뜻이다.
///
/// 코어에 있는 이유: 이 정책은 앱의 것이 아니라 **기기 모델의 것**이다. 코어를
/// 붙이는 앱이 발열 게이트를 다시 구현해야 한다면 그 앱은 코어를 절반만 받은 것이다.
public enum ModelAdmission {
  private static let log = AgentHost.logger("model-admission")
  private static let gate = AdmissionGate()
  /// 시스템 알림이 오지 않아도 이 간격마다 상태를 다시 본다.
  private static let conditionPollInterval: Duration = .milliseconds(250)
  /// 안전 조건을 기다리는 상한. **모델 호출 자체의 상한이 아니다** — 입장까지의
  /// 대기만 재고, 일단 들어간 호출은 이 시계를 보지 않는다.
  private static let conditionWaitTimeout: Duration = .seconds(30)

  /// 기기 조건이 풀릴 때까지 기다린 뒤, 줄을 서서 `operation`을 돌린다.
  ///
  /// `admitted`는 **줄에서 기다린 시간**을 밀리초로 돌려준다. 이 값이 없던 동안
  /// 한 차례가 느린 이유를 "모델이 느리다"와 "다른 목적이 기기 모델을 쥐고
  /// 있었다"로 나눌 수 없었다 — 앞은 모델의 문제고 뒤는 우리의 순서 문제다.
  public static func withAdmission<T>(
    for job: AdmissionJob,
    admitted: (@Sendable (Int) -> Void)? = nil,
    operation: @Sendable () async throws -> T
  ) async throws -> T {
    let clock = ContinuousClock()
    let requestedAt = clock.now
    let deadline = requestedAt.advanced(by: conditionWaitTimeout)
    while true {
      try await waitForSafeConditions(for: job, until: deadline)

      do {
        return try await gate.run {
          let conditions = DeviceConditions.current()
          // 줄에 선 사이에 기기가 뜨거워질 수 있다. **들어온 자리에서 다시 본다.**
          guard !conditions.isUnsafe else {
            logDeferred(job: job, conditions: conditions)
            throw DeferredAdmission()
          }

          let waited = Int((clock.now - requestedAt) / .milliseconds(1))
          admitted?(waited)
          log.info(
            "model job=\(job.rawValue, privacy: .public) state=admitted waited=\(waited, privacy: .public) thermal=\(String(describing: conditions.thermalState), privacy: .public) lowPower=\(conditions.lowPowerMode, privacy: .public)"
          )
          defer {
            log.info("model job=\(job.rawValue, privacy: .public) state=finished")
          }
          return try await operation()
        }
      } catch is DeferredAdmission {
        // 줄의 소유권은 이미 놓았다. 줄 밖에서 조건을 다시 보고 같은 요청을 다시 낸다.
        continue
      }
    }
  }

  private static func logDeferred(job: AdmissionJob, conditions: DeviceConditions) {
    let reason = conditions.lowPowerMode ? "lowPowerDeferred" : "thermalDeferred"
    log.warning(
      "model job=\(job.rawValue, privacy: .public) state=deferred reason=\(reason, privacy: .public) thermal=\(String(describing: conditions.thermalState), privacy: .public) lowPower=\(conditions.lowPowerMode, privacy: .public)"
    )
  }

  private static func waitForSafeConditions(
    for job: AdmissionJob,
    until deadline: ContinuousClock.Instant
  ) async throws {
    let clock = ContinuousClock()
    while true {
      try Task.checkCancellation()
      let conditions = DeviceConditions.current()
      guard conditions.isUnsafe else { return }
      guard clock.now < deadline else {
        log.error("model job=\(job.rawValue, privacy: .public) state=admissionTimeout")
        throw ModelAdmissionError.conditionWaitTimedOut(
          job: job.rawValue, timeout: conditionWaitTimeout)
      }
      logDeferred(job: job, conditions: conditions)
      let remaining = clock.now.duration(to: deadline)
      let waitDuration = remaining < conditionPollInterval ? remaining : conditionPollInterval
      try await AdmissionConditionWaiter().waitUntilChange(timeout: waitDuration)
    }
  }
}
