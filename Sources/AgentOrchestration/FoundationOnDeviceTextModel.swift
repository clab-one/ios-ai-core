import AgentKernel
import Foundation
import FoundationModels

/// 기기의 Apple Intelligence 모델. 툴이 쓰는 유일한 구현이다.
///
/// 입장 제어를 지난다(`ModelAdmission`) — 발열·저전력에서 기다리고, 여러 툴의
/// 호출을 한 줄로 세운다. 호출 하나가 줄에서 기다린 시간은 호출자에게 돌려준다.
@available(iOS 26.0, *)
public struct FoundationOnDeviceTextModel: OnDeviceTextModel {
  private let model: SystemLanguageModel

  public init(model: SystemLanguageModel = .default) {
    self.model = model
  }

  public var isAvailable: Bool {
    if case .available = model.availability { return true }
    return false
  }

  public func respond(
    instructions: String, prompt: String, purpose: AdmissionJob, maximumTokens: Int
  ) async throws -> String {
    let session = try DynamicProfileAdapter.onDeviceSession(
      instructions: instructions, model: model)
    return try await ModelAdmission.withAdmission(for: purpose) {
      let response = try await session.respond(
        to: prompt,
        options: GenerationOptions(maximumResponseTokens: maximumTokens))
      return response.content
    }
  }
}
