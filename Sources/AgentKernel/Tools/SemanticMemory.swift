import Foundation

/// 색인이 고른 한 줄. **정본이 아니다** — 되짚을 식별자와 찾은 글만 든다.
public struct MemoryHit: Sendable, Equatable {
  /// 정본의 식별자. 다음 단계(`memory.read`)의 인자가 이 값이다.
  public let id: String
  public let title: String
  /// 찾은 자리의 글. 코어가 상한으로 자른다(`MemoryTool.snippetLimit`).
  public let snippet: String
  /// 색인이 매긴 점수. 순서를 정하는 데만 쓴다 — 화면에도, 모델에도 가지 않는다.
  public let score: Double
  public let createdAt: Date

  public init(
    id: String, title: String, snippet: String = "", score: Double = 0,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.snippet = snippet
    self.score = score
    self.createdAt = createdAt
  }
}

/// 기록 하나의 본문.
public struct MemoryDocument: Sendable, Equatable {
  public let id: String
  public let title: String
  public let body: String
  public let createdAt: Date

  public init(id: String, title: String, body: String, createdAt: Date = Date()) {
    self.id = id
    self.title = title
    self.body = body
    self.createdAt = createdAt
  }
}

/// 임베딩 기억의 **색인**. 호스트가 자기 엔진으로 구현한다.
///
/// 코어가 이 자리를 구현하지 않는 이유는 하나다: 벡터 엔진과 임베딩 모델은
/// 바이너리 자산이고, 이 저장소의 계약은 **의존성이 비어 있는 것**이다. 대신
/// 코어는 검색을 *어떻게 쓰는가*를 소유한다 — 상한, 스니펫 길이, 중복 제거,
/// 결과를 근거로 옮기는 모양(`MemoryTool`).
///
/// **어휘로 끝낼지, 임베딩을 만들지, 둘을 합칠지는 이 구현이 정한다.** 모델에게
/// 보이는 검색 툴은 하나뿐이고(`memory.search`), 색인이 넉넉해져도 그 툴은 그대로다.
public protocol SemanticMemoryIndex: Sendable {
  /// 질의 하나로 고른 줄들. 순서는 구현이 정한 관련도 순서다.
  ///
  /// **`accountID`는 필수다, 기본값이 없다.** 이 값이 없어서 전체 계정을 훑던
  /// 시절에는 계정 B의 검색이 계정 A가 저장한 첨부·웹 읽기·기억을 그대로
  /// 찾아냈다(코드 리뷰 2026-09-18: `memory_documents`에 계정 칸이 없었다). 대화
  /// 단위 격리는 두지 않는다 — `memory.save`("여권 만료, 기억해")는 대화를
  /// 넘어 계정 전체에서 찾아져야 하는 사실이다.
  func search(_ query: String, accountID: String, limit: Int, cursor: String?) async throws
    -> [MemoryHit]
  /// 정본 하나의 본문. 없거나 **다른 계정의 것이면** nil이다 — 지어내지 않는다.
  func read(id: String, accountID: String) async throws -> MemoryDocument?
  /// 말로만 준 사실을 기록으로 만든다. 같은 글이 두 번 오면 **같은 식별자**를
  /// 돌려주어야 한다(코어도 멱등 열쇠로 막지만, 색인이 정본의 주인이다).
  ///
  /// `conversationID`는 출처 기록일 뿐 검색 범위가 아니다 — 이 값으로 걸러
  /// 저장한 대화 밖에서 못 찾게 만들면 `memory.save`의 존재 이유(대화를 넘는
  /// 회상)가 사라진다.
  func save(text: String, title: String?, accountID: String, conversationID: String?)
    async throws -> String
}

/// 기억을 읽고 쓰는 툴.
///
/// PCC가 회상이 필요하다고 판단하면 이 툴을 부른다. 어느 문장이 회상인지
/// 규칙으로 가르지 않는다 — 그 판단이 모델의 일이다.
///
/// **자동으로 쌓이는 것은 저장하지 않는다.** 웹 페이지·파일·OCR·사진은 정본
/// 캡처가 기록으로 만들고 색인이 따라잡는다. 그래서 `memory.save`의 역할은 하나로
/// 좁다: **자동 수집이 닿지 못하는 순수 문장**("여권 만료 2027년 3월, 기억해").
public struct MemoryTool: CapabilityHandler {
  /// 한 번에 돌려주는 줄 수의 기본값과 상한.
  ///
  /// 상한이 필요한 이유는 비용이다. 모델이 `limit: 100`을 요구하면 그 100줄이
  /// 축약을 거쳐 PCC 문맥으로 올라간다 — 상한은 문맥이 조용히 커지는 길을 막는다.
  public static let defaultLimit = 5
  public static let maximumLimit = 20
  /// 한 줄이 싣는 글의 상한. 본문 전체는 `memory.read`가 가져온다.
  public static let snippetLimit = 240

  private let index: any SemanticMemoryIndex

  public init(index: any SemanticMemoryIndex) {
    self.index = index
  }

  public var capabilities: Set<CapabilityID> {
    [.memorySearch, .memoryRead, .memorySave]
  }

