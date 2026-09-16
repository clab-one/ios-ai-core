import AgentKernel
import Foundation


/// 모델 호출 한 번의 **영수증**.
///
/// 개인 데이터를 담지 않는다(§35). 담는 것은 어느 단계에서 어느 모델을 부르려
/// 했고 어느 모델이 답했는가, 얼마나 걸렸는가, 얼마나 컸는가뿐이다.
///
/// 요청한 모델과 답한 모델을 **따로** 드는 이유: `isAvailable`이 참이어도 세션은
/// 던질 수 있고(실측 2026-09-14, 시뮬레이터에서 `backend=privateCloud`로 고른
/// 차례가 7ms에 실패했다), 그때 기기 모델이 답한다. 한 칸으로 들면 계측이
/// "PCC가 답했다"고 거짓을 말한다.
public struct ModelInvocationReceipt: Sendable, Equatable {
  public let phase: TurnPhase
  /// 어느 **목적**으로 부른 호출인가(`FoundationModelRuntime.AdmissionJob`).
  ///
  /// 단계와 같은 값이 아니다. 한 단계가 목적이 다른 호출을 여러 번 하고(계획하는
  /// 단계가 값을 뽑기도 한다), 기기 모델은 하나뿐이라 목적들이 **한 줄에 선다**.
  /// 목적을 적어 두지 않으면 지표가 "대화 계획이 느리다"는 한 문장으로 뭉개진다.
  public let purpose: String
  public let requestedBackend: ModelTarget
  public let resolvedBackend: ModelTarget

  public let pccAttempted: Bool
  public let pccCompleted: Bool
  public let onDeviceAttempted: Bool
  public let onDeviceCompleted: Bool

  /// 대역으로 내려선 이유 코드. 성공했으면 nil이다.
  public let fallbackReason: String?
  public let inputCharacters: Int
  public let latencyMilliseconds: Int
  /// 입장 줄에서 **기다린** 시간. 지연에서 이 값을 빼면 모델이 실제로 쓴 시간이다.
  /// 두 값을 한 칸에 접으면 "모델이 느리다"와 "앞 목적이 기기 모델을 쥐고 있었다"를
  /// 구별할 수 없다.
  public let waitedMilliseconds: Int

  /// 이 호출이 실제로 태운 토큰. **모델이 돌려준 값**이다
  /// (`LanguageModelSession.Response.usage`, iOS 27).
  ///
  /// 글자 수는 이 값의 대용이 아니다. Apple TN3193에 따르면 라틴 문자는 세~네
  /// 글자가 한 토큰이고 **한국어·중국어·일본어는 대략 한 글자가 한 토큰**이므로,
  /// 같은 `inputCharacters`가 언어에 따라 서로 다른 부하를 뜻한다. 그리고
  /// `@Generable` 스키마와 `@Guide` 문구도 프롬프트에 실려 토큰을 태우는데, 그
  /// 비용은 글자 수 어디에도 없다.
  ///
  /// 재지 못한 호출은 **nil이고 0이 아니다** — iOS 26에는 이 값이 없고, 응답을
  /// 받지 못한 호출에는 사용량이 없다. 0으로 적으면 평균이 조용히 낮아진다.
  public let inputTokens: Int?
  /// 그중 캐시에서 온 토큰. 재시도가 같은 문맥을 다시 태우는지가 이 값에 보인다.
  public let cachedInputTokens: Int?
  public let outputTokens: Int?

