import AgentKernel
import XCTest

@testable import AgentOrchestration

/// L0 — **문맥이 넘치면 실패 대신 줄여서 계속되는가.**
///
/// `docs/REMAINING_WORK.ko.md` "문맥 압축과 기존 호출자 전환": context가 차면
/// 세션을 버리지 않고 transcript를 줄여 작업을 계속한다. `TurnRuntime.decide()`와
/// finalizing 답변 합성 경로 둘 다 이 wrapper로 전환됐다(evidence가 없는
/// `conversed(_:asking:)`는 압축 대상이 아니라 제외) — 이 시험은 wrapper 자체의
/// 계약을 독립적으로 증명한다. `TurnRuntime`이 표준 예산으로는 사실상 넘치지
/// 않도록(섹션별 예산이 이미 개별 강제된다 — `testNoCompiledContextExceedsTheBudget`)
/// 설계돼 있어, 실사용 오버플로우 재현은 작은 테스트 전용 budget이 필요하다(아래).
@available(iOS 26.0, *)
final class ContextCompactionTests: XCTestCase {
  private func evidence(_ count: Int) -> [Evidence] {
    (0..<count).map {
      Evidence(
        source: .web, sourceID: "doc-\($0)", title: "문서 \($0)",
        facts: [String(repeating: "본문 내용 조각입니다. ", count: 20)])
    }
  }

  private func profile(phase: TurnPhase = .reviewing) -> DynamicTurnProfile {
    DynamicTurnProfile.supervising(phase: phase, target: .privateCloud, scope: .empty)
  }

  /// 정상 크기 근거는 **압축 없이 그대로** 지어진다.
  func testSmallEvidenceCompilesWithoutDropping() throws {
    let compiler = ConversationContextCompiler()
    let result = try compiler.compileWithCompaction(
      profile: profile(), userMessage: "요약해줘", evidence: evidence(2),
      calendar: .current)
    XCTAssertEqual(result.droppedEvidenceCount, 0)
    XCTAssertTrue(result.context.carriesEvidence)
  }

  /// **근거 과다로 넘치면 뒤에서부터 줄여 다시 짓는다.** 실제 표준 예산은
  /// 섹션별 최대치의 합으로 설계되어 있어(`PCCContextBudget.assembled`) 근거
  /// 하나만으로는 거의 넘치지 않는다 — 그래서 이 시험은 **작은 테스트 전용
  /// budget**을 주입해 압축 루프 자체의 동작만 결정적으로 본다: 근거 조각이
  /// 있으면 넘치고, 다 빼면 들어가는 예산.
  func testOverflowingEvidenceIsDroppedFromTheLeastRelevantEnd() throws {
    // 고정 구획(tools·clock·markers)만으로도 예산을 이미 거의 채우고, 근거
    // 하나가 더해지면 반드시 넘치도록 절대값을 작게 둔다 — 실제 표준 예산의
    // 산술을 손으로 재현하지 않고 압축 루프의 동작만 결정적으로 본다.
    let tinyBudget = PCCContextBudget(
      requestCharacters: 2_000, instructionCharacters: 2_000, assembledCharacters: 500)
    let compiler = ConversationContextCompiler(budget: tinyBudget)
    let result = try compiler.compileWithCompaction(
      profile: profile(), userMessage: "요약해줘", evidence: evidence(6), calendar: .current)
    XCTAssertGreaterThan(result.droppedEvidenceCount, 0, "넘치는 근거인데 하나도 줄이지 않았다")
    // **뒤에서부터 빠졌는가.** `evidence(_:)`는 관련도 순으로 0...5를 만든다 —
    // 압축이 정말 "가장 관련도 낮은 조각부터"(뒤에서부터) 뺐다면, 가장 앞(문서
    // 0, 가장 관련도 높음)은 살아남고 가장 뒤(문서 5, 가장 관련도 낮음)는
    // 없어야 한다. `droppedEvidenceCount > 0`만으로는 몇 개가 줄었는지는 알아도
    // **어느 조각이** 줄었는지는 증명하지 못한다 — 앞에서부터 빼는 결함이 있어도
    // 이전 단정은 그대로 통과했을 것이다.
    XCTAssertTrue(
      result.context.prompt.contains("문서 0"),
      "가장 관련도 높은 근거(문서 0)가 압축 중 사라졌다 — 앞에서부터 빠진 것 아닌지 확인 필요")
    XCTAssertFalse(
      result.context.prompt.contains("문서 5"),
      "가장 관련도 낮은 근거(문서 5)가 압축 후에도 남아 있다 — 뒤에서부터 빼는 계약이 깨졌다")
  }

