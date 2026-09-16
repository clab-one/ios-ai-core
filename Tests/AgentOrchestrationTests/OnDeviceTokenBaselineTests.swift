import AgentKernel
import FoundationModels
import XCTest

@testable import AgentOrchestration

/// **L1: 진짜 토크나이저로 잰다.** PCC는 부르지 않는다.
///
/// 이 저장소의 예산은 전부 **글자**다(`PCCContextBudget`). 글자를 고른 이유는
/// 호출 전에 셀 수 있는 유일한 값이기 때문인데, 비용은 토큰으로 매겨진다. 두 값의
/// 환산비를 모르면 예산은 방향만 맞고 크기는 모르는 값이다.
///
/// `SystemLanguageModel.tokenCount(for:)`(iOS 26.4)가 그 환산을 실측으로 돌려준다.
/// PCC 모델과 기기 모델이 같은 토크나이저를 쓴다는 보장은 없으므로 여기서 얻는 것은
/// **자리표**다 — PCC의 실제 값은 호출이 돌려주는 `usage`에 있고, 그 값은
/// `ModelInvocationReceipt`에 남는다.
///
/// 기준선 숫자를 아직 박지 않았다. 재지 않은 값을 상한으로 적으면 그 상한은
/// 지어낸 값이다 — 실기에서 한 번 돌린 뒤 `📐` 줄의 값으로 박는다.
@available(iOS 26.4, *)
final class OnDeviceTokenBaselineTests: XCTestCase {

  /// 계획 스키마 한 벌의 토큰. **`@Guide` 한 줄의 가격이 이 값이다.**
  ///
  /// 이 값이 왜 필요한가: 문맥 글자 수는 스키마를 세지 않는다(golden의 `context=`는
  /// 문맥 문자열만 잰다). 그래서 `@Guide` 문구를 늘리는 커밋은 L0의 어떤 예산도
  /// 건드리지 않으면서 **매 계획 호출의 비용**을 늘린다.
  func testPlanSchemaTokenCost() async throws {
    let model = SystemLanguageModel.default
    try XCTSkipUnless(model.isAvailable, "이 기기에 기기 모델이 없다: \(model.availability)")

    let schema = GeneratedTurnDecision.generationSchema
    let tokens = try await model.tokenCount(for: schema)
    print("📐 schema: plan=\(tokens)토큰")
    XCTAssertGreaterThan(tokens, 0, "스키마를 재지 못했다")
  }

  /// **한국어와 영어의 글자당 토큰이 다르다.**
  ///
  /// Apple TN3193은 라틴 문자 세~네 글자가 한 토큰, CJK는 대략 한 글자가 한 토큰이라고
  /// 적는다. 그 비율이 맞다면 같은 글자 예산이 한국어에서 세 배 비싸다 — 예산의
  /// 단위를 글자로 두는 한, 이 비율은 알고 있어야 하는 값이다.
  func testCharactersPerTokenByScript() async throws {
    let model = SystemLanguageModel.default
    try XCTSkipUnless(model.isAvailable, "이 기기에 기기 모델이 없다: \(model.availability)")

    let korean = String(repeating: "애플은 서버에서 도는 추론의 검증 가능성을 이야기한다. ", count: 20)
    let english = String(
      repeating: "Apple describes the verifiability of inference that runs on servers. ",
      count: 20)

    let koreanTokens = try await model.tokenCount(for: Prompt(korean))
    let englishTokens = try await model.tokenCount(for: Prompt(english))
    let koreanRatio = Double(korean.count) / Double(koreanTokens)
    let englishRatio = Double(english.count) / Double(englishTokens)

    print(
      """
      📐 ratio: ko=\(korean.count)자/\(koreanTokens)토큰=\(String(format: "%.2f", koreanRatio)) \
      en=\(english.count)자/\(englishTokens)토큰=\(String(format: "%.2f", englishRatio))
      """)
    XCTAssertGreaterThan(englishRatio, koreanRatio, "라틴 문자가 한국어보다 토큰당 글자가 적다")
  }

  /// 근거 한 조각의 상한이 **토큰으로 얼마인가.**
  ///
  /// P2에서 줄이려는 값들이다(`factLimit` 240, `factsPerEvidence` 3,
  /// `contextCharacterLimit`). 줄일 크기를 글자로만 고르면 얼마를 아끼는지 모른 채
  /// 기능을 깎는다.
  func testEvidenceLimitsInTokens() async throws {
    let model = SystemLanguageModel.default
    try XCTSkipUnless(model.isAvailable, "이 기기에 기기 모델이 없다: \(model.availability)")

    let fact = String(repeating: "가", count: Evidence.factLimit)
    let piece = String(repeating: "나", count: Evidence.contextCharacterLimit)
    let factTokens = try await model.tokenCount(for: Prompt(fact))
    let pieceTokens = try await model.tokenCount(for: Prompt(piece))

    print(
      """
      📐 evidence: fact=\(Evidence.factLimit)자/\(factTokens)토큰 \
      piece=\(Evidence.contextCharacterLimit)자/\(pieceTokens)토큰 \
      evidence×\(ConversationContextCompiler.evidenceLimit)
      """)
    XCTAssertGreaterThan(factTokens, 0)
    XCTAssertGreaterThan(pieceTokens, factTokens, "더 긴 글이 더 적은 토큰이다")
  }
}
