import AgentKernel
import Foundation
import FoundationModels

/// 한 차례의 native tool 호출이 공유하는 **정체**.
///
/// SDK의 `Tool.call(arguments:)`는 세션이 만들어질 때 캡처된 값만 본다 — 호출마다
/// 새로 주입할 자리가 없다. 그래서 계정·대화·차례·epoch를 어댑터 생성 시점에
/// 한 번 고정한다(`docs/AGENT_RUNTIME_DESIGN.ko.md` §정체와 소유권).
@available(iOS 26.0, *)
public struct NativeToolContext: Sendable {
  public let accountID: String
  public let conversationID: String?
  public let turnID: UUID
  public let accountEpoch: UInt64

  public init(accountID: String, conversationID: String?, turnID: UUID, accountEpoch: UInt64) {
    self.accountID = accountID
    self.conversationID = conversationID
    self.turnID = turnID
    self.accountEpoch = accountEpoch
  }
}

/// native tool 호출을 **journal/UI에 알리는 손.**
///
/// `Tool.call`은 SDK가 `respond()` 실행 도중 직접 부른다 — 바깥에서 그 호출을
/// 가로챌 자리가 없다. 그래서 시작·끝을 이 관찰자에게 직접 통지한다. `callID`는
/// SDK가 준 것이 아니라 어댑터가 만든 지문이다(`FoundationToolAdapter.call`의 주석).
@available(iOS 26.0, *)
public protocol NativeToolObserver: Sendable {
  func toolStarted(callID: String, capability: CapabilityID, arguments: [String: ActionValue])
    async
  func toolFinished(callID: String, capability: CapabilityID, outcome: ActionOutcome) async
}

/// **하나의 능력**을 Foundation Models가 직접 부를 수 있는 도구로 세운다
/// (`docs/AGENT_RUNTIME_DESIGN.ko.md` §Native tool bridge).
///
/// ## 왜 읽기 전용만 통과하는가
///
/// SDK의 `Tool.call`은 모델 세션의 `respond()` 실행 도중 SDK가 직접 부른다 —
/// 그 호출 앞에는 사람이 승인할 대기 지점이 없다(`AgentKernel`의
/// `ActionDispatcher.dispatch`는 `.waitingApproval`을 돌려줄 수 있지만, 그 값을
/// 받아 사람에게 보이고 다시 실행을 잇는 것은 지금 이 native 호출 경로가 아니라
/// 승인 UI가 있는 다른 경로다). 쓰기 능력을 이 도구 목록에 얹으면 **사람의
/// 허락 없이 효과가 나갈 길**이 열린다. 그래서 `init?`는 계약의 권한이
/// `CapabilityID.Authority.observes`가 아니면 어댑터 자체를 만들지 않는다 —
/// 도구 목록에 없는 능력은 모델이 부를 수조차 없다.
@available(iOS 26.0, *)
public final class FoundationToolAdapter: Tool, @unchecked Sendable {
  public typealias Arguments = GeneratedContent
  public typealias Output = String

  /// 모델에게 보여줄 결과 글의 상한. 상한을 넘으면 자른 사실을 글에 적는다 —
  /// 조용히 잘라 모델이 전체를 봤다고 오인하게 두지 않는다.
  private static let responseCharacterLimit = 2_000

  public let name: String
  public let description: String
  public let parameters: GenerationSchema

  private let contract: CapabilityContract
  private let dispatcher: ActionDispatcher
  private let context: NativeToolContext
  private let observer: (any NativeToolObserver)?