  /// **오해하기 쉬운 이름이었다**(리뷰 2026-09-18: "빈 근거 overflow"가 아니라
  /// 사용자 문장 자체가 큰 경로를 시험한다 — `evidence: []`는 "근거가 이미
  /// 0개"라는 뜻이지, 압축이 근거를 0개까지 줄인 결과가 아니다). 그 사실을
  /// 이름과 주석에 반영하고, `do` 블록이 던지지 않고 끝나는(즉 압축이 성공한)
  /// 성공 경로에도 `XCTFail`을 둔다 — 이전 코드는 그 경로에서 아무 단정도 없이
  /// 조용히 "통과"했다(구현이 실수로 성공을 돌려줘도 이 시험은 못 잡았다).
  func testUserMessageAloneOverflowsAndCannotBeFixedByDroppingEvidence() {
    let compiler = ConversationContextCompiler()
    let hugeMessage = String(
      repeating: "가", count: PCCContextBudget.standard.requestCharacters + 1)
    do {
      _ = try compiler.compileWithCompaction(
        profile: profile(), userMessage: hugeMessage, evidence: [], calendar: .current)
      XCTFail("근거 없이도 넘치는 사용자 문장이 압축 없이 그냥 통과했다")
    } catch let ContextCompactionError.unrecoverable(underlying) {
      // 사용자 문장 자체가 원인이면 근거 압축으로 고칠 수 없다 — 실패가 맞다.
      XCTAssertNotEqual(underlying, .requestTooLarge(actual: 0, limit: 0), "case만 비교")
    } catch {
      XCTFail("예상과 다른 오류: \(error)")
    }
  }

  /// **`requestTooLarge`는 재시도하지 않는다.** 근거를 줄여도 사용자 문장의
  /// 크기는 줄지 않으므로, 루프를 돌지 않고 즉시 실패해야 한다.
  func testRequestTooLargeFailsImmediatelyWithoutLoopingEvidence() {
    let compiler = ConversationContextCompiler()
    let hugeMessage = String(
      repeating: "가", count: PCCContextBudget.standard.requestCharacters + 1)
    do {
      _ = try compiler.compileWithCompaction(
        profile: profile(), userMessage: hugeMessage, evidence: evidence(5),
        calendar: .current)
      XCTFail("과도한 사용자 문장이 통과했다")
    } catch ContextCompactionError.unrecoverable(.requestTooLarge) {
      // expected
    } catch {
      XCTFail("잘못된 오류로 실패: \(error)")
    }
  }

  /// ledger의 근거는 이 함수가 손대지 않는다 — 호출자가 넘긴 원본 배열은
  /// 값 타입이라 애초에 함수 밖에서 변경될 수 없다. 반환값의
  /// `droppedEvidenceCount`만으로 무엇이 빠졌는지 센다.
  func testOriginalEvidenceArrayIsNeverMutatedByTheCaller() throws {
    let original = evidence(3)
    let compiler = ConversationContextCompiler()
    _ = try compiler.compileWithCompaction(
      profile: profile(), userMessage: "요약해줘", evidence: original, calendar: .current)
    XCTAssertEqual(original.count, 3, "호출자가 들고 있는 원본이 줄었다")
  }
}
