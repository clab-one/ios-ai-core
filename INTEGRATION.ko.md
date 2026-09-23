# 코어 붙이기

이 저장소는 앱이 아니라 **에이전트 실행 평면**이다. 화면도, 저장 스키마도, 공급자
SDK도 없다. 의존성은 `Foundation · OSLog · CryptoKit · Security · FoundationModels`
뿐이고, 그 목록이 비어 있는 것 자체가 계약이다 — SwiftUI·DB·앱 모델은 주석이
아니라 **모듈 경계가** 막는다.

흐름은 하나다:

```
사용자 문장
  → PCC 1회: 대화 답변 · 되물음 · 실행 계획 중 하나
  → 대화·되물음이면 같은 호출의 문장으로 닫는다(모델 1회, 도구 0)
  → 실행이면 코어: 순차 실행(앞 결과로 다음 인자 채움 · 빠진 읽기 보정 · 쓰기 앞 승인 · 원장 기록)
  → PCC 1회: 회수한 사실로 최종 답
  → 화면
```

실행 중에 PCC를 다시 부르지 않는다. 값이 모자라면 **첫 결정이 질문을 들고 오고**
그 답은 다음 차례가 된다. 등록된 툴이 0개인 호스트도 대화는 돈다 — 도구가 없는 것과
답할 수 없는 것은 다른 사실이다.

실측 비용(아이패드, 실제 PCC, 2026-09-17): 도구를 지난 차례는 **PCC 2회**, 입력
1,285–1,616 토큰(문자 2,415–3,087), 그중 한 호출 최대 650–959 토큰.
실측(iPhone Air, 실제 PCC, 2026-09-18): 일상 대화 한 차례는 **PCC 1회**, 입력 857
토큰(문자 1,809, 캐시 41), 완료 2,947ms. 같은 기기의 `memory.save` 차례는 PCC 2회,
입력 1,534 토큰(문자 3,551), 완료 5,255ms.

이 문서와 함께 쓰는 템플릿: `Examples/Host/`의 `project.yml` · `App.entitlements` ·
`AgentHostSetup.swift`. 세 파일은 실제 앱 타깃에서 컴파일을 확인한 판이다.

---

## 1. 가져가기

코어는 원격 의존성이 없으므로 해석이 빠르고, 포크해도 서브모듈이 따라오지 않는다.

```swift
// 포크·수정이 잦은 동안: 같은 워크스페이스에 두고 경로로
.package(path: "../ios-ai-core")

// 판을 고정해 가져오기(권장)
.package(url: "https://github.com/your-org/ios-ai-core", exact: "0.1.0")
```

xcodegen을 쓰면 `Examples/Host/project.yml`을 그대로 복사한다. Xcode 프로젝트를
손으로 들고 있으면 **네 자리만** 옮긴다: 배포 대상 `iOS 26.0`, `SWIFT_VERSION 5.9`,
`CODE_SIGN_ENTITLEMENTS`, 그리고 패키지 산출물 둘.

```
AgentKernel         능력 이름 · 계약 · 수령증 · 원장 · 승인 · 커넥터 · 웹 · 기기 모델 문
AgentOrchestration  차례 한 번의 기계: 단계 · 범위 · 계획 스키마 · 근거 축약 · 문맥 조립
```

**둘 다 넣는다.** Kernel만으로는 차례가 돌지 않고, Orchestration만으로는 능력·
계약·수령증 타입이 없다.

이 패키지는 **iOS 26+ · macOS 27+** 다(`platforms: [.iOS("26.0"), .macOS("27.0")]`).
macOS에서는 `swift build`·`swift test`가 선다. 다만 `swift test`는 층을 가르지 않는다 —
L1(기기 모델)·L3(살아 있는 웹)까지 돈다. 싼 층만 원하면 `--skip`으로 그 클래스를 뺀다
(`Scripts/test.sh`의 층 목록). iOS 검증은 `xcodebuild ... -destination`으로 한다(§11).

---

## 2. PCC가 전제다

오케스트레이터는 **PCC 하나**다. 기기 모델은 툴이 자기 일을 할 때 쓰는 자리이고
계획·답을 대신 쓰지 않는다 — 두 모델이 한 차례를 나눠 맡으면 답이 근거와 어긋나고
계측의 `backend` 칸이 거짓이 된다. 계획 자리는 권한이 없으면 **세션을 만들지
못하고 던진다**(`DynamicProfileAdapter.privateCloudSession`).

