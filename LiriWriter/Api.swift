// Api.swift — 跟 LiriChat 服務的 /v1/novels… 說話(2026-11-10)
import Foundation

struct NovelSummary: Decodable, Identifiable, Hashable {
    let id: Int64
    let title: String
    let theme: String
    let status: String
    let chaptersDone: Int
    let targetChapters: Int
    let running: Bool
    let updatedAt: Int64
}

struct NovelCharacter: Codable, Identifiable, Hashable {
    var id: Int64
    var name: String
    var role: String
    var profile: String
    var look: String
    var personality: String
    var voice: String
    var background: String
    var goal: String
    var relations: String
    var state: String
    var desire: String = ""
    var source: String
    var firstChapter: Int

    static func blank() -> NovelCharacter {
        NovelCharacter(id: 0, name: "", role: "配角", profile: "", look: "", personality: "", voice: "",
                       background: "", goal: "", relations: "", state: "", desire: "", source: "manual", firstChapter: 0)
    }
}

struct NovelChapter: Decodable, Identifiable, Hashable {
    var id: Int { idx }
    let idx: Int
    let title: String
    let plan: String
    let content: String
    let summary: String
    let segDone: Int
    let segTotal: Int
    let lookups: String
    let status: String
    let chars: Int
    var hasOriginal: Bool = false
    var rewriteNote: String = ""
    var technique: String = ""
}

struct NovelJob: Decodable, Hashable {
    let phase: String
    let chapter: Int
    let seg: Int
    let segTotal: Int
    let live: String
    let lookups: [String]
    let all: Bool
}

struct KnowledgeItem: Decodable, Identifiable, Hashable {
    let id: Int64
    let topic: String
    let text: String
    let source: String
    let chapter: Int
    let createdAt: Int64
    var shared: Bool = false
    var from: String = ""

    enum CodingKeys: String, CodingKey { case id, topic, text, source, chapter, createdAt, shared, from }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id); topic = try c.decode(String.self, forKey: .topic)
        text = try c.decode(String.self, forKey: .text); source = try c.decode(String.self, forKey: .source)
        chapter = try c.decode(Int.self, forKey: .chapter); createdAt = try c.decode(Int64.self, forKey: .createdAt)
        shared = (try? c.decode(Bool.self, forKey: .shared)) ?? false
        from = (try? c.decode(String.self, forKey: .from)) ?? ""
    }
}

struct NovelDetail: Decodable, Identifiable {
    let id: Int64
    var title: String
    let theme: String
    var style: String
    var world: String
    var outline: String
    let recap: String
    var nextNote: String
    var targetChapters: Int
    var chapterWords: Int
    var auto: Bool
    var adult: Bool
    var research: Bool
    var researchHint: String = ""
    var povName: String = ""
    var pov: String = ""
    var avoidOthers: Bool = true
    var shareKb: Bool? = nil   // 舊服務端沒有這個鍵
    var randomize: Bool = true
    var variation: String = ""
    let status: String
    let error: String
    let characters: [NovelCharacter]
    let chapters: [NovelChapter]
    let job: NovelJob?
    let memoryCount: Int
    let knowledge: [KnowledgeItem]
    var analysis: String = ""
    var analysisAt: Int64 = 0
    var worldBible: String = ""
    var worldBibleAt: Int64 = 0
    var spine: String = ""
    var ledger: String = ""
    var rules: String = ""
    var maps: String = ""

    var isBusy: Bool { status == "planning" || status == "writing" || job != nil }
    var chaptersDone: Int { chapters.filter { $0.status == "done" }.count }
}

struct SearchHit: Decodable, Identifiable, Hashable {
    let id = UUID()
    let kind: String
    let chapter: Int
    let text: String
    let score: Double
    enum CodingKeys: String, CodingKey { case kind, chapter, text, score }
}

struct ApiError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class Api: @unchecked Sendable {
    var baseURL: URL
    var apiKey: String

