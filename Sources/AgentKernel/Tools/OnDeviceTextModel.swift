import Foundation

/// 기기 모델의 **창 크기**. 요약·번역 툴이 조각을 나누는 단 하나의 근거다.
///
/// 한 자리에만 선언한다. `SummaryModel`과 `OnDeviceTextModel`이 각자 같은 이름의
/// 기본 구현을 들면, **둘 다 채택한 타입**에서 어느 기본값을 쓸지 정해지지
/// 않아 두 프로토콜 모두 미충족이 된다(코어 시험 번들이 그 자리였다).
public protocol ModelContextWindow: Sendable {
  var contextWindowTokens: Int { get }
}

// 기존 호스트를 위한 보수적 기본값. 실제 제공자는 자기 창을 적는다.
public extension ModelContextWindow {
  var contextWindowTokens: Int { 4096 }
}

/// 툴이 **기기 안에서** 쓰는 모델.
///
/// PCC가 못 하는 일을 툴이 한다 — 그 툴 중 일부는 자기 일을 하려고 모델을 쓴다:
/// 스캔한 문서에서 값을 뽑고, 웹 페이지를 사실 몇 줄로 줄이고, 긴 본문을
/// 요약한다. 그 일을 PCC로 올리면 **원문이 기기를 떠나고** 비용도 함께 오른다.
///
/// 툴이 `SystemLanguageModel`을 직접 부르지 않고 이 문을 지나는 이유:
///
/// 1. **기기 모델은 하나다.** 툴 둘이 동시에 부르면 둘 다 느려진다 —
///    `ModelAdmission`이 순서를 정한다.
/// 2. **발열 정책이 한 자리에 있다.** 툴마다 자기 게이트를 들면 정책이 툴 수만큼
///    갈라지고, 그중 하나는 반드시 게이트 없이 돈다.
/// 3. **기다린 시간이 지표에 남는다.** 어느 목적이 줄을 오래 쥐었는지 말할 수 있다.
public protocol OnDeviceTextModel: ModelContextWindow {
  /// 지시와 프롬프트로 짧은 글 한 편. 구조화 산출이 필요하면 툴이 자기
  /// `@Generable` 타입으로 직접 세션을 쓰되, 입장은 이 문으로 받는다.
  ///
  /// - Parameters:
  ///   - purpose: 지표의 열쇠. 툴은 자기 이름을 `AdmissionJob`으로 선언한다.
  ///   - maximumTokens: 산출 상한. 요약이 길어지는 것은 곧 다음 단계의 문맥이
  ///     커지는 것이다.
  func respond(
    instructions: String, prompt: String, purpose: AdmissionJob, maximumTokens: Int
  ) async throws -> String

  /// 이 기기에서 기기 모델을 쓸 수 있는가. 쓸 수 없으면 툴은 **모델 없이 할 수
  /// 있는 일만** 하고, 못 한 것을 못 했다고 말한다.
  var isAvailable: Bool { get }
}
