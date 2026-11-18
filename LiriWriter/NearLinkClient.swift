// NearLinkClient.swift — 近場直連的「手機這一端」(2026-09-17)
//
// 做的事:找到 Mac 上的 LiriChat → 接上 → 把 URLRequest 原封不動送過去 →
// 把狀態碼、內容、以及 SSE 的每一行原封不動帶回來。
// 上層(ApiClient)只要換一個 fetch/lines 的來源,其他程式碼一行都不用動。
import Foundation
import Network
import SwiftUI
import Combine   // ⚠ MEMBER_IMPORT_VISIBILITY 打開後,@Published 要自己 import

/// 一次請求在近場上的回應事件。跟 HTTP 對得起來:先表頭,再內容,最後結束。
enum LinkEvent {
    case head(Int, [String: String])
    case chunk(Data)
    case end
}

// ⚠ class 本身不要標 @MainActor——AppState 的病史那條同樣適用:這個工具鏈下
// @MainActor 的 class 會讓合成的 objectWillChange 被隔離,過不了 ObservableObject。
// 作法一樣:class 保持 nonisolated,會碰 @Published 的成員各自標 @MainActor。
final class NearLinkClient: ObservableObject {
    static let shared = NearLinkClient()

    enum Status: Equatable {
        case off, searching, connecting, ready
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var peerName = ""
    /// 這一輪搜到的名字,純顯示用(找不到東西時最想知道的就是「到底看到了誰」)。
    @Published private(set) var found: [String] = []
    @Published var note: String = ""

    @MainActor
    var isReady: Bool { status == .ready }

    /// 現在這條線是 USB 接進來的(2026-09-20)。純顯示;走法完全一樣。
    @Published private(set) var viaUSB = false

    @MainActor
    var statusText: String {
        switch status {
        case .off:        return "關閉"
        case .searching:  return found.isEmpty ? "搜尋中…" : "搜尋中…(看到 \(found.joined(separator: "、")))"
        case .connecting: return "連線中…"
        case .ready:      return "已連上 \(peerName)" + (viaUSB ? "(USB)" : "")
        case .failed(let m): return "失敗:\(m)"
        }
    }

    private let queue = DispatchQueue(label: "nearlink.client")
    private var browser: NWBrowser?
    private var usbListener: NWListener?
    private var channel: LinkChannel?
    private var code = ""
    private var nextId: UInt32 = 1
    private var pending: [UInt32: AsyncThrowingStream<LinkEvent, Error>.Continuation] = [:]
    private var retryTask: Task<Void, Never>?
    private var retryDelay: UInt64 = 1
    private var lastEndpoint: NWEndpoint?
    private var requestDeadlines: [UInt32: Task<Void, Never>] = [:]
    private var streamingRequests: Set<UInt32> = []

    private init() {}

    // ── 開關 ──

    @MainActor
    func start(code newCode: String) {
        let c = newCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !c.isEmpty else { stop(); status = .failed("還沒有配對碼"); return }
        if c == code, let browser {
            switch browser.state {
            case .failed, .cancelled: break
            default: return
            }
        }
        stop()
        code = c
        status = .searching
        let b = NWBrowser(for: .bonjour(type: NearLink.serviceType, domain: nil),
                          using: NearLink.parameters())
        b.stateUpdateHandler = { [weak self, weak b] state in
            Task { @MainActor in
                guard let self, let b, self.browser === b else { return }
                switch state {
                case .failed(let err):
                    self.status = .failed(err.localizedDescription)
                    self.scheduleRetry()
                case .waiting(let err):
                    // 幾乎都是本地網路權限那一格還沒點「允許」
                    self.note = "等待中:\(err.localizedDescription)"
                default: break
                }
            }
        }
        b.browseResultsChangedHandler = { [weak self, weak b] results, _ in
            let names = results.map { Self.name(of: $0.endpoint) }
            Task { @MainActor in
                guard let self, let b, self.browser === b else { return }
                self.found = names.sorted()
                self.connectIfIdle()
            }
        }
        browser = b
        b.start(queue: queue)
        startUSB()
    }