```swift
guard AgentRuntime.isSupported(for: AgentHostSetup.identity) else {
  // 이 기기·계정·서명으로는 에이전트를 열 수 없다. **기능이 없다고 말한다.**
  return showUnsupported()
}
```

전제 셋이 모두 참이어야 한다:

| 전제 | 확인 | 아니면 |
|---|---|---|
| iOS 27+ | `#available` | 미지원 |
| App ID에 `com.apple.developer.private-cloud-compute` | 개발자 포털 capability + `App.entitlements` | 서명이 통과해도 **실행 중 `fatalError`** |
| 기기에서 Apple Intelligence 사용 가능 | `PrivateCloudComputeAccess.isDeviceEligible()` | 미지원 |

진단 한 줄을 화면·로그에 띄우면 미지원의 이유가 갈린다:

```swift
"entitled=\(PrivateCloudComputeAccess.isEntitled) "
+ "supported=\(AgentRuntime.isSupported(for: identity)) "
+ "device=\(SystemLanguageModel.default.availability)"
```

실측 함정: iPad에서 `device=unavailable(modelNotReady)`였고 원인은 **기기 언어
설정**이었다. 시뮬레이터의 "Sign to Run Locally" 서명은 엔타이틀먼트를 싣지
않으므로(`codesign -d --entitlements` 결과가 빈 dict) PCC 경로는 실기에서만 검증된다.

---

## 3. 최소 연결

전체 배선은 `Examples/Host/AgentHostSetup.swift`에 있다. 요지만:

```swift
@main
struct MyApp: App {
  // 신원이 가장 먼저다. `boot` 뒤에 설정하면 첫 화면이 "지원하지 않음"을 거짓으로 그린다.
  init() { AgentHost.configure(AgentHostSetup.identity) }
  var body: some Scene { WindowGroup { RootView() } }
}

let runtime = await AgentRuntime.boot(
  AgentRuntimeConfiguration(
    host: AgentHostSetup.identity,
    tools: [MyCalendarTool(), MyMailTool()],
    memoryIndex: MyVectorIndex(),                 // 없으면 memory.* 미등록
    summaryModel: FoundationSummaryModel(),       // 없으면 text.summarize 미등록
    webSearch: .standard,                         // 없으면 web.search 미등록
    webRead: .standard,                           // 없으면 web.read 미등록
    copy: TurnCopy { key in myStrings[key] ?? key },
    turnRuns: MyTurnRunStore(),                   // 없으면 복구를 포기한다
    actionLedger: MyActionLedger(),               // 없으면 원격 쓰기를 실행하지 않는다
    currentAccountID: { myAccount.id },
    // 임시 문장(streaming preview) 정책과 수신자. 기본은 꺼짐이고, 정본은 onResult다.
    responseStreamingEnabled: { UIApplication.shared.applicationState == .active },
    onResponseSnapshot: { snapshot in myUI.preview(snapshot) },
    onEvent: { envelope in myUI.observe(envelope) },
    onResult: { result in myUI.present(result) }))
```

`AgentRuntime`이 호스트가 말을 거는 단 하나의 자리다: `submit` · `approve` ·
`reject` · `cancel` · `hasPendingTurn` · `lastReadSources(for:)` · `dispatcher`.

차례 하나:

```swift
await runtime.submit(
  TurnContextSnapshot(
    requestID: UUID(), accountID: account, conversationID: conversation,
    input: "이 페이지 요약해서 지민에게 보내줘", recentMessages: recentTurns,
    registeredCapabilities: await runtime.dispatcher.registeredCapabilities()))
```

지시 하나의 상한은 **2,000자**다. 넘으면 모델을 부르지 않고 거절한다
(`TurnCopy.Key.answerRequestTooLarge`) — 뒤를 자르면 `"이 내용을 수정하지 말고
보내줘"`에서 지시 자체가 사라진다.

---

## 4. 호스트가 채우는 자리

### 신원 — `AgentHostIdentity`

`bundleIdentifier` 하나에서 로그 서브시스템·Keychain 서비스(`<bundle>.connector`)·
기본값 접두사·근거 인용 스킴·OAuth 리다이렉트 스킴이 유도된다. **이미 출하된 앱은
처음 쓰던 값을 명시로 넘겨야 한다** — 이름이 바뀌면 저장된 토큰을 찾지 못한다.

