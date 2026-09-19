import AgentKernel
import FoundationModels
import XCTest

@testable import AgentOrchestration

/// L0 — **native tool 다리는 읽기 전용만 지나간다**
/// (`docs/AGENT_RUNTIME_DESIGN.ko.md` §Native tool bridge).
///
/// SDK의 `Tool.call`은 모델 세션이 `respond()`를 실행하는 도중 SDK가 직접
/// 부른다 — 그 앞에는 사람이 승인할 대기 지점이 없다. 이 시험이 지키는 것은
/// "변환이 돈다"가 아니라 **쓰기 능력은 애초에 도구가 되지 못한다**는 경계다.
@available(iOS 26.0, *)
final class FoundationToolAdapterTests: XCTestCase {
  private func context(conversationID: String? = "conv") -> NativeToolContext {
    NativeToolContext(
      accountID: "acct", conversationID: conversationID, turnID: UUID(),
      accountEpoch: AssistantAccountEpoch.current)
  }

  /// **쓰기 능력에는 어댑터 자체가 서지 않는다.** `mail.send`는 코어의 표에서
  /// `.leavesTheDevice`다 — `init?`가 nil을 돌려주는지가 이 경로의 유일한 문이다.
  func testWriteCapabilityRefusesAdapter() {
    let dispatcher = ActionDispatcher(currentAccountID: { "acct" })
    let contract = CapabilityContract(
      .mailSend, required: [.init("to"), .init("body")], optional: [.init("subject")])
    let adapter = FoundationToolAdapter(
      contract: contract, description: "메일 보내기", dispatcher: dispatcher,
      context: context(), observer: nil)
    XCTAssertNil(adapter, "쓰기 능력(mail.send)에 native 도구 어댑터가 서면 안 된다")
  }

  /// 읽기 능력 호출이 실제로 `ActionDispatcher`를 지나 `FixtureTool`을 실행하고,
  /// 수령증의 줄(`CapabilitySourceRow`)이 모델이 읽을 글에 그대로 실린다.
  func testReadCapabilityExecutesThroughDispatcherAndReturnsReceiptRow() async throws {
    let dispatcher = ActionDispatcher(currentAccountID: { "acct" })
    let fixture = FixtureTool(.mailSearch, required: [.init("query")]) { _ in
      [
        CapabilitySourceRow(
          title: "분기 보고서", subtitle: "steve@example.com", body: "본문 요약",
          identifier: "msg-1")
      ]
    }
    await dispatcher.register(fixture)
    let contract = CapabilityContract(.mailSearch, required: [.init("query")])
    let adapter = try XCTUnwrap(
      FoundationToolAdapter(
        contract: contract, description: "메일 검색", dispatcher: dispatcher,
        context: context(), observer: nil))

    let text = try await adapter.call(arguments: GeneratedContent(json: #"{"query":"분기"}"#))

    XCTAssertTrue(text.contains("분기 보고서"), "수령증 줄이 모델이 읽는 글에 없다: \(text)")
    XCTAssertEqual(fixture.requests.first?.arguments["query"], .text("분기"), "dispatcher를 지나지 않았다")
  }

  /// observer는 시작과 끝을 **같은 callID**로 본다 — SDK가 call ID를 주지 않으므로
  /// 어댑터가 만든 지문이 시작·끝 통지에서 일관돼야 journal 상관관계가 선다.
  func testObserverSeesSameCallIDForStartAndFinish() async throws {
    final class RecordingObserver: NativeToolObserver, @unchecked Sendable {
      private(set) var started: [String] = []
      private(set) var finished: [String] = []
      func toolStarted(
        callID: String, capability: CapabilityID, arguments: [String: ActionValue]
      ) async {
        started.append(callID)
      }
      func toolFinished(callID: String, capability: CapabilityID, outcome: ActionOutcome) async {
        finished.append(callID)
      }
    }

    let dispatcher = ActionDispatcher(currentAccountID: { "acct" })
    let fixture = FixtureTool(.mailSearch, required: [.init("query")]) { _ in [] }
    await dispatcher.register(fixture)
    let contract = CapabilityContract(.mailSearch, required: [.init("query")])
    let observer = RecordingObserver()
    let adapter = try XCTUnwrap(
      FoundationToolAdapter(
        contract: contract, description: "메일 검색", dispatcher: dispatcher,
        context: context(), observer: observer))

    _ = try await adapter.call(arguments: GeneratedContent(json: #"{"query":"x"}"#))

    XCTAssertEqual(observer.started.count, 1)
    XCTAssertEqual(observer.finished.count, 1)
    XCTAssertEqual(observer.started.first, observer.finished.first, "시작·끝의 callID가 다르다")
  }

  /// 계약에 없는 열쇠는 실행 인자에서 사라지고, 필수 자리가 비면 모델이 다시
  /// 채울 수 있게 `invalidArguments`를 던진다.
  func testUnknownArgumentDroppedAndMissingRequiredThrowsInvalidArguments() async throws {
    let dispatcher = ActionDispatcher(currentAccountID: { "acct" })
    let fixture = FixtureTool(.mailSearch, required: [.init("query")]) { _ in [] }
    await dispatcher.register(fixture)
    let contract = CapabilityContract(.mailSearch, required: [.init("query")])
    let adapter = try XCTUnwrap(
      FoundationToolAdapter(
        contract: contract, description: "메일 검색", dispatcher: dispatcher,
        context: context(), observer: nil))

    _ = try await adapter.call(
      arguments: GeneratedContent(json: #"{"query":"x","bogus":"y"}"#))
    let executed = try XCTUnwrap(fixture.requests.first)
    XCTAssertNil(executed.arguments["bogus"], "계약에 없는 열쇠가 실행 인자까지 살아남았다")

    do {
      _ = try await adapter.call(arguments: GeneratedContent(json: "{}"))
      XCTFail("필수 자리가 빈 채로 실행됐다")
    } catch ActionError.invalidArguments(let reason) {
      XCTAssertTrue(reason.contains("query"), "이유 문자열이 모자란 자리를 말하지 않는다: \(reason)")
    }
  }

  /// `staysOnDevice`(`final`+`verbatim`) 능력은 본문 대신 "무엇을 했는가" 한
  /// 줄만 돌려준다 — 기기 산출물이 모델 입력에 다시 실리지 않는다.
  func testStaysOnDeviceCapabilityReturnsSummaryLineOnly() async throws {
    let dispatcher = ActionDispatcher(currentAccountID: { "acct" })
    let fixture = FixtureTool(.textSummarize, required: [.init("sourceText")]) { _ in
      [CapabilitySourceRow(title: "요약 제목", subtitle: "", body: "이 본문은 모델 글에 실리면 안 된다")]
    }
    await dispatcher.register(fixture)
    let contract = CapabilityContract(
      .textSummarize, required: [.init("sourceText")], result: .deviceArtifact)
    let adapter = try XCTUnwrap(
      FoundationToolAdapter(
        contract: contract, description: "요약", dispatcher: dispatcher,
        context: context(), observer: nil))

    let text = try await adapter.call(
      arguments: GeneratedContent(json: #"{"sourceText":"원문"}"#))

    XCTAssertEqual(text, "text.summarize.result", "staysOnDevice 능력은 summary 한 줄만 돌려줘야 한다")
    XCTAssertFalse(text.contains("이 본문은"), "기기 산출물의 본문이 모델 글에 실렸다")
  }
}