  public var contracts: [CapabilityContract] {
    [
      CapabilityContract(
        .memorySearch, required: [CapabilityContract.Argument("query")],
        optional: [
          CapabilityContract.Argument("limit", .number),
          CapabilityContract.Argument("cursor"),
        ]),
      CapabilityContract(.memoryRead, required: [CapabilityContract.Argument("itemID")]),
      // 저장할 글의 자리는 **메일·채팅과 같은 낱말**이다(`body`). `"찾아서 메모로
      // 저장해줘"`의 글은 계획 시점에 없다 — 읽고 줄인 뒤에 생기고, 그 값이 이
      // 자리로 흐르는 길이 `ResolvableArgument.body`다.
      CapabilityContract(
        .memorySave, required: [CapabilityContract.Argument("body")],
        optional: [CapabilityContract.Argument("title")]),
    ]
  }

  public func perform(_ request: ActionRequest) async throws -> ActionReceipt {
    switch request.capability {
    case .memorySearch:
      return try await search(request)
    case .memoryRead:
      return try await read(request)
    case .memorySave:
      return try await save(request)
    default:
      throw ActionError.unsupported(request.capability)
    }
  }

  private func search(_ request: ActionRequest) async throws -> ActionReceipt {
    guard let query = request.arguments["query"]?.textValue, !query.isEmpty else {
      throw ActionError.invalidArguments(reason: "query")
    }
    let requested = request.arguments["limit"]?.numberValue.map { Int($0) } ?? Self.defaultLimit
    let limit = max(1, min(requested, Self.maximumLimit))
    let hits = try await index.search(
      query, accountID: request.accountID, limit: limit,
      cursor: request.arguments["cursor"]?.textValue)

    // 같은 정본이 여러 조각으로 색인되어 있으면 한 줄로 접는다 — 같은 기록이
    // 세 줄로 서면 모델은 그것을 세 건의 사실로 읽는다.
    var seen: Set<String> = []
    var rows: [CapabilitySourceRow] = []
    var sources: [SourceReference] = []
    for hit in hits where !hit.id.isEmpty && seen.insert(hit.id).inserted {
      rows.append(
        CapabilitySourceRow(
          title: hit.title,
          subtitle: "",
          body: String(hit.snippet.prefix(Self.snippetLimit)),
          identifier: hit.id,
          timestamp: hit.timestamp))
      sources.append(
        SourceReference(
          accountID: request.accountID,
          binding: .accountLocal(accountID: request.accountID, domain: "memory"),
          kind: .memory, id: hit.id, timestamp: hit.createdAt))
    }

    return ActionReceipt(
      requestID: request.id,
      capability: request.capability,
      summary: "기록 \(rows.count)건",
      details: CapabilitySourceRow.detail(rows),
      sources: sources,
      coverage: [
        CoverageRecord(
          binding: .accountLocal(accountID: request.accountID, domain: "memory"),
          capability: request.capability,
          queryFingerprint: ActionFingerprint.arguments(["query": .text(query)]),
          state: .complete,
          discoveredCount: rows.count, readCount: rows.count,
          // 상한까지 찼으면 더 있을 수 있다. 그 사실을 감독자가 본다.
          paginationExhausted: rows.count < limit)
      ])
  }

  private func read(_ request: ActionRequest) async throws -> ActionReceipt {
    guard let id = request.arguments["itemID"]?.textValue, !id.isEmpty else {
      throw ActionError.invalidArguments(reason: "itemID")
    }
    guard let document = try await index.read(id: id, accountID: request.accountID) else {
      // 없는 기록을 "빈 기록"으로 돌려주지 않는다. 빈 본문은 모델에게 "내용이
      // 없는 기록"으로 읽히고, 그 차례는 사실이 아닌 답을 쓴다.
      throw ActionError.failed(reason: "notFound")
    }
    let row = CapabilitySourceRow(
      title: document.title, subtitle: "", body: document.body, identifier: document.id,
      timestamp: "")
    return ActionReceipt(
      requestID: request.id,
      capability: request.capability,
      externalID: document.id,
      summary: document.title.isEmpty ? "기록" : document.title,
      details: CapabilitySourceRow.detail([row]),
      sources: [
        SourceReference(
          accountID: request.accountID,
          binding: .accountLocal(accountID: request.accountID, domain: "memory"),
          kind: .memory, id: document.id, timestamp: document.createdAt)
      ])
  }

  /// 말로만 준 사실을 기록으로.
  ///
  /// **중복은 멱등 열쇠가 막는다.** 열쇠는 능력 이름과 정규화된 인자의 지문이므로
  /// (`ActionFingerprint.call`), 같은 글을 두 번 저장하면 두 번째 호출은 실행되지
  /// 않고 첫 수령증을 돌려받는다 — 조회 요청에 모델이 저장을 덧붙여도 기록은
  /// 하나다.
  private func save(_ request: ActionRequest) async throws -> ActionReceipt {
    guard let body = request.arguments["body"]?.textValue, !body.isEmpty else {
      throw ActionError.invalidArguments(reason: "body")
    }
    let id = try await index.save(
      text: body, title: request.arguments["title"]?.textValue,
      accountID: request.accountID, conversationID: request.conversationID)
    return ActionReceipt(
      requestID: request.id,
      capability: request.capability,
      externalID: id,
      summary: "기록했어요",
      details: ["itemID": .text(id)],
      sources: [
        SourceReference(
          accountID: request.accountID,
          binding: .accountLocal(accountID: request.accountID, domain: "memory"),
          kind: .memory, id: id)
      ])
  }
}

extension MemoryHit {
  /// 사람이 읽을 시각 문자열. 없으면 빈 값이다 — 시각을 지어내지 않는다.
  fileprivate var timestamp: String {
    createdAt.formatted(date: .abbreviated, time: .shortened)
  }
}
