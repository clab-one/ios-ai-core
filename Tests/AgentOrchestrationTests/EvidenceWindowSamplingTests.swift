import AgentKernel
import XCTest

@testable import AgentOrchestration

/// **L0.** `EvidenceCompiler.window`/`relevantSentences`가 질의 낱말이 없을 때
/// (순수 "요약해줘"류 지시) 문서 맨 앞만 보지 않는가를 본다.
///
/// 실측(2026-09-17 Yahoo Finance, `WebReadTool` 문서 주석)에서 맨 앞 4,000자가
/// 전부 메뉴·추천글이고 기사 산문은 한 줄도 없었다 — 그 실패를 고정한다.
final class EvidenceWindowSamplingTests: XCTestCase {
  /// 앞부분은 전부 메뉴, 실제 산문은 문서 중반부터.
  private static func menuHeavyDocument(marker: String) -> String {
    let menu = String(repeating: "메뉴 링크. ", count: 400)  // ~2,400자, 순수 잡음
    let article = marker + " " + String(repeating: "실제 기사 문장입니다. ", count: 200)
    return menu + article
  }

  /// **질의 낱말이 없으면** 앞만 자르지 않고 문서 뒤쪽도 함께 담는다.
  func testWindowIncludesLaterSegmentWhenNoAnchorIsFound() {
    let marker = "DEEP-ARTICLE-MARKER"
    let text = Self.menuHeavyDocument(marker: marker)
    XCTAssertGreaterThan(text.count, 4_000, "픽스처가 충분히 길지 않다")

    let window = EvidenceCompiler.window(in: text, around: nil, limit: 4_000)

    XCTAssertTrue(
      window.contains(marker),
      "질의 낱말이 없을 때 앞 구간만 보내 문서 중반의 기사 표지를 놓쳤다")
  }

  /// 질의 낱말이 실제로 있으면 **그 자리를 품는 창**을 그대로 쓴다(회귀 방지 —
  /// 이번 수정이 앵커가 있는 기존 경로를 건드리지 않았는가).
  func testWindowStillCentersOnAnchorWhenQueryTermIsFound() {
    let marker = "검증가능성"
    let text = String(repeating: "잡음 문장. ", count: 800) + marker
      + String(repeating: " 뒤 문장.", count: 800)
    let offset = EvidenceCompiler.firstRelevantOffset(in: text, terms: ["검증가능성"])
    let window = EvidenceCompiler.window(in: text, around: offset, limit: 2_000)

    XCTAssertTrue(window.contains(marker), "앵커가 있는데도 그 자리를 담지 못했다")
    XCTAssertFalse(
      window.contains("…"),
      "앵커가 있는 경로는 이어진 한 창이어야 한다 — 구분자가 섞이면 안 된다")
  }

  /// **짧은 문서**는 그대로 돌려준다(상한 밑이면 표본을 나누지 않는다).
  func testWindowReturnsWholeTextWhenUnderLimit() {
    let text = "짧은 문서입니다."
    XCTAssertEqual(EvidenceCompiler.window(in: text, around: nil, limit: 4_000), text)
  }

  /// **짧은 본문(대화 스크린샷 OCR 등)은 문장으로 쪼개 3개만 고르지 않는다.**
  /// 실측: OCR 240자 미만 대화를 번역 요청했을 때 `relevantSentences`가 앞
  /// 세 문장만 남겨 뒤쪽 대화가 답에서 통째로 사라졌다. 이미 한 사실 상한
  /// 안에 들어가는 본문은 그대로 하나의 사실로 싣는다.
  func testDeterministicKeepsWholeBodyWhenItAlreadyFitsInOneFact() {
    let conversation = [
      "민수: 내일 몇 시에 만날까?",
      "지은: 3시 어때?",
      "민수: 좋아, 어디서?",
      "지은: 역 앞 카페에서 보자",
      "민수: 알겠어, 이따 봐",
    ].joined(separator: "\n")
    XCTAssertLessThanOrEqual(conversation.count, Evidence.factLimit, "픽스처가 상한을 넘으면 이 시험의 전제가 깨진다")

    let row = CapabilitySourceRow(title: "대화", body: conversation, identifier: "shot-1")
    let evidence = EvidenceCompiler.deterministic(row, source: .init(domain: "memory"), terms: [])

    XCTAssertEqual(evidence.facts.count, 1, "짧은 본문을 여러 사실로 쪼갰다")
    XCTAssertEqual(evidence.facts.first, conversation, "짧은 본문의 일부만 근거로 남았다 — 뒤쪽 발화가 사라졌다")
  }

  /// 상한을 **넘는** 본문은 여전히 질의 관련 문장 선별을 탄다(회귀 방지 —
  /// 이번 수정이 긴 본문 경로를 건드리지 않았는가).
  func testDeterministicStillExtractsRelevantSentencesWhenBodyExceedsFactLimit() {
    let long = String(repeating: "잡음 문장입니다. ", count: 60) + "실제 답 문장입니다."
    XCTAssertGreaterThan(long.count, Evidence.factLimit)

    let row = CapabilitySourceRow(title: "문서", body: long, identifier: "doc-1")
    let evidence = EvidenceCompiler.deterministic(row, source: .init(domain: "memory"), terms: ["실제답"])

    XCTAssertLessThanOrEqual(evidence.facts.count, Evidence.factsPerEvidence)
    XCTAssertTrue(
      evidence.facts.contains { $0.contains("실제 답 문장") },
      "긴 본문에서 질의와 겹치는 문장을 고르지 못했다")
  }
  /// `relevantSentences`도 같은 실패를 고정한다: 낱말 겹침이 없으면 앞줄만
  /// 고르지 않고 문서 1/3 지점의 문장도 섞는다.
  func testRelevantSentencesSpreadsAcrossDocumentWhenNoTermsOverlap() {
    let marker = "실제기사문장입니다"
    let sentences = (0..<30).map { i in
      i == 10 ? "\(marker)." : "메뉴 링크 \(i)."
    }
    let body = sentences.joined(separator: " ")

    let picked = EvidenceCompiler.relevantSentences(in: body, terms: [])

    XCTAssertTrue(
      picked.contains { $0.contains(marker) },
      "낱말 겹침이 없을 때 앞줄만 골라 문서 1/3 지점의 문장을 놓쳤다")
  }

