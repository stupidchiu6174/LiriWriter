// Store.swift — App 狀態:連線設定、作品列表、目前打開的作品(寫作中會自己刷新)
import Foundation
import SwiftUI
import Combine

@MainActor
final class Store: ObservableObject {
    @AppStorage("serverURL") var serverURL: String = "http://127.0.0.1:8090"
    @AppStorage("apiKey") var apiKey: String = ""
    /// 配對時拿到的其他位址(區網 / Tailscale),以換行分隔。目前這個連不上就輪流試。
    @AppStorage("altURLs") var altURLs: String = ""
    /// 近地連結的配對碼(Chat App 的配對 QR 裡的 nl=)。有填就在網路不通時自動改走近地。
    @AppStorage("nearCode") var nearCode: String = ""

    @Published var novels: [NovelSummary] = []
    @Published var connected = false
    @Published var lastError: String?

    private(set) var api: Api

    init() {
        api = Api(baseURL: URL(string: "http://127.0.0.1:8090")!, apiKey: "")
        applySettings()
    }

    func applySettings() {
        if let u = URL(string: serverURL.trimmingCharacters(in: .whitespaces)) { api.baseURL = u }
        api.apiKey = apiKey
        #if os(iOS)
        let code = nearCode.trimmingCharacters(in: .whitespacesAndNewlines)
        api.nearEnabled = !code.isEmpty
        if code.isEmpty { NearLinkClient.shared.stop() } else { NearLinkClient.shared.start(code: code) }
        #endif
        Task { await refresh() }
    }

    /// 回到前景:睡著時近地那條線多半被系統收掉了,驗活、必要時重找
    func resumeNear() async {
        #if os(iOS)
        if !nearCode.isEmpty { await NearLinkClient.shared.resume() }
        #endif
    }
    var viaNear: Bool { api.viaNear }

    func refresh() async {
        do {
            novels = try await api.list()
            connected = true
            lastError = nil
        } catch {
            connected = await api.health()
            if !connected, await switchToReachable() {
                novels = (try? await api.list()) ?? novels
                lastError = nil
                return
            }
            lastError = connected ? error.localizedDescription : "連不上服務:\(serverURL)"
        }
    }

    /// 目前位址不通時,試配對時記下的其他位址(在家走區網、出門走 Tailscale)。
    private var switching = false
    private func switchToReachable() async -> Bool {
        if switching { return false }
        switching = true; defer { switching = false }
        let cur = serverURL.trimmingCharacters(in: .whitespaces)
        for alt in altURLs.split(separator: "\n").map(String.init) where alt != cur {
            guard let u = URL(string: alt) else { continue }
            let probe = Api(baseURL: u, apiKey: apiKey)
            if await probe.health() {
                serverURL = alt
                api.baseURL = u
                connected = true
                return true
            }
        }
        return false
    }

    /// 解析 Chat App 的配對 QR:lirichat://pair?h=…&p=…&k=…[&lan=…&ts=…]
    static func parsePairing(_ raw: String) -> (host: String, port: Int, key: String, hosts: [String], near: String)? {
        guard let comps = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.scheme == "lirichat", comps.host == "pair" else { return nil }
        let items = comps.queryItems ?? []
        func q(_ n: String) -> String? { items.first(where: { $0.name == n })?.value }
        guard let h = q("h"), let p = q("p").flatMap(Int.init), let k = q("k") else { return nil }
        var hosts: [String] = []
        for c in [q("lan"), q("ts"), h] { if let c, !c.isEmpty, !hosts.contains(c) { hosts.append(c) } }
        return (h, p, k, hosts, q("nl") ?? "")
    }

    /// 依序試每個位址(區網優先),連得上的那個留下來,其餘記著備用。
    func applyPairing(hosts: [String], port: Int, key: String, near: String = "") async -> Bool {
        if !near.isEmpty { nearCode = near }
        let urls = hosts.map { "http://\($0):\(port)" }
        altURLs = urls.joined(separator: "\n")
        apiKey = key
        api.apiKey = key
        for u in urls {
            guard let url = URL(string: u) else { continue }
            if await Api(baseURL: url, apiKey: key).health() {
                serverURL = u
                applySettings()
                await refresh()
                return connected
            }
        }
        serverURL = urls.first ?? serverURL
        applySettings()
        await refresh()
        return connected
    }

    func run(_ what: String, _ op: @escaping () async throws -> Void) async {
        do { try await op(); lastError = nil }
        catch { lastError = "\(what)失敗:\(error.localizedDescription)" }
    }
}

/// 一部作品的畫面狀態。寫作中每 2 秒拉一次(服務端會給「現在寫到哪、正在寫的字」)。
@MainActor
final class NovelModel: ObservableObject {
    let id: Int64
    let store: Store
    @Published var detail: NovelDetail?
    @Published var error: String?
    @Published var rewriteTarget: NovelChapter?
    private var poller: Task<Void, Never>?
    /// 上次拿到的原始資料:一樣就不重設 detail(重設會讓整個畫面重畫,手機上打字、選取時游標會跳)
    private var lastData: Data?

    init(id: Int64, store: Store) { self.id = id; self.store = store }

    func start() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.load()
                let busy = self.detail?.isBusy ?? false
                try? await Task.sleep(nanoseconds: busy ? 2_000_000_000 : 8_000_000_000)
            }
        }
    }
    func stop() { poller?.cancel(); poller = nil }

    func load() async {
        do {
            let (d, data) = try await store.api.detailData(id)
            let wasBusy = detail?.isBusy ?? false
            if data != lastData || detail == nil { detail = d; lastData = data }
            error = nil
            if wasBusy != d.isBusy { await store.refresh() }
        } catch {
            self.error = error.localizedDescription
            // 可能是換了網路(離開家裡 Wi-Fi):讓 Store 試另一個位址
            await store.refresh()
        }
    }

    func act(_ what: String, _ op: @escaping (Api) async throws -> Void) async {
        do { try await op(store.api); error = nil } catch { self.error = "\(what)失敗:\(error.localizedDescription)" }
        await load()
        await store.refresh()
    }
}