### 툴 — `CapabilityHandler`

툴은 자기 계약을 들고 온다. 등록하면 코어가 계약도 함께 싣는다.

```swift
struct MyCalendarTool: CapabilityHandler {
  var capabilities: Set<CapabilityID> { [.calendarSearch, .calendarCreate] }

  var contracts: [CapabilityContract] {
    [
      CapabilityContract(.calendarSearch, optional: [
        .init("query"), .init("start", .timestamp), .init("end", .timestamp),
      ]),
      CapabilityContract(.calendarCreate,
        required: [.init("title"), .init("start", .timestamp)],
        optional: [.init("location"), .init("notes")]),
    ]
  }

  func perform(_ request: ActionRequest) async throws -> ActionReceipt {
    let rows = try await search(request.arguments)
    return ActionReceipt(
      requestID: request.id, capability: request.capability,
      summary: "일정 \(rows.count)건",
      details: CapabilitySourceRow.detail(rows),   // 모델이 읽는 자리
      sources: rows.map { … },                     // 되짚는 자리
      coverage: [ … ])                             // 덜 읽은 범위(§9)
  }
}
```

- **계약 없는 능력은 실행되지 않는다.** 손이 있어도 인자를 검사할 수 없으면 거절이다.
- 줄은 다섯 칸으로 고정이다: `title · subtitle · body · identifier · timestamp`.
  `body`에 담은 바깥 글이 기기 모델 축약의 재료가 된다.
- **쓸 글의 인자 이름은 `body`다.** `mail.send`·`chat.send`·`memory.save`가 모두 같은
  이름을 쓴다 — 공급자 낱말(`text`·`content`)로 옮기는 일은 어댑터의 몫이다. 이름이
  갈리면 앞 단계의 요약이 그 자리로 흐르지 못한다.
- 검색 결과처럼 **다음 단계로 가는 손잡이**를 돌려주는 능력은 그 사실을 계약에
  적는다:

  ```swift
  CapabilityContract(.webSearch, required: [.init("query")], rows: .handle)
  ```

  손잡이 줄은 근거가 되지 않는다(참조·회수 건수에는 남는다). 이 선언이 없으면
  공급자가 쓴 한 줄이 우리가 읽지도 않은 사실로 답에 올라간다.

### 기억 색인 — `SemanticMemoryIndex`

```swift
protocol SemanticMemoryIndex: Sendable {
  func search(_ query: String, limit: Int, cursor: String?) async throws -> [MemoryHit]
  func read(id: String) async throws -> MemoryDocument?
  func save(text: String, title: String?) async throws -> String
}
```

벡터 엔진은 호스트의 자산이고, **검색을 어떻게 쓰는가는 코어가 소유한다**
(`MemoryTool`: 기본 5건·상한 20건, 스니펫 240자, 정본 중복 접기, 근거 변환).
어휘로 끝낼지·임베딩을 만들지·둘을 합칠지는 이 구현이 정한다. 모델에게 보이는
검색 툴은 하나다. 같은 글은 같은 식별자를 돌려줘야 한다.

### 기기 모델 — `OnDeviceTextModel`

툴이 기기에서 요약·추출할 때 **이 문으로만** 지난다. 코어가 기본 구현을 싣는다
(`FoundationOnDeviceTextModel`). 툴이 `SystemLanguageModel`을 직접 부르면 발열
정책이 툴 수만큼 갈라지고, 그중 하나는 반드시 게이트 없이 돈다.

### 문구 — `TurnCopy`

판정은 코어가, 낱말과 언어는 호스트가. 채워야 하는 열쇠는 `TurnCopy.Key.all`이
알려 준다 — 그 집합과 자기 문구 파일을 대조하는 시험을 쓰면 빠짐이 화면에서
드러나기 전에 잡힌다. 표는 `Examples/Host/AgentHostSetup.swift`에 전부 있다.

### 복구·원장

| 자리 | 없으면 |
|---|---|
| `TurnRunStore` | 복구를 포기한다(`NoTurnRunStore`). 앱이 죽으면 그 차례는 사라진다 |
| `ActionLedger` | **원격 쓰기를 실행하지 않는다.** 기록 없이 보낸 전송은 다음 재시도에서 두 번째 전송이 된다 |