    init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil,
                         query: [URLQueryItem] = []) async throws -> Data {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        comps.path = path
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Liri-Key") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, code) = try await send(req)
        if code >= 400 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw ApiError(message: msg ?? "伺服器回 \(code)")
        }
        return data
    }

    /// 近地連結(2026-11-16):Tailscale / Wi-Fi 連不上時,改走 Mac 上 Chat App 的近地連結(藍牙找、Wi-Fi 直連),
    /// 同一組 HTTP 請求原封不動送過去。走近地之後每 30 秒試一次網路,通了就換回來。
    var nearEnabled = false
    private(set) var viaNear = false
    private var lastNetTry = Date.distantPast

    private func send(_ req: URLRequest) async throws -> (Data, Int) {
        #if os(iOS)
        if nearEnabled, viaNear {
            if Date().timeIntervalSince(lastNetTry) > 30 {
                lastNetTry = Date()
                var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!; c.path = "/health"; c.queryItems = nil
                var probe = URLRequest(url: c.url!); probe.timeoutInterval = 3
                if let (_, r) = try? await session.data(for: probe), (r as? HTTPURLResponse)?.statusCode == 200 { viaNear = false }
            }
            if viaNear, await NearLinkClient.shared.isReady { return try await NearLinkClient.shared.fetch(req) }
        }
        #endif
        do {
            let (data, resp) = try await session.data(for: req)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let e as URLError {
            #if os(iOS)
            if nearEnabled, e.code != .cancelled, await NearLinkClient.shared.waitUntilReady(timeout: 5) {
                let r = try await NearLinkClient.shared.fetch(req)
                viaNear = true; lastNetTry = Date()
                return r
            }
            #endif
            throw e
        }
    }

    private func decode<T: Decodable>(_ t: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }

    func health() async -> Bool {
        (try? await request("GET", "/health")) != nil
    }

    func list() async throws -> [NovelSummary] {
        try decode([NovelSummary].self, await request("GET", "/v1/novels"))
    }

    func detail(_ id: Int64) async throws -> NovelDetail {
        try decode(NovelDetail.self, await request("GET", "/v1/novels/\(id)"))
    }
    /// 原始回應:畫面輪詢時用來判斷「跟上次一模一樣就不要刷新」
    func detailData(_ id: Int64) async throws -> (NovelDetail, Data) {
        let data = try await request("GET", "/v1/novels/\(id)")
        return (try decode(NovelDetail.self, data), data)
    }

    func create(theme: String, style: String, chapters: Int, words: Int, auto: Bool, adult: Bool, research: Bool,
                researchHint: String, povName: String = "", pov: String = "", avoidOthers: Bool = true, randomize: Bool = true, castFrom: Int64? = nil) async throws -> NovelDetail {
        try decode(NovelDetail.self, await request("POST", "/v1/novels", body: [
            "theme": theme, "style": style, "chapters": chapters, "words": words, "auto": auto,
            "adult": adult, "research": research, "researchHint": researchHint,
            "povName": povName, "pov": pov, "avoidOthers": avoidOthers, "randomize": randomize, "castFrom": castFrom ?? 0]))
    }

    /// 匯入現有小說:服務端切章、摘要、整理設定(背景跑,進度看作品頁)
    func importNovel(text: String, title: String, direction: String, povName: String, pov: String, more: Int,
                     words: Int, auto: Bool, adult: Bool, research: Bool) async throws -> NovelDetail {
        try decode(NovelDetail.self, await request("POST", "/v1/novels/import", body: [
            "text": text, "title": title, "direction": direction, "povName": povName, "pov": pov, "more": more,
            "words": words, "auto": auto, "adult": adult, "research": research]))
    }

    /// 分析報告 / 世界觀設定集(服務端背景跑)
    func analyze(_ id: Int64, focus: String) async throws {
        _ = try await request("POST", "/v1/novels/\(id)/analyze", body: ["focus": focus])
    }
    func worldbuild(_ id: Int64, focus: String) async throws {
        _ = try await request("POST", "/v1/novels/\(id)/worldbuild", body: ["focus": focus])
    }
    /// 重寫第 from 章到第 to 章(第一次重寫會留原稿)
    func rewrite(_ id: Int64, from: Int, to: Int, instruction: String) async throws {
        _ = try await request("POST", "/v1/novels/\(id)/chapters/\(from)/rewrite", body: ["to": to, "instruction": instruction])
    }
    func revert(_ id: Int64, chapter: Int) async throws {
        _ = try await request("POST", "/v1/novels/\(id)/chapters/\(chapter)/revert", body: [:])
    }

    /// 上網查一件事(服務端背景跑:搜尋 → 讀網頁 → 整理成筆記存進知識庫)
    func research(_ id: Int64, query: String) async throws {
        _ = try await request("POST", "/v1/novels/\(id)/knowledge", body: ["query": query])
    }
    /// 手動加一筆資料(不用模型)
    func addKnowledge(_ id: Int64, topic: String, text: String) async throws {
        _ = try await request("POST", "/v1/novels/\(id)/knowledge", body: ["topic": topic, "text": text])
    }
    func deleteKnowledge(_ id: Int64, _ kid: Int64) async throws {
        _ = try await request("DELETE", "/v1/novels/\(id)/knowledge/\(kid)")
    }

    func patch(_ id: Int64, _ fields: [String: Any]) async throws -> NovelDetail {
        try decode(NovelDetail.self, await request("PATCH", "/v1/novels/\(id)", body: fields))
    }

    func delete(_ id: Int64) async throws { _ = try await request("DELETE", "/v1/novels/\(id)") }
    func write(_ id: Int64, all: Bool, note: String?) async throws {
        var b: [String: Any] = ["all": all]
        if let note { b["note"] = note }
        _ = try await request("POST", "/v1/novels/\(id)/write", body: b)
    }
    func stop(_ id: Int64) async throws { _ = try await request("POST", "/v1/novels/\(id)/stop", body: [:]) }
    func replan(_ id: Int64) async throws { _ = try await request("POST", "/v1/novels/\(id)/replan", body: [:]) }
    func deleteLastChapter(_ id: Int64) async throws { _ = try await request("DELETE", "/v1/novels/\(id)/chapters/last") }

    func saveCharacter(_ novelId: Int64, _ c: NovelCharacter) async throws {
        let b: [String: Any] = ["name": c.name, "role": c.role, "profile": c.profile, "look": c.look,
                                "personality": c.personality, "voice": c.voice, "background": c.background,
                                "goal": c.goal, "relations": c.relations, "state": c.state, "desire": c.desire]
        if c.id == 0 { _ = try await request("POST", "/v1/novels/\(novelId)/characters", body: b) }
        else { _ = try await request("PUT", "/v1/novels/\(novelId)/characters/\(c.id)", body: b) }
    }
    func deleteCharacter(_ novelId: Int64, _ cid: Int64) async throws {
        _ = try await request("DELETE", "/v1/novels/\(novelId)/characters/\(cid)")
    }

    func search(_ id: Int64, _ q: String) async throws -> [SearchHit] {
        struct R: Decodable { let hits: [SearchHit] }
        return try decode(R.self, await request("GET", "/v1/novels/\(id)/search", query: [URLQueryItem(name: "q", value: q)])).hits
    }
}
