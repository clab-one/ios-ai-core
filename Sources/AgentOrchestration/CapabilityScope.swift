import AgentKernel
import Foundation


/// 이 차례에 모델에게 **보이는 도구 집합**.
///
/// 예전에는 프로파일 하나만 골랐다(`ToolProfile.resolve`). 그 구조에서
/// `"Slack에서 찾은 내용을 내일 일정으로 만들어줘"`는 `communication`이거나
/// `schedule`이었고 둘 다일 수는 없었다 — 모델은 자기가 다음에 필요할 도구를
/// **볼 수조차 없었다.** 그것이 조합 요청이 조용히 반쪽으로 끝난 이유다.
///
/// 그래서 범위는 합집합이고, 언제나 세 겹의 교집합으로 잘린다(§8):
///
/// ```
/// 원하는 능력 ∩ 등록된 능력 ∩ 허용된 능력
/// ```
///
/// 마지막 겹이 최소 권한이다. 쓰기 동사가 없는 문장에는 **읽기만** 펼친다 —
/// 문장이 시키지 않은 삭제를 모델이 고를 자리를 만들지 않는다.
public struct CapabilityScope: Sendable, Equatable {
  public let capabilities: Set<CapabilityID>
  /// 이 범위가 어느 영역에서 나왔는가. 계측과 시험이 읽는다(원문은 담지 않는다).
  public let domains: Set<CapabilityDomain>

  public static let empty = CapabilityScope(capabilities: [], domains: [])

  public var isEmpty: Bool { capabilities.isEmpty }

  /// 모델에게 세울 도구 목록. 순서를 고정한다 — 같은 요청이 같은 프롬프트를 만든다.
  public var sorted: [CapabilityID] {
    capabilities.sorted { $0.rawValue < $1.rawValue }
  }

  public func contains(_ capability: CapabilityID) -> Bool {
    capabilities.contains(capability)
  }

  /// 능력 하나를 걷어낸 범위.
  ///
  /// 쓰는 자리는 하나다: **이 제출이 이미 보관함에 들어간 경우**. 외부 데이터는
  /// 정본 캡처가 저장하고(`StreamRuntime.submitRecord`), 그때 저장 툴이 손에
  /// 남아 있으면 모델이 같은 것을 한 번 더 저장한다 — `"<주소> 기억해"` 한 번에
  /// 기록이 두 건 남는다.
  public func removing(_ capability: CapabilityID) -> CapabilityScope {
    guard capabilities.contains(capability) else { return self }
    let remaining = capabilities.subtracting([capability])
    return CapabilityScope(
      capabilities: remaining,
      domains: Set(remaining.compactMap { CapabilityDomain.named($0.domain) }))
  }

  /// 스케치에서 범위를 만든다.
  ///
  /// `registered`는 지금 실제로 손이 달린 능력이다. 연결되지 않은 서비스를 도구
  /// 목록에 세우면 모델이 그것을 고르고, 그 계획은 실행 직전에 죽는다.
  public static func compile(
    _ sketch: IntentSketch, registered: Set<CapabilityID>
  ) -> CapabilityScope {
    var desired: Set<CapabilityID> = []
    for domain in sketch.domains {
      // **쓰기 동사가 없으면 읽기만.** 회수율은 영역 단위로 넓히고, 권한은
      // 동작 단위로 좁힌다 — 그 둘을 한 손잡이로 묶으면 둘 중 하나가 틀린다.
      desired.formUnion(sketch.wantsWrite ? domain.capabilities : domain.readCapabilities)
    }
    // 되돌릴 수 없는 삭제는 **문장이 삭제를 말했을 때만** 보인다. 승인 문이
    // 뒤에 서 있어도, 보이지 않는 도구는 잘못 골릴 수 없다.
    if !sketch.operations.contains(.delete) {
      desired = desired.filter {
        $0 != .calendarDelete && $0 != .remindersDelete && $0 != .shareRevoke
      }
    }
    // 저장은 사용자가 저장을 말했을 때만. 조회 요청이 기록을 만들지 않는다.
    if !sketch.operations.contains(.save) { desired.remove(.memorySave) }
    if !sketch.operations.contains(.record) {
      desired.subtract([.recordingStart, .recordingStop])
    }
    let allowed = desired.intersection(registered)
    let domains = Set(allowed.compactMap { CapabilityDomain.named($0.domain) })
    return CapabilityScope(capabilities: allowed, domains: domains)
  }

  /// 이 범위가 **무엇을 뺀 것인가**를 기록해 둔 자리는 없다.
  ///
  /// 끝난 쓰기를 범위에서 숨기던 손잡이가 여기 있었다. 숨기면
  /// `"두 사람에게 각각 보내줘"`가 반만 일어난다 — 첫 전송이 끝나자 그 능력이
  /// 사라져 두 번째를 계획할 수 없었다. 중복은 호출의 정체가 막는다
  /// (`TurnRuntime.callIdentity`): 같은 인자는 같은 멱등 열쇠로 막히고, 다른
  /// 인자는 다른 일이다. 감독자는 끝난 일을 `<<<completed>>>`로 본다.
}