`ActionLedger`는 다섯 자리다: `replay` · `claim(_:at:)` · `settle` · `entry` ·
`deleteAll(accountID:)`. 메모리 판이 템플릿에 있고, **출하 앱은 그것을 쓰지 않는다**
— 앱이 죽으면 "보냈는지 모르는 전송"을 다시 보내게 된다.

### 웹 두 스위치

```swift
webSearch: WebSearchBroker?      // .standard = DuckDuckGo HTML → Lite 순서
webRead: WebReadConfiguration?   // .standard = 정책·2 MiB·15초
```

**둘을 나눠 둔 이유**: 붙여넣은 주소만 읽는 앱이 있고, 그 앱은 사용자 문장을 공개
웹으로 내보내지 않는다. 한 스위치로 묶으면 그 앱이 검색까지 켜야 한다.

조절할 것은 정책이다. 문(`ContentFetchTransport`)은 넘길 수 없다 — 주입된 문은
리다이렉트를 자기가 따라가고, 따라간 홉은 주소 표를 지나지 않는다.

```swift
webRead: WebReadConfiguration(
  policy: ContentFetchHostPolicy(),  // 사설·루프백·링크로컬·멀티캐스트·자격증명 차단
  byteLimit: 2 * 1024 * 1024,
  timeout: 15)
```

`web.fetch`는 이 자리가 **아니다.** 받은 것을 정본 기록으로 남기는 능력이므로
호스트의 저장소가 필요하다 — `web.read`는 지나가는 읽기이고 남는 것은 수령증뿐이다.

---

## 5. 앞 단계 산출이 다음 단계 인자가 된다

모델은 식별자를 모른다. 모르는 값을 요구받으면 **지어낸다.** 그래서 이 자리들은
모델이 아니라 **앞 단계의 수령증**에서 채운다(`ResolvableArgument`).

| 자리 | 어디서 오는가 |
|---|---|
| `to` | `people.resolve` · `contacts.read` 결과의 주소 |
| `messageID` · `threadID` · `messageIDHeader` | 메일 영역 수령증 |
| `channelID` · `threadTS` | 채팅 영역 수령증 |
| `itemID` | 기억·보관함·콘텐츠·녹음 수령증 |
| `eventID` · `reminderID` | 일정·미리 알림 수령증 |
| `url` | `web.search` 결과의 식별자 |
| `sourceText` | **앞 단계가 읽은 글** → 요약 툴의 입력 (손잡이 줄은 여기 못 들어온다) |
| `body` | **요약 툴의 산출** → 전송·저장의 본문 |

`web.read → text.summarize → mail.send`가 이 표로 성립한다. 원문은 PCC 문맥에
올라가지 않는다 — 기기 모델이 줄인 글만 다음 단계로 간다.

### 런타임이 계획을 낮춘다 (호스트가 알아야 하는 정상 동작)

PCC는 **뜻**을 계획하고, 그 뜻을 실행 가능한 순서로 만드는 일은 런타임이 한다.
실기에서 PCC가 낸 계획은 읽기를 빼놓는다:

```
PCC 계획:   web.search → text.summarize → memory.save
실제 실행:  web.search → web.read → text.summarize → memory.save
                         ^^^^^^^^ 런타임이 끼운 단계
```

그 사실은 계측에 이름으로 남는다: `interventionReason = "dependency:web.read"`.
같은 자리가 `memory.search → memory.read`도 메운다. **실패가 아니라 정상 경로다.**

어느 줄을 읽을지는 **기기**가 고른다(`SearchCandidateSelector`): 사용자 문장과 그
차례가 기기에서 이미 읽은 사적 맥락으로 후보를 세우고, 점수가 갈리지 않으면 기기
모델이 다섯 중 하나를 고르거나 **"고를 것이 없다"**고 답한다. 그때는 읽지 않고
`interventionReason = "search:no-relevant-candidate"`가 남는다 — 사용자가 묻지 않은
페이지를 "최신 웹 내용"으로 말하는 것보다 웹에서 찾지 못했다고 말하는 것이 맞다.

사적 맥락은 **점수 계산에만** 쓰인다. 공개 웹으로 나가는 것은 질의뿐이다.

---

## 6. 부작용의 경계

모든 실행이 `ActionDispatcher` 한 문을 지난다. 순서가 계약이다:

```
계약 검사 → 계정/epoch → 멱등·replay → 손 → 승인 → 원장
```

