import Foundation

/// **이 실행이 어느 지시를 수행하는가**를 런타임이 확인한 결과(§7.4).
///
/// 사용자에게 승인창을 한 번 더 세우기 위한 물건이 아니다. `origin`은 감사
/// metadata일 뿐 권한이 아니므로(§2.4), 되돌릴 수 없는 실행의 자격은 이 값이 진다.
/// 모델은 proof를 발급하지 않는다 — 발급자는 결정론 라우터(사용자 문장 그대로),
/// 승인 문(사용자 확인), 등록된 자동화(AutomationGrant) 셋뿐이다.
///
/// 결합 대상: 계정·epoch·턴·능력·정규화된 호출 지문(인자와 binding 포함)·정책 판.
/// 수신자나 본문이 바뀌면 지문이 달라지므로 같은 proof로 실행되지 않는다.
public struct AuthorizationProof: Sendable, Hashable, Codable {
  public enum Source: String, Sendable, Codable {
    /// 결정론 라우터가 사용자 문장에서 대상·내용을 그대로 해석한 지시.
    case userInstruction
    /// 승인 문에서 사람이 확인한 것.
    case userConfirmation
    /// 명시적으로 등록한 좁은 자동화 범위(§9.6).
    case automationGrant
  }

  public let source: Source
  public let accountID: String
  public let accountEpoch: UInt64
  public let turnID: UUID
  public let capability: CapabilityID
  /// 정규화된 capability + 인자 + binding의 지문. 대상이 바뀌면 다른 값이다.
  public let callIdentity: String
  public let policyVersion: Int
  public let grantedAt: Date
  public let expiresAt: Date

  public init(
    source: Source,
    accountID: String,
    accountEpoch: UInt64,
    turnID: UUID,
    capability: CapabilityID,
    callIdentity: String,
    policyVersion: Int,
    grantedAt: Date,
    expiresAt: Date
  ) {
    self.source = source
    self.accountID = accountID
    self.accountEpoch = accountEpoch
    self.turnID = turnID
    self.capability = capability
    self.callIdentity = callIdentity
    self.policyVersion = policyVersion
    self.grantedAt = grantedAt
    self.expiresAt = expiresAt
  }

  /// 이 요청을 이 proof로 실행할 수 있는가. 하나라도 어긋나면 실행 자격이 없다.
  public func authorizes(_ request: ActionRequest, at now: Date = Date()) -> Bool {
    guard now < expiresAt,
      accountID == request.accountID,
      accountEpoch == request.accountEpoch,
      turnID == request.turnID,
      capability == request.capability,
      policyVersion == request.policyVersion,
      callIdentity
        == ActionFingerprint.call(
          request.capability, request.arguments, binding: request.binding)
    else { return false }
    return true
  }

  /// 만료는 실행 자격의 수명이지 효과의 정체가 아니다(§7.5) — 지문과 따로 둔다.
  public static let defaultLifetime: TimeInterval = 300

  public static func issue(
    for request: ActionRequest,
    source: Source,
    lifetime: TimeInterval = AuthorizationProof.defaultLifetime,
    now: Date = Date()
  ) -> AuthorizationProof {
    AuthorizationProof(
      source: source,
      accountID: request.accountID,
      accountEpoch: request.accountEpoch,
      turnID: request.turnID,
      capability: request.capability,
      callIdentity: ActionFingerprint.call(
        request.capability, request.arguments, binding: request.binding),
      policyVersion: request.policyVersion,
      grantedAt: now,
      expiresAt: now.addingTimeInterval(lifetime))
  }
}