  /// 읽기 전용이 아니거나 스키마를 만들 수 없는 계약은 **어댑터가 서지 않는다.**
  ///
  /// 권한 판정은 코어의 표 하나에서만 나온다(`CapabilityID.Authority`) — 이
  /// 파일이 새 분류를 만들지 않는다. 계약이 직접 선언한 권한이 있으면 그 값을,
  /// 없으면 코어의 표(`declaredAuthority`)를 본다 — 등록 시점의 판정
  /// (`CapabilityID.authority`)과 같은 순서다.
  ///
  /// 스키마 생성이 실패하면(`FoundationToolSchema.schema(for:)`가 던지면) 그
  /// 계약도 nil이다 — 스키마를 못 만든 도구를 모델에게 "이름만" 보여주면 모델은
  /// 부를 수 있다고 믿고 부르다가 실행 직전에야 실패를 본다.
  public init?(
    contract: CapabilityContract, description: String,
    dispatcher: ActionDispatcher, context: NativeToolContext,
    observer: (any NativeToolObserver)?
  ) {
    guard (contract.authority ?? contract.capability.declaredAuthority) == .observes else {
      return nil
    }
    guard let schema = try? FoundationToolSchema.schema(for: contract) else {
      return nil
    }
    self.contract = contract
    self.name = contract.capability.rawValue
    self.description = description
    self.parameters = schema
    self.dispatcher = dispatcher
    self.context = context
    self.observer = observer
  }

  public func call(arguments: GeneratedContent) async throws -> String {
    let extracted = extract(arguments)
    let normalized: [String: ActionValue]
    switch contract.normalize(extracted) {
    case .success(let values):
      normalized = values
    case .failure(let violation):
      // 모델이 이 오류를 보고 다시 채울 수 있어야 하므로 자리 이름을 그대로 문다.
      throw ActionError.invalidArguments(reason: violation.reason)
    }

    // **SDK는 call ID를 주지 않는다**(`docs/AGENT_RUNTIME_DESIGN.ko.md`
    // §현재 확인된 사실: "Tool.call(arguments:) 자체에는 SDK call ID가 없다").
    // 그래서 실행 정체 지문을 열쇠로 쓴다 — 같은 능력에 같은 정규화된 인자로
    // 두 번째 호출이 오면 같은 `callID`가 나오고, 아래 `idempotencyKey`가
    // 원장의 멱등 계약과 같은 모양(같은 열쇠는 한 번만 실행)이 된다.
    let callID = ActionFingerprint.call(contract.capability, normalized, binding: nil)

    await observer?.toolStarted(
      callID: callID, capability: contract.capability, arguments: normalized)

    let request = ActionRequest(
      capability: contract.capability,
      arguments: normalized,
      idempotencyKey: "\(context.turnID.uuidString)#\(callID)",
      origin: .modelPlan,
      conversationID: context.conversationID,
      accountID: context.accountID,
      turnID: context.turnID,
      accountEpoch: context.accountEpoch
      // `authorization`은 절대 붙이지 않는다. 읽기 전용만 이 경로에 오르므로
      // 자격이 필요 없고, 붙이면 이 native 호출 경로가 승인 없이 자격을 발급하는
      // 길이 된다.
    )

    let outcome = await dispatcher.dispatch(request)
    await observer?.toolFinished(callID: callID, capability: contract.capability, outcome: outcome)

    switch outcome {
    case .completed(let receipt):
      return render(receipt)
    case .waitingApproval:
      // 읽기 전용(`observes`)만 이 어댑터를 통과하므로, 여기 도달한 승인 대기는
      // `init?`의 계약이 깨졌다는 뜻이다 — 대기하지 않고 명확한 오류로 던진다.
      throw ActionError.failed(reason: "approvalInNativeLoop")
    case .failed(let reason):
      throw ActionError.failed(reason: reason)
    case .cancelled:
      throw ActionError.cancelled
    case .queued, .routing, .working:
      // `ActionDispatcher.dispatch`는 이 값들을 돌려주지 않는다(즉시
      // completed/failed/cancelled/waitingApproval 중 하나로 끝난다). 여기
      // 도달하면 실행 모델이 바뀐 것이므로 조용히 삼키지 않는다.
      throw ActionError.failed(reason: "unexpectedOutcome")
    }
  }

