import XCTest

@testable import AgentKernel

/// 대역 기기 모델로 번역 계약만 본다. 실제 모델은 부르지 않는다.
final class TranslateToolTests: XCTestCase {
  func testShortTextPreservesLineBreaksAtTextKey() async throws {
    let model = ScriptedTextModel { prompt in
      prompt.replacingOccurrences(of: "Hello", with: "안녕")
        .replacingOccurrences(of: "World", with: "세계")
    }
    let tool = TranslateTool(model: model)
    let source = "Hello\nWorld"
    let receipt = try await tool.perform(Self.request(source, target: "ko"))

    XCTAssertEqual(
      receipt.details[SummarizeTool.textDetailKey]?.textValue, "안녕\n세계")
    XCTAssertEqual(
      tool.contracts.first?.result.intelligence, ResultEnvelope.deviceArtifact.intelligence)
    XCTAssertTrue(receipt.summary.contains("번역"))
  }

  func testUnavailableDeviceModelRefuses() async throws {
    let model = ScriptedTextModel(isAvailable: false) { _ in "no" }
    let tool = TranslateTool(model: model)
    do {
      _ = try await tool.perform(Self.request("Hello", target: "ko"))
      XCTFail("기기 모델이 없는데 번역했다고 말한다")
    } catch let error as ActionError {
      XCTAssertEqual(error, .unsupported(.textTranslate))
      XCTAssertEqual(model.calls, 0)
    }
  }

  func testPartialChunkFailureRecordsCoverage() async throws {
    let model = ScriptedTextModel { prompt in
      if prompt.contains("BBB") { throw TestFailure.chunk }
      return "ok:\(prompt.prefix(3))"
    }
    let filler = String(repeating: "AAA ", count: 40)
    let source = filler + "\n\n" + String(repeating: "BBB ", count: 40)
    let slices = TextChunker.slices(source, budget: 80)
    XCTAssertGreaterThan(slices.count, 1, "조각이 하나면 부분 실패를 볼 수 없다")

    let tool = TranslateTool(model: model, chunkBudget: 80)
    let receipt = try await tool.perform(Self.request(source, target: "ko"))
    XCTAssertEqual(receipt.coverage.first?.state, .partial)
    let text = try XCTUnwrap(receipt.details[SummarizeTool.textDetailKey]?.textValue)
    XCTAssertFalse(text.isEmpty)
    XCTAssertEqual(receipt.details["truncated"], .flag(true))
  }

  func testContractDeclaresDeviceArtifact() {
    let tool = TranslateTool(model: ScriptedTextModel { $0 })
    XCTAssertEqual(tool.contracts.first?.result, .deviceArtifact)
  }

  private static func request(_ source: String, target: String) -> ActionRequest {
    ActionRequest(
      capability: .textTranslate,
      arguments: ["sourceText": .text(source), "targetLanguage": .text(target)],
      origin: .modelPlan, conversationID: "l0", accountID: "l0")
  }
}

private enum TestFailure: Error { case chunk }

private final class ScriptedTextModel: OnDeviceTextModel, @unchecked Sendable {
  var isAvailable: Bool
  private(set) var calls = 0
  private let reply: (String) throws -> String

  init(isAvailable: Bool = true, reply: @escaping (String) throws -> String) {
    self.isAvailable = isAvailable
    self.reply = reply
  }

  func respond(
    instructions: String, prompt: String, purpose: AdmissionJob, maximumTokens: Int
  ) async throws -> String {
    calls += 1
    return try reply(prompt)
  }
}