  // MARK: 조각 선택 — 긴 본문이 근거로 옮겨질 때 문서 뒤쪽도 실리는가

  /// 앞은 메뉴, 뒤는 마커가 촘촘히 박힌 문서. 조각 단위 선택(`selectedSlices`)과
  /// 그 결과가 실제 근거(`deterministic`)에 살아남는지를 함께 본다 — 뒤쪽 조각이
  /// 여러 개라 그 전부가 마커 문장이면, 어느 조각이 뽑히든 마커는 살아남는다.
  private static func chunkedTailDocument(marker: String) -> String {
    let menu = String(repeating: "메뉴 링크. ", count: 400)  // ~2,800자, 순수 잡음(앞)
    let filler = String(repeating: "실제 기사 문장입니다. ", count: 400)  // 중간, 조각을 여럿 만든다
    let tail = String(repeating: "\(marker) 관련 문장입니다. ", count: 200)  // 뒤, 조각마다 마커가 있다
    return menu + filler + tail
  }

  /// **문서 뒤쪽 조각도 고른다.** 앞에서 N개만 고르면 메뉴·머리말만 읽는
  /// 실패(`window`의 실측 주석)를 조각 단위로 되풀이한다.
  func testSelectedSlicesIncludesTheLastSliceWhenNoTermsOverlap() {
    let body = Self.chunkedTailDocument(marker: "TAIL-FACT-MARKER")
    XCTAssertGreaterThan(body.count, 8_000, "픽스처가 충분히 길지 않다")

    let slices = TextChunker.slices(body)
    XCTAssertGreaterThan(slices.count, 3, "조각이 충분히 나뉘지 않았다")

    let picked = EvidenceCompiler.selectedSlices(slices, terms: [], limit: 3)

    XCTAssertEqual(
      picked.map(\.sequence), picked.map(\.sequence).sorted(),
      "조각이 문서 순서로 되돌아오지 않았다")
    XCTAssertEqual(
      picked.last?.sequence, slices.last?.sequence,
      "마지막 조각이 고른 표본에 없다 — 문서 뒤쪽이 답에서 빠진다")
  }

  /// 질문과 겹치는 조각이 있으면 그 조각부터 고른다.
  func testSelectedSlicesPrefersTheOverlappingSlice() {
    let anchor = "고유단어마커"
    let filler = String(repeating: "잡음 문장입니다. ", count: 400)
    let body = filler + anchor + " 관련 문장입니다. " + filler + filler
    let slices = TextChunker.slices(body)
    XCTAssertGreaterThan(slices.count, 2, "픽스처가 조각 여러 개로 나뉘지 않았다")

    let picked = EvidenceCompiler.selectedSlices(slices, terms: [anchor], limit: 3)

    XCTAssertTrue(
      picked.contains { $0.body.contains(anchor) },
      "겹치는 낱말이 있는데도 그 조각을 고르지 못했다")
  }

  /// **종단.** 긴 본문 한 줄이 근거로 옮겨질 때 문서 뒤쪽의 사실이 답의 근거에
  /// 실린다 — 388,754자 문서 실측(`EvidenceStrategy` 주석)의 재현.
  func testCompileCarriesTheDocumentTailAsEvidence() async {
    let marker = "TAIL-FACT-MARKER"
    let body = Self.chunkedTailDocument(marker: marker)
    XCTAssertGreaterThan(body.count, 8_000, "픽스처가 충분히 길지 않다")

    let row = CapabilitySourceRow(title: "긴 문서", body: body, identifier: "doc-tail-1")
    let receipt = ActionReceipt(
      requestID: UUID(), capability: .memoryRead, summary: "memory.read.result",
      details: CapabilitySourceRow.detail([row]))

    // 기기 모델 0회 = 결정론 경로. 시뮬레이터의 기기 모델 유무에 이 시험이
    // 좌우되지 않는다.
    let compiled = await EvidenceCompiler(query: "요약해줘")
      .compile([receipt], budget: LocalExtractionBudget(limit: 0))

    XCTAssertGreaterThan(compiled.evidence.count, 1, "긴 본문이 조각으로 펼쳐지지 않았다 — 근거가 하나뿐이다")
    XCTAssertTrue(
      compiled.evidence.contains { $0.facts.contains { $0.contains(marker) } },
      "문서 뒤쪽의 사실이 근거에 한 번도 오르지 않았다")
    XCTAssertTrue(
      compiled.evidence.allSatisfy { $0.sourceID == row.identifier },
      "조각의 출처 식별자가 원래 줄과 달라 출처 카드를 잃는다")
  }
}