- **승인**: 되돌릴 수 없는 실행은 자격(`AuthorizationProof`) 없이는 사람의 허락을
  지난다. 호스트는 `onEvent`의 `.awaitingApproval`을 받아 문을 세우고,
  `dispatcher.approve(id)` 결과를 `runtime.approve(_:outcome:)`에 넘긴다. 차례는
  **남은 단계부터** 이어 간다.
- **멱등**: 열쇠는 능력 이름 + 정규화된 인자 지문이다. 같은 글을 두 번 저장하면
  두 번째는 실행되지 않고 첫 수령증을 돌려받는다.
- **완료는 수령증에서만 나온다**: 계획이 약속한 쓰기에 수령증이 없으면 코어가 그
  차례를 완료로 닫지 않는다(`partial`). 모델이 "보냈습니다"라고 써도 화면의 단계는
  바뀌지 않는다.

> **알려진 제약**: 되돌릴 수 없음·원격 쓰기·실행 분류는 코어가 아는 능력 이름
> 표(`CapabilityID.executionClass`)로 판정한다. 표에 없는 새 이름은 `.interactive`로
> 떨어져 **승인·원장 보호를 받지 못하고** 병렬 읽기에도 들지 못한다. 쓰기 툴은 코어가
> 분류하는 이름을 쓰거나, 그 표에 이름을 추가해야 한다.

---

## 7. 무엇이 기기를 떠나는가

| 나가는 것 | 어디로 |
|---|---|
| 사용자 문장(2,000자 상한) | PCC |
| 능력 **이름** 목록 | PCC |
| 기기 모델이 뽑은 사실 몇 줄(조각당 240자, 8조각) | PCC |
| 검색 질의 | 검색 공급자 |
| `web.read`의 주소 | 그 사이트 |

**나가지 않는 것**: 페이지 전문, 메일·메시지 원문, 기록 본문, 검색 결과 스니펫,
사적 맥락. 이 경계는 주석이 아니라 타입과 시험이 지킨다 — 수령증의 세부 값은
계약에 선언된 열쇠만 문맥에 오르고(불투명 손잡이는 제외), 손잡이 줄은 근거 후보에서
빠지고, L0 시험이 원문 표식으로 그 사실을 고정한다.

주소 심사(`ContentFetchHostPolicy`)가 막는 것: `http`/`https` 밖 스킴, URL에 박힌
자격증명, 루프백·링크로컬·사설·CGNAT·멀티캐스트(IPv4·IPv6·NAT64·IPv4-mapped),
`localhost`/`.local`/`.internal`, 네 마디로 읽히지 않는 숫자 주소, 그리고
**리다이렉트의 매 홉**. 막지 못하는 것: 공개 이름이 사설 주소로 해석되는 경우
(DNS 해석·rebinding) — 그 한계는 코드 주석에 적혀 있다.

---

## 8. 비용

PCC 비용은 **호출 수 × 입력 크기**다. 그래서 코어는 다음을 지킨다.

| 자리 | 크기 |
|---|---|
| 공통 지시 | ~400자 (모든 호출) |
| 계획 지시 | ~300자 |
| 답 지시 | ~900자 |
| 툴 목록 | 이름만. 차례에 필요한 것만 보여 준다(실측: 좁힌 범위 158자 대 전부 651자) |
| 최근 대화 | 완전한 turn 단위로 최대 12줄, JSON 인코딩 후 2,400자 |
| 덜 읽은 곳(coverage) | 300자 상한, 미완료 항목만 |
| 근거 | 8조각, 조각당 240자 상한 |
| 계획 스키마 | **346토큰**(실측, 기기 토크나이저) — 문맥 글자 수에는 세어지지 않는다 |

글자와 토큰의 환산비도 실측이 있다: 한국어 산문 1.92자/토큰, 영문 5.27자/토큰.
**같은 글자 예산이 한국어에서 2.7배 비싸다.**

**지시에 규칙을 더하지 않는다.** 제약은 코드에 둔다 — 계약이 인자를 검사하고,
지문이 중복을 막고, 승인이 쓰기를 막고, 수령증이 완료를 정한다. 프롬프트로 옮긴
규칙은 매 호출에 돈을 내면서도 지켜질지 모른다(실측: 모델은 `<<<completed>>>`를
받고도 없던 전송을 말했다 — 그 거짓을 막은 것은 문단이 아니라 구조 검사였다).

---

## 9. 계측 — 호스트가 화면·지표에 쓸 값