    // ── USB 線(2026-09-20)──
    //
    // 手機在一個固定埠上聽;Mac 那端透過 usbmuxd(iTunes 那套 USB 通道)接進來。
    // 接進來的連線跟 Bonjour 撥出去的一模一樣地交給 LinkChannel(手機還是 client 角色),
    // 上面的請求/回應一個位元組都不用改。USB 一接上就優先用它——它不吃電、不看訊號。
    @MainActor
    private func startUSB() {
        #if os(iOS)
        guard usbListener == nil else { return }
        do {
            let l = try NWListener(using: NearLink.plainParameters(), on: NWEndpoint.Port(rawValue: NearLink.usbPort)!)
            l.stateUpdateHandler = { [weak self, weak l] state in
                if case .failed(let e) = state {
                    Task { @MainActor in
                        guard let self, let l, self.usbListener === l else { return }
                        self.note = "USB 監聽失敗:\(e.localizedDescription)"
                        self.usbListener = nil
                    }
                }
            }
            l.newConnectionHandler = { [weak self, weak l] conn in
                Task { @MainActor in
                    guard let self, let l, self.usbListener === l else { conn.cancel(); return }
                    self.adoptUSB(conn)
                }
            }
            usbListener = l
            l.start(queue: queue)
        } catch {
            note = "USB 監聽開不起來:\(error.localizedDescription)"
        }
        #endif
    }

    @MainActor
    private func adoptUSB(_ conn: NWConnection) {
        guard !code.isEmpty else { conn.cancel(); return }
        // 已經有一條 USB 在跑就不要第二條(Mac 那端每三秒會試一次,連上之後它就停)
        if channel != nil, viaUSB { conn.cancel(); return }
        // 有 Wi-Fi 直連的話換掉它:USB 更穩、不吃電
        let old = channel
        channel = nil
        old?.cancel()
        failAll("已切換連線，正在補回訊息")
        viaUSB = true
        status = .connecting
        wire(conn)
    }

    @MainActor
    func stop() {
        retryTask?.cancel(); retryTask = nil
        browser?.cancel(); browser = nil
        usbListener?.cancel(); usbListener = nil
        let old = channel
        channel = nil
        old?.cancel()
        viaUSB = false
        failAll("近場連線已關閉")
        found = []
        peerName = ""
        code = ""
        lastEndpoint = nil
        retryDelay = 1
        status = .off
    }

    /// 從背景回到前景時叫一次:睡著的那段時間裡,這條連線多半已經被系統收掉了。
    ///
    /// ⚠ 2026-09-18 病史:舊版只看 `browser == nil` / `channel == nil` 兩種情況。
    /// 但 iOS 把 App 停住之後,那兩個**物件都還在**——只是底下的 socket 已經死了,
    /// 而且系統不會回報。於是兩個判斷都不成立,resume 什麼都不做,狀態還掛著 ready,
    /// 直到下一個請求撞上去才知道。使用者看到的就是「回到 App 不會自己找一次」。
    ///
    /// 現在:兩個都在的話,**驗活**——走這條線打一次 /health,兩秒沒回就整組重來
    /// (重新 Bonjour、重接)。這是 async 的,呼叫端要 await 完再問 isReady,
    /// 不然看到的是驗活之前那個可能是假的 ready。
    @MainActor
    func resume() async {
        guard !code.isEmpty else { return }
        startUSB()
        if channel != nil, isReady, await probe(timeout: 3) { return }
        // 還在握手時保留它，由握手期限負責判斷；不要每次進前景都打斷新連線。
        if channel != nil, status == .connecting { return }
        let c = code            // stop() 會把 code 清掉,先留一份
        let endpoint = lastEndpoint
        stop()
        start(code: c)
        lastEndpoint = endpoint
        connectIfIdle()         // 曾經成功的端點可先接，不必重新等 Bonjour
    }

    /// 走近場打一次 /health。回 true = 這條線活著。逾時或任何錯誤都算死。
    @MainActor
    private func probe(timeout: TimeInterval) async -> Bool {
        var req = URLRequest(url: URL(string: "http://nearlink/health")!)   // host 不重要,對面只看路徑
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        if let (_, code) = try? await fetch(req) { return (200..<300).contains(code) }
        return false
    }