  public init(
    phase: TurnPhase,
    purpose: String = "",
    requestedBackend: ModelTarget,
    resolvedBackend: ModelTarget,
    pccAttempted: Bool,
    pccCompleted: Bool,
    onDeviceAttempted: Bool,
    onDeviceCompleted: Bool,
    fallbackReason: String?,
    inputCharacters: Int,
    latencyMilliseconds: Int,
    waitedMilliseconds: Int = 0,
    usage: ModelTokenUsage? = nil
  ) {
    self.phase = phase
    self.purpose = purpose
    self.requestedBackend = requestedBackend
    self.resolvedBackend = resolvedBackend
    self.pccAttempted = pccAttempted
    self.pccCompleted = pccCompleted
    self.onDeviceAttempted = onDeviceAttempted
    self.onDeviceCompleted = onDeviceCompleted
    self.fallbackReason = fallbackReason
    self.inputCharacters = inputCharacters
    self.latencyMilliseconds = latencyMilliseconds
    self.waitedMilliseconds = waitedMilliseconds
    self.inputTokens = usage?.inputTokens
    self.cachedInputTokens = usage?.cachedInputTokens
    self.outputTokens = usage?.outputTokens
  }
}

/// 이 차례의 처리가 **어디서** 일어났는가(§36).
///
/// 답을 기기 모델이 썼다는 사실이 앞서 일어난 PCC 호출을 지우지 않는다. 그래서
/// 값이 넷이고, 화면의 "전부 기기에서 처리" 문장은 첫 값에서만 나온다.
public enum ProcessingLocation: String, Sendable, Hashable {
  case entirelyOnDevice
  /// PCC를 부르려 했으나 실패해 기기 모델이 끝냈다.
  case pccAttemptedButFallbackLocal
  case pccCompleted

  /// 이 차례가 전부 기기 안에서 끝났는가. 화면의 접근 영수증이 이 값을 그린다.
  public var processedEntirelyOnDevice: Bool { self == .entirelyOnDevice }
}

/// 차례 전체의 모델 사용 기록.
///
/// 영수증을 모아 두는 자리이고, 처리 위치는 **모아 둔 것에서 계산된다** —
/// 따로 들고 있으면 두 값이 갈라지고, 갈라진 고지는 거짓말이다.
public struct ModelUsageLog: Sendable, Equatable {
  private(set) var receipts: [ModelInvocationReceipt] = []

  public init() {}

  public mutating func record(_ receipt: ModelInvocationReceipt) {
    receipts.append(receipt)
  }

  public var pccAttempts: Int { receipts.filter(\.pccAttempted).count }
  public var pccCompletions: Int { receipts.filter(\.pccCompleted).count }

  /// 기기를 떠난 **읽기**는 이 값이 말하지 않는다 — 그것은 접근 영수증의 일이다
  /// (`ToolResultReducer.Reduced.leftDevice`). 이 값은 **모델이 어디서 돌았는가**만
  /// 말한다. 두 사실을 한 칸에 접었던 동안, 링크 하나를 읽은 차례가 "Apple 프라이빗
  /// 클라우드에서 처리"로 섰다(실기 재현 2026-09-14).
  public var location: ProcessingLocation {
    if pccCompletions > 0 { return .pccCompleted }
    if pccAttempts > 0 { return .pccAttemptedButFallbackLocal }
    return .entirelyOnDevice
  }

  private static let log = AgentHost.logger("orchestrator")

  /// 이 차례가 **목적별로** 부른 횟수와 기다린 시간.
  ///
  /// 목적 하나가 줄을 오래 쥐면 다른 목적의 지연이 함께 커진다. 그 관계를 보려면
  /// 목적을 열쇠로 모아야 한다 — 단계로 모으면 같은 단계의 다른 목적이 섞인다.
  public var waitByPurpose: [String: Int] {
    receipts.reduce(into: [:]) { totals, receipt in
      guard !receipt.purpose.isEmpty else { return }
      totals[receipt.purpose, default: 0] += receipt.waitedMilliseconds
    }
  }

  /// 줄에서 기다린 시간의 합. 차례 지연에서 이 값을 빼면 모델이 쓴 시간이다.
  public var waitedMilliseconds: Int { receipts.reduce(0) { $0 + $1.waitedMilliseconds } }