`ConversationTurnResult.telemetry`에 한 차례의 비용과 판정이 있다.

```
pcc=2/2                              물리 호출 / 그중 사용량을 받은 호출
tokens=1294/650  cached=82           총 입력 / 한 호출 최대 / 캐시된 입력
chars=2573/1616                      같은 값의 글자 판
materials=1 rows=6 local=1/0         근거 조각 / 회수한 줄 / 기기 추출·기기 선택
iterations=1                         감독자에게 물은 횟수
```

**재지 못한 값은 nil이다.** `inputTokens`·`maximumInputTokens`·`cachedInputTokens`는
`Int?`이고, 나간 호출 **전부**를 재지 못하면 nil이 된다 — 부분 합을 총량으로 적으면
재시도가 많은 차례가 실제보다 작게 잡히고, 그 값으로 뽑은 p50/p95는 근거가 되지
못한다. 부분 값이 필요하면 `measuredInputTokens`를 본다. 화면에 0을 찍지 말고
`?`를 찍는다.

사유는 **세 칸으로 갈라져 있다.** 한 칸이던 동안 보정 표시가 실패 사유를 지웠다:

| 필드 | 질문 | 값 예시 |
|---|---|---|
| `interventionReason` | 왜 이 실행 경로를 탔나(정상) | `dependency:web.read` · `dependency:memory.read` · `search:no-relevant-candidate` |
| `completionReason` | 왜 완료가 아닌가 | `coverage:web.read:truncation` · `coverage:web.read:providerFailure` · `unkept:mail.send` · `deadline` · `answer:unavailable` · `requestTooLarge` |
| `fallbackReason` | 모델·백엔드가 대역으로 내려섰나 | (보통 빈 값) |

`completionReason`은 차례 끝에 **관측된 사실에서 계산한다**(종료 사실 + 원장의 범위 +
못 지킨 쓰기 + 답 부재). 그래서 `phase=partial`이면 그 줄이 이유를 말한다.

호스트가 이 세 값을 **한 칸으로 접지 않는 것**이 중요하다. 바깥의 사정(사이트가
거절했다)과 우리 결함(파서가 깨졌다)이 같은 글자로 보이면 지표가 쓸모없어진다.

---

## 10. 검증

코어는 비용 층으로 갈라져 있다. **기본은 가장 싼 층이다.**

```
./Scripts/test.sh          L0   70 tests · PCC 0 · 기기 모델 0 · 네트워크 0
./Scripts/test.sh local    L1   기기 모델만
./Scripts/test.sh pcc      L2   (이 저장소에서는 비어 있다 — 아래)
./Scripts/test.sh e2e      L3   살아 있는 웹 3 tests
```

L0의 `golden 8`은 계획·답 자리만 대역이고 resolver·계약·근거 압축·문맥 조립은 전부
제품 코드다. 각 시나리오가 **문맥 글자 수 기준선**을 들고 있어 +10%에 경고, +20%에
실패한다 — 기능이 성공했는데 문맥이 두 배가 된 커밋은 회귀다.

**L2(실제 PCC)는 이 저장소에서 돌 수 없다.** SwiftPM의 iOS 시험 번들은 일반 XCTest
호스트에서 돌고 그 앱에는 엔타이틀먼트를 넣을 자리가 없다. 그래서 그 층은
**엔타이틀먼트를 든 호스트 앱이 소유한다**(`Examples/Host/project.yml`의 시험 타깃).
참고 구현: `ios-ai-core-test`의 `ScenarioRunner` — 시나리오를 차례로 돌리고 계약
위반만 적으며, 답의 낱말은 검사하지 않는다(**어느 툴이 돌았는가, 되돌릴 수 없는
실행 앞에서 멈췄는가, 모자란 값을 먼저 물었는가**).

실기 실행은 화면을 두드리지 않는다. 환경변수로 켜고 콘솔로 읽는다:

```bash
xcrun devicectl device install app --device <UDID> <App.app>
xcrun devicectl device process launch --device <UDID> --console \
  --environment-variables '{"CORETEST_AUTORUN":"1","CORETEST_SUITE":"baseline"}' \
  com.example.myagentapp
```

기기의 `os_log`는 **Mac으로 중계되지 않는다**(실측: `idevicesyslog`는 앱의 info
단계를 싣지 않는다). 그래서 실기 증거가 필요한 값은 호스트가 `print`로 찍어야 한다 —
수령증의 줄·글자 수·coverage가 그 대상이다.

