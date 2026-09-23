// swift-tools-version: 6.0
import PackageDescription

/// Apple 플랫폼 AI 오케스트레이션 코어(iOS 26+, macOS 27+).
///
/// 앱이 아니라 **실행 평면**이다. 여기에는 화면도, 저장 스키마도, 공급자 SDK도
/// 없다 — 능력의 이름과 계약, 그 계약을 지나는 단 하나의 실행 문, 그리고 모델이
/// 채울 좁은 칸만 있다. 붙이는 앱이 자기 저장소·권한·화면을 어댑터로 물려 준다.
///
/// 의존성이 비어 있는 것이 이 패키지의 계약이다. SwiftUI·UIKit·GRDB·앱 모델을
/// **모듈 경계로** 막는다 — 규칙을 주석으로 적는 대신 컴파일이 거부하게 한다.
/// (같은 방식을 쓰는 선례: `JustSendContentCore/Package.swift`)
let package = Package(
  name: "ios-ai-core",
  platforms: [.iOS("26.0"), .macOS("27.0")],
  products: [
    .library(name: "AgentKernel", targets: ["AgentKernel"]),
    .library(name: "AgentOrchestration", targets: ["AgentOrchestration"]),
  ],
  targets: [
    // 능력·행동·원장·승인·커넥터. 부작용이 지나가는 단 하나의 문이 여기 있다.
    //
    // 행동과 커넥터가 한 모듈인 이유: `ActionRequest`가 `ConnectorBindingID`를
    // 들고(`Actions/ActionTypes.swift`), 어댑터가 `ActionRequest`를 받는다
    // (`Connectors/ConnectorAdapter.swift`) — 서로를 가리키는 두 벌은 한 모듈이다.
    .target(
      name: "AgentKernel",
      // 앱과 같은 언어 모드. 옮긴 코드의 동시성 의미를 바꾸지 않는다
      // (`app/project.yml`의 SWIFT_VERSION 5.9).
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // 차례 한 번의 기계: 단계·범위·계획 스키마·검증·근거 축약·조립.
    // PCC를 부르는 자리는 프로토콜이고, 시험은 그 문으로 대역을 세운다.
    .target(
      name: "AgentOrchestration",
      dependencies: ["AgentKernel"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // **앱 없이 도는가.** 시뮬레이터에는 PCC도 기기 모델도 없으므로, 계획과 답의
    // 자리에는 대역을 세우고 툴은 가짜를 등록한다 — 증명하는 것은 모델의 품질이
    // 아니라 **조립**이다: 앞 단계의 산출이 다음 단계의 인자가 되는가, 값이
    // 모자랄 때 먼저 묻는가, 되돌릴 수 없는 실행 앞에서 멈추는가.
    .testTarget(
      name: "AgentOrchestrationTests",
      dependencies: ["AgentOrchestration"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // **커널만.** 부작용의 문·권한 표·주소 정책이 여기 있고, 그 셋은 오케스트레이션
    // 없이도 지켜져야 한다 — 웹 주소를 거르는 문은 차례가 없어도 문이다.
    .testTarget(
      name: "AgentKernelTests",
      dependencies: ["AgentKernel"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