  /// 이 차례가 태운 **입력 토큰의 합**. 재지 못한 호출은 더하지 않는다.
  public var inputTokens: Int { receipts.compactMap(\.inputTokens).reduce(0, +) }
  /// 한 호출이 태운 최대 입력 토큰. 합만 보면 "호출이 많았다"와 "한 호출이
  /// 컸다"를 구별할 수 없고, 문맥 창에 걸리는 것은 뒤쪽이다.
  public var maximumInputTokens: Int { receipts.compactMap(\.inputTokens).max() ?? 0 }
  public var cachedInputTokens: Int {
    receipts.compactMap(\.cachedInputTokens).reduce(0, +)
  }
  /// 물리 호출 전체가 실은 글자 수의 합. 예산은 글자로 재고(호출 전) 비용은
  /// 토큰으로 잰다(호출 후) — 두 값을 한 칸에 접지 않는다.
  public var inputCharacters: Int { receipts.reduce(0) { $0 + $1.inputCharacters } }
  public var maximumInputCharacters: Int { receipts.map(\.inputCharacters).max() ?? 0 }

  /// 단계별 한 줄씩 남긴다. 개인 데이터는 담지 않는다.
  public func emit() {
    for receipt in receipts {
      Self.log.info(
        """
        model stage=\(receipt.phase.rawValue, privacy: .public) \
        purpose=\(receipt.purpose, privacy: .public) \
        requested=\(receipt.requestedBackend.rawValue, privacy: .public) \
        resolved=\(receipt.resolvedBackend.rawValue, privacy: .public) \
        input=\(receipt.inputCharacters, privacy: .public) \
        tokens=\(receipt.inputTokens ?? -1, privacy: .public) \
        cached=\(receipt.cachedInputTokens ?? -1, privacy: .public) \
        waited=\(receipt.waitedMilliseconds, privacy: .public) \
        latency=\(receipt.latencyMilliseconds, privacy: .public) \
        fallback=\(receipt.fallbackReason ?? "", privacy: .public)
        """)
    }
  }
}

/// 모델이 돌려준 **실제 토큰 사용량**.
///
/// 추정이 아니다. 이 값이 있는 이유는 글자 수로는 알 수 없는 것이 두 가지이기
/// 때문이다: 언어에 따른 글자당 토큰 비율, 그리고 `@Generable` 스키마가 프롬프트에
/// 실리는 비용. SDK 값을 그대로 퍼뜨리지 않고 이 모양으로 옮긴다
/// (`DynamicProfileAdapter.tokenUsage`) — `LanguageModelSession.Usage`는 iOS 27
/// 전용이고 이 코어는 iOS 26에서도 계획한다.
public struct ModelTokenUsage: Sendable, Equatable {
  public let inputTokens: Int
  public let cachedInputTokens: Int
  public let outputTokens: Int

  public init(inputTokens: Int, cachedInputTokens: Int, outputTokens: Int) {
    self.inputTokens = inputTokens
    self.cachedInputTokens = cachedInputTokens
    self.outputTokens = outputTokens
  }
}

/// 요청 하나가 실제로 낸 **물리 호출들**의 영수증.
///
/// 재시도는 호출이 하나 더인 것이고, 그 호출도 문맥을 태우고 요금을 낸다. 영수증을
/// 한 장만 남기던 동안 `ModelUsageLog.pccAttempts`는 재시도를 세지 않았고, 계측이
/// 실제 PCC 요청 수보다 작게 나왔다 — 문맥 크기가 핵심 지표인 코어에서 그 오차는
/// 지표 전체를 못 믿게 만든다.
public struct ModelInvocationTrail: Sendable, Equatable {
  /// 결과를 정한 호출. 처리 위치와 대역 사유는 이 영수증이 말한다.
  public let outcome: ModelInvocationReceipt
  /// 그 앞에 **실제로 나갔던** 호출들. 시간 순이고, 버린 것은 결과뿐이다.
  public let discarded: [ModelInvocationReceipt]

  public init(
    outcome: ModelInvocationReceipt, discarded: [ModelInvocationReceipt] = []
  ) {
    self.outcome = outcome
    self.discarded = discarded
  }

  /// 시간 순 전부. **계측은 이 목록을 센다.**
  public var all: [ModelInvocationReceipt] { discarded + [outcome] }
}