---

## 11. 깨지는 API (옛 판에서 올라올 때)

| 옛 | 지금 |
|---|---|
| `TurnTelemetry.estimatedInputCharacters` | 제거. `inputCharacters` / `maximumInputCharacters` |
| `TurnTelemetry.inputTokens: Int` | `Int?` (`maximumInputTokens`·`cachedInputTokens`도) |
| `TurnTelemetry.fallbackReason`에 섞여 있던 보정·실패 | `interventionReason` / `completionReason` / `fallbackReason` |
| `SupervisorStep`·`FinalizationStep`의 `receipt:` | `trail: ModelInvocationTrail(outcome:)` |
| `mail.send`의 `body`, `chat.send`·`memory.save`의 `text` | 전부 `body` |
| `WebSearchEngine.search(query:limit:)` | `search(query:limit:window:)` |
| `webRead: ContentFetchTransport?` | `webRead: WebReadConfiguration?` |
| `Info.plist`의 `JSWebSearchEndpoint`·`JSWebSearchAPIKey` | 제거. 검색은 열쇠가 없다 |
| — | 새 문구 열쇠 `conversation.answer.requestTooLarge` |

---

## 12. 알려진 한계 (실측)

포크 전에 알고 있어야 하는 것들. 이 목록은 추측이 아니라 실기 로그에서 왔다.

| 한계 | 측정 |
|---|---|
| **웹 질문의 답 품질** | 질의가 모호하면(`PCC`) 후보 다섯 줄에 찾는 페이지가 아예 없다. 사적 맥락으로 질의를 늘리는 것은 경계 위반이므로 지금은 **읽지 않기로** 막는다 |
| **기기 모델이 보는 앞 4,000자** | 답이 그 뒤에 있으면 못 본다(실측 `firstRelevant=4,763`). 한국어 질의 대 영문 페이지는 겹침이 0이어서 구간 선택으로도 못 고른다 |
| **장식이 지배하는 페이지** | 한 기사 `markdown=57,001자` 중 산문 7,207자 → 40,000자 상한에 걸려 차례가 `partial`. 본문 추출을 시도했고 다른 페이지의 기사를 잃어 **되돌렸다**(근거는 `WebReadTool.characterLimit` 주석) |
| **공급자 거절** | 사이트가 읽기를 거절한다(`web.read.rejected`). 후보 2회까지 재시도하고 그 뒤에는 `partial`로 적는다 |
| **검색 공급자 스로틀** | 한 IP에서 요청이 몰리면 DuckDuckGo가 20분 이상 202를 준다. **속도 제한·백오프·캐시 정책이 코어에 없다** — 호스트가 얹어야 한다 |
| **커넥터** | 일정·미리 알림·메일·연락처의 실제 구현은 호스트의 몫이다. 코어에 있는 것은 이름·계약·경계다 |

---

## 13. 실기에서 배운 함정

| 함정 | 증상 | 막는 법 |
|---|---|---|
| 신원을 `boot` 뒤에 설정 | 첫 화면이 "지원하지 않음"을 거짓으로 그린다 | `AgentHost.configure`를 앱 `init`에서 |
| 엔타이틀먼트와 `privateCloudComputeEntitled`가 갈림 | 실행 중 `fatalError` | 두 자리를 대조하는 시험 |
| 새 능력에 실행 분류 없음 | 모든 해당 차례가 `partial`로 닫힌다 | `executionClass`에 이름 추가 |
| 손잡이 능력에 `rows: .handle` 없음 | 공급자 스니펫이 답의 근거가 된다 | 계약에 선언 |
| 쓸 글의 인자를 `text`로 | 앞 단계의 요약이 흐르지 않고 되물음으로 끝난다 | `body` |
| 기기 언어·지역 | `pccAvailable=false` | Apple Intelligence 사용 가능 언어로 |
| 시뮬레이터 서명 | 엔타이틀먼트가 비어 PCC가 죽는다 | 실기 + 프로비저닝 프로파일 |
| 문구 열쇠 누락 | "값이 하나 더 필요해요"가 화면에 선다 | `TurnCopy.Key.all` 대조 시험 |
| 계측 세 사유를 한 칸으로 접기 | 바깥 사정과 우리 결함이 같은 글자로 보인다 | 세 필드를 따로 찍는다 |