    /// 等近場**真的**接上,最多等 `timeout` 秒。已經 ready 立刻回 true;
    /// 沒開(code 空)立刻回 false;其餘就等狀態變 ready 或時間到。
    ///
    /// 為什麼要有這個(2026-09-18):回到前景時 `resume()` 才剛把 browser 起來,
    /// Bonjour 要一兩秒才找得到人;而 `health()` 是**同一刻**跑的,看到的永遠是
    /// 「還沒 ready」,於是判定走網路——而網路(熱點)是關的。結果是等 6 秒逾時、
    /// 顯示未連線,然後才靠 linkWatch 補救。差的只是這一兩秒的等待。
    @MainActor
    func waitUntilReady(timeout: TimeInterval) async -> Bool {
        if isReady { return true }
        if code.isEmpty || status == .off { return false }
        if case .failed(let m) = status, m.contains("配對碼") { return false }  // 不會好的,別等
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return false }
            if isReady { return true }
            if case .failed(let m) = status, m.contains("配對碼") { return false }
        }
        return isReady
    }

    // ── 找人、接上 ──

    private static func name(of endpoint: NWEndpoint) -> String {
        if case let .service(name, _, _, _) = endpoint { return name }
        return endpoint.debugDescription
    }

    @MainActor
    private func connectIfIdle() {
        guard channel == nil, !code.isEmpty, let browser else { return }
        let endpoint = browser.browseResults
            .sorted { Self.name(of: $0.endpoint) < Self.name(of: $1.endpoint) }
            .first?.endpoint ?? lastEndpoint
        guard let endpoint else {
            if status != .off { status = .searching }
            return
        }
        status = .connecting
        viaUSB = false
        lastEndpoint = endpoint
        let conn = NWConnection(to: endpoint, using: NearLink.parameters())
        wire(conn)
    }

    /// 把一條 TCP 連線(不管是自己撥出去的、還是 USB 接進來的)接上框協定。
    /// ⚠ 2026-10-20:回呼一律用 DispatchQueue.main.async 跳回主執行緒,**不要**改回 `Task { @MainActor in }`。
    /// 一框一個 Task 不保證照順序跑——「結束」框可能比最後一塊內容先處理(內容被截斷、JSON 壞掉),
    /// 內容也可能比表頭先到(那塊被丟掉)。圖、離線同步包這種切很多塊的最容易中。main queue 是嚴格先進先出。
    @MainActor
    private func wire(_ conn: NWConnection) {
        let ch = LinkChannel(connection: conn, code: code, role: .client, queue: queue)
        ch.onReady = { [weak self, weak ch] in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, let ch, self.channel === ch else { return }
                self.peerName = ch.peerName
                self.status = .ready
                self.note = ""
                self.retryDelay = 1
                self.retryTask?.cancel(); self.retryTask = nil
            }}
        }
        ch.onFrame = { [weak self, weak ch] header, body in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, let ch, self.channel === ch else { return }
                self.dispatch(header, body)
            }}
        }
        ch.onNote = { [weak self, weak ch] msg in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, let ch, self.channel === ch else { return }
                self.note = msg
            }}
        }
        ch.onClose = { [weak self, weak ch] reason in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self, let ch, self.channel === ch else { return }
                self.channel = nil
                let wasUSB = self.viaUSB
                self.viaUSB = false
                self.failAll(reason ?? (wasUSB ? "USB 線斷了" : "近場連線中斷"))
                if !self.code.isEmpty {
                    // 配對碼不對就別無止境地重試——那不是訊號問題,重試一萬次也一樣。
                    if let reason, reason.contains("配對碼") {
                        self.status = .failed(reason)
                    } else {
                        self.status = .searching
                        self.scheduleRetry()
                    }
                }
            }}
        }
        channel = ch
        ch.start()
    }

    @MainActor
    private func scheduleRetry() {
        retryTask?.cancel()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 8)
        retryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self.retryTask = nil
            if self.channel == nil, !self.code.isEmpty {
                if let browser = self.browser {
                    switch browser.state {
                    case .failed, .cancelled:
                        await self.resume()
                    default: self.connectIfIdle()
                    }
                } else { await self.resume() }
            }
        }
    }

    // ── 送請求 / 收回應 ──

    @MainActor
    func stream(_ req: URLRequest, sse: Bool) -> AsyncThrowingStream<LinkEvent, Error> {
        let (out, cont) = AsyncThrowingStream<LinkEvent, Error>.makeStream()
        guard let channel, isReady, let url = req.url else {
            cont.finish(throwing: NSError(domain: "NearLink", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "近場連線還沒接上(\(statusText))"]))
            return out
        }
        let id = nextId
        nextId &+= 1
        pending[id] = cont
        if sse { streamingRequests.insert(id) }
        // URLRequest 的期限也要套到自訂載體；原本近場 /health 會無限等。
        let timeout = max(0.1, min(req.timeoutInterval, 3600))
        requestDeadlines[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self, let pending = self.pending[id] else { return }
            self.abandon(id)
            pending.finish(throwing: NSError(domain: "NearLink", code: -1001,
                userInfo: [NSLocalizedDescriptionKey: "近場請求逾時，請回到 App 等待重新連線"]))
        }
        cont.onTermination = { [weak self] _ in
            Task { @MainActor in self?.abandon(id) }
        }

        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var path = comps?.percentEncodedPath ?? url.path
        if let q = comps?.percentEncodedQuery, !q.isEmpty { path += "?" + q }
        channel.send(["t": "req", "id": Int(id),
                      "m": req.httpMethod ?? "GET",
                      "p": path,
                      "sse": sse,
                      "h": req.allHTTPHeaderFields ?? [:]])

        // 內容切塊:一次四張圖的 base64 有一兩百萬位元組,不能塞成一框。
        let body = req.httpBody ?? Data()
        var off = 0
        while off < body.count {
            let n = min(NearLink.chunk, body.count - off)
            channel.send(["t": "rq", "id": Int(id)],
                         body: body.subdata(in: off..<(off + n)))
            off += n
        }
        channel.send(["t": "rqe", "id": Int(id)])
        return out
    }

    /// 一般請求:收完整包,連同狀態碼一起回。
    @MainActor
    func fetch(_ req: URLRequest) async throws -> (Data, Int) {
        var status = 0
        var buf = Data()
        for try await ev in stream(req, sse: false) {
            switch ev {
            case .head(let s, _): status = s
            case .chunk(let d): buf.append(d)
            case .end: break
            }
        }
        return (buf, status)
    }

    /// SSE:對面已經照行切好了,這裡只要把塊切回行。
    @MainActor
    func lines(for req: URLRequest) -> AsyncThrowingStream<String, Error> {
        let (out, cont) = AsyncThrowingStream<String, Error>.makeStream()
        let src = stream(req, sse: true)
        let task = Task {
            // ⚠ 切行要在 bytes 上做,不能先轉字串:一個中文字三個位元組,
            //   萬一剛好跨在兩塊之間,先轉字串就會把它切成兩個問號。
            var buf = Data()
            do {
                for try await ev in src {
                    switch ev {
                    case .head(let s, _):
                        if !(200..<300).contains(s) {
                            throw NSError(domain: "NearLink", code: s, userInfo: [
                                NSLocalizedDescriptionKey: "HTTP \(s)(近場)"])
                        }
                        cont.yield(": connected")
                    case .chunk(let d):
                        buf.append(d)
                        while let nl = buf.firstIndex(of: 0x0A) {
                            let line = Data(buf[buf.startIndex..<nl])
                            cont.yield(String(decoding: line, as: UTF8.self))
                            buf = Data(buf[buf.index(after: nl)...])
                        }
                    case .end:
                        break
                    }
                }
                if !buf.isEmpty { cont.yield(String(decoding: buf, as: UTF8.self)) }
                cont.finish()
            } catch {
                cont.finish(throwing: error)
            }
        }
        cont.onTermination = { _ in task.cancel() }
        return out
    }

    // ── 內部 ──

    @MainActor
    private func dispatch(_ header: [String: Any], _ body: Data) {
        guard let raw = header["id"] as? Int else { return }
        let id = UInt32(truncatingIfNeeded: raw)
        guard let cont = pending[id] else { return }
        switch header["t"] as? String {
        case "rs":
            if streamingRequests.contains(id) { requestDeadlines.removeValue(forKey: id)?.cancel() }
            cont.yield(.head(header["s"] as? Int ?? 0, header["h"] as? [String: String] ?? [:]))
        case "ch":
            cont.yield(.chunk(body))
        case "ed":
            requestDeadlines.removeValue(forKey: id)?.cancel()
            cont.yield(.end)
            cont.finish()
            pending[id] = nil
            streamingRequests.remove(id)
        case "er":
            requestDeadlines.removeValue(forKey: id)?.cancel()
            cont.finish(throwing: NSError(domain: "NearLink", code: -2, userInfo: [
                NSLocalizedDescriptionKey: (header["e"] as? String) ?? "近場那端出錯"]))
            pending[id] = nil
            streamingRequests.remove(id)
        default:
            break
        }
    }

    /// 呼叫端不要了(for await 提早離開):跟對面說一聲,免得它白跑一整段生成。
    @MainActor
    private func abandon(_ id: UInt32) {
        guard pending[id] != nil else { return }
        requestDeadlines.removeValue(forKey: id)?.cancel()
        pending[id] = nil
        streamingRequests.remove(id)
        channel?.send(["t": "cn", "id": Int(id)])
    }

    @MainActor
    private func failAll(_ reason: String) {
        for task in requestDeadlines.values { task.cancel() }
        requestDeadlines.removeAll()
        let err = NSError(domain: "NearLink", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: reason])
        for (_, cont) in pending { cont.finish(throwing: err) }
        pending.removeAll()
        streamingRequests.removeAll()
    }
}