  /// `GeneratedContent`에서 계약이 아는 자리만 뽑는다.
  ///
  /// 계약의 `required`/`optional`만 순회하므로 **계약에 없는 열쇠는 애초에
  /// 읽지 않는다** — 버리는 코드가 따로 없다. `timestamp`는 ISO8601 문자열을
  /// 파싱하고, 실패하면 그 칸을 비운다(지어내지 않는다) — 어차피 필수 자리라면
  /// 뒤이은 `normalize`가 `missing`으로 잡는다.
  private func extract(_ content: GeneratedContent) -> [String: ActionValue] {
    var result: [String: ActionValue] = [:]
    for argument in contract.required + contract.optional {
      switch argument.kind {
      case .text:
        if let value = try? content.value(String?.self, forProperty: argument.key) {
          result[argument.key] = .text(value)
        }
      case .number:
        if let value = try? content.value(Double?.self, forProperty: argument.key) {
          result[argument.key] = .number(value)
        }
      case .flag:
        if let value = try? content.value(Bool?.self, forProperty: argument.key) {
          result[argument.key] = .flag(value)
        }
      case .timestamp:
        if let raw = try? content.value(String?.self, forProperty: argument.key),
          let date = Self.iso8601.date(from: raw)
        {
          result[argument.key] = .timestamp(date)
        }
      case .list:
        if let values = try? content.value([String]?.self, forProperty: argument.key) {
          result[argument.key] = .list(values.map(ActionValue.text))
        }
      }
    }
    return result
  }

  private static let iso8601 = ISO8601DateFormatter()

  /// 수령증을 **모델이 읽을 글**로 바꾼다.
  ///
  /// `staysOnDevice`(`final` + `verbatim`)인 능력은 본문을 싣지 않는다 — 그 값은
  /// 이미 화면이 그대로 그릴 산출물이고, 모델이 다시 문장을 덧붙이면 안 된다
  /// (`docs/AGENT_RUNTIME_DESIGN.ko.md` §ResultEnvelope). 그때는 "무엇을
  /// 했는가" 한 줄(`receipt.summary`)만 돌려준다.
  private func render(_ receipt: ActionReceipt) -> String {
    guard !contract.result.staysOnDevice else {
      return receipt.summary
    }
    var lines = [receipt.summary]
    for row in CapabilitySourceRow.rows(in: receipt.details) {
      let line = [row.title, row.subtitle, row.body]
        .filter { !$0.isEmpty }
        .joined(separator: " — ")
      if !line.isEmpty { lines.append(line) }
    }
    let joined = lines.joined(separator: "\n")
    guard joined.count > Self.responseCharacterLimit else { return joined }
    let truncated = String(joined.prefix(Self.responseCharacterLimit))
    return truncated + "\n[잘림: 전체 \(joined.count)자 중 \(Self.responseCharacterLimit)자만 표시]"
  }
}

/// 계약 목록을 **모델이 부를 수 있는 도구 목록**으로 바꾸는 조립 지점.
@available(iOS 26.0, *)
public enum AgentModelSession {
  /// 어댑터가 만들어지는 계약만 돌려준다.
  ///
  /// 나머지가 빠지는 이유는 하나다 — **쓰기라서.** `FoundationToolAdapter.init?`가
  /// 이미 그 계약을 거절했고, 여기서는 그 결과를 그대로 모은다. 조용히 빠지는
  /// 도구처럼 보이지만, 실제로는 승인 없는 native 실행을 막기 위해 명시적으로
  /// 배제된 것이다.
  public static func tools(
    contracts: [CapabilityContract], descriptions: [CapabilityID: String],
    dispatcher: ActionDispatcher, context: NativeToolContext,
    observer: (any NativeToolObserver)?
  ) -> [any Tool] {
    contracts.compactMap { contract in
      FoundationToolAdapter(
        contract: contract,
        description: descriptions[contract.capability] ?? contract.capability.rawValue,
        dispatcher: dispatcher, context: context, observer: observer)
    }
  }
}
