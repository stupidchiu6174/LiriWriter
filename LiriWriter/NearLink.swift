// NearLink.swift — 近場直連(2026-09-17)
//
// 為什麼有這一層
// ──────────────
// 在外面的時候,手機開熱點不是為了讓 Mac 上網——這條路上根本沒有「網」要上,
// 模型就在 Mac 上跑,手機只是要跟它講話。但開熱點等於讓手機全程當一台基地台:
// AP 一直亮、NAT 一直轉、行動網路上行一直開著。電就是這樣掉的。
//
// 這一層把那台基地台拿掉:兩台機器直接對接。Bonjour 找到對方(藍牙負責發現),
// 資料走 AWDL 點對點 Wi-Fi。沒有路由器、沒有熱點、不需要 Tailscale。
//
// ⚠ 一句誠實話:資料**不是**走藍牙傳的。
// 純 BLE 實測大概幾十 KB/s,一張 1.2MB 的圖要傳一分鐘,而這個 App 是會傳圖的。
// 藍牙在這裡的角色是「發現對方」,真正的頻寬來自 Wi-Fi 直連。省電的來源是
// 「不用當熱點」——那才是耗電的大頭——不是換成低功耗無線。
//
// 架構不變
// ────────
//   手機 →(近場)→ Mac 上的這個 App → LiriChat 127.0.0.1:8090 → 模型管理器
// 手機永遠沒有直接打模型管理器。近場只是把同一組 HTTP 請求換一個載體:
// 同樣的 method/path/header/body 進去,同樣的狀態碼與 SSE 逐行出來。
// 服務端一行都不用改,也不知道這件事發生過。
import Foundation
import Network
import CryptoKit

enum NearLink {
    /// Bonjour 服務型別。名字部分要 ≤15 字元、小寫。
    static let serviceType = "_lirichat._tcp"
    static let version = 1
    /// 單一框上限。收到比這大的長度前綴 = 對方壞了、或根本不是這個協定 → 直接斷。
    static let maxFrame = 4 << 20
    /// 切塊大小。大一點吞吐好,小一點延遲低;32K 是圖與文字的折衷。
    static let chunk = 32 * 1024

    /// USB 線(2026-09-20):手機這端在這個 TCP 埠上**聽**,Mac 透過 usbmuxd 接進來。
    /// 方向跟 Bonjour 那條相反(TCP 是 Mac 撥給手機),但框協定不管誰撥的:
    /// 手機照樣是 client 角色、Mac 照樣是 host。任何埠都行,只要兩邊一致。
    static let usbPort: UInt16 = 27183

    /// 純 TCP 參數(loopback / USB 用):不要點對點,那會讓系統去找 AWDL。
    static func plainParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveCount = 3
        tcp.keepaliveInterval = 5
        let p = NWParameters(tls: nil, tcp: tcp)
        p.includePeerToPeer = false
        return p
    }

    /// 點對點參數。關鍵是 includePeerToPeer——沒有這行就只會用現成的 Wi-Fi,
    /// 有了才會讓系統自己去湊 AWDL/藍牙那條直連。
    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true                 // 逐行的 SSE 不能被 Nagle 攢著
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveCount = 3
        tcp.keepaliveInterval = 5
        let p = NWParameters(tls: nil, tcp: tcp)
        p.includePeerToPeer = true
        return p
    }

    /// 配對碼。拿掉看起來會搞混的字(0/O、1/I/l),因為這串是要用眼睛抄的。
    static func randomCode() -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }

    static var deviceName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
        #endif
    }

    // ── 大端序 32 位長度前綴 ──
    static func be32(_ v: Int) -> Data {
        let u = UInt32(truncatingIfNeeded: v)
        return Data([UInt8(truncatingIfNeeded: u >> 24), UInt8(truncatingIfNeeded: u >> 16),
                     UInt8(truncatingIfNeeded: u >> 8), UInt8(truncatingIfNeeded: u)])
    }

    static func readBE32(_ d: Data, at offset: Int) -> Int {
        let i = d.startIndex + offset
        return (Int(d[i]) << 24) | (Int(d[i + 1]) << 16) | (Int(d[i + 2]) << 8) | Int(d[i + 3])
    }
}

/// 一條近場連線。負責:握手、加解密、切框、把一個個「表頭 + 內容」交給上層。
///
/// 加密為什麼自己做而不是掛 TLS-PSK:TLS 的預共享金鑰在 Network.framework 要走
/// sec_protocol_options_add_pre_shared_key 那套 C 介面(還要手挑 ciphersuite),
/// 而這裡要的東西很小——雙方都知道同一組配對碼,就用它導一把金鑰,每框
/// ChaChaPoly 封一次。配對碼不對的人連第一框都解不開,所以「認證」與「加密」
/// 是同一件事,不需要另外設計一輪驗證。
///
/// 回呼都在自己的 queue 上跑,上層要碰 UI 得自己跳回主執行緒。
final class LinkChannel {
    enum Role { case client, host }

    let role: Role
    private let conn: NWConnection
    private let code: String
    private let queue: DispatchQueue
    private var key: SymmetricKey?
    private var myNonce = Data()
    private var inBuf = Data()
    private var closed = false
    private var authenticated = false
    private var handshakeDeadline: DispatchWorkItem?
    private var heartbeat: DispatchSourceTimer?
    private var lastReceivedAt = ProcessInfo.processInfo.systemUptime

    private(set) var peerName = ""

    /// 握手完成、而且雙方的配對碼確實對得上(對不上就不會走到這裡)。
    var onReady: (() -> Void)?
    var onFrame: (([String: Any], Data) -> Void)?
    var onClose: ((String?) -> Void)?
    var onNote: ((String) -> Void)?

    init(connection: NWConnection, code: String, role: Role, queue: DispatchQueue) {
        self.conn = connection
        self.code = code
        self.role = role
        self.queue = queue
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendHandshake()
            case .waiting(let err):
                // 最常見的是本地網路權限還沒給,或對方剛好不在。不是致命,報一聲繼續等。
                self.onNote?("等待中:\(err.localizedDescription)")
            case .failed(let err):
                self.close("連線失敗:\(err.localizedDescription)")
            case .cancelled:
                self.close(nil)
            default:
                break
            }
        }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, !self.authenticated else { return }
            self.close("近場握手逾時，正在重新連線")
        }
        handshakeDeadline = deadline
        queue.asyncAfter(deadline: .now() + 12, execute: deadline)
        conn.start(queue: queue)
        receiveLoop()
    }

    // close 的狀態與接收回呼都只在這條序列佇列修改。
    func cancel() { queue.async { self.close(nil) } }

    private func markReady() {
        guard !authenticated, !closed else { return }
        authenticated = true
        handshakeDeadline?.cancel(); handshakeDeadline = nil
        lastReceivedAt = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            if ProcessInfo.processInfo.systemUptime - self.lastReceivedAt > 40 {
                self.close("近場連線沒有回應，正在重新連線")
            } else { self.sendNow(["t": "ping"], Data()) }
        }
        heartbeat = timer
        timer.resume()
        onReady?()
    }

    // ── 送 ──

    /// 送一框(握手之後才有意義:沒有金鑰就丟掉,不會退回明文)。
    ///
    /// 一律繞回自己的 queue 再送:key/closed 是在收的那條路上寫的,而呼叫端在主
    /// 執行緒。同一條序列佇列處理讀寫,順序也順便保證了——請求表頭與後面的內容
    /// 分塊必須照順序抵達,不然對面拼不回來。
    func send(_ header: [String: Any], body: Data = Data()) {
        queue.async { [weak self] in self?.sendNow(header, body) }
    }

    private func sendNow(_ header: [String: Any], _ body: Data) {
        guard let key, !closed else { return }
        guard let hjson = try? JSONSerialization.data(withJSONObject: header) else { return }
        var plain = NearLink.be32(hjson.count)
        plain.append(hjson)
        plain.append(body)
        guard let sealed = try? ChaChaPoly.seal(plain, using: key).combined else { return }
        sendRaw(sealed)
    }

    private func sendRaw(_ payload: Data) {
        var out = NearLink.be32(payload.count)
        out.append(payload)
        conn.send(content: out, completion: .contentProcessed { [weak self] err in
            if let err { self?.close("送出失敗:\(err.localizedDescription)") }
        })
    }

    private func sendHandshake() {
        myNonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let hello: [String: Any] = ["v": NearLink.version,
                                    "n": myNonce.base64EncodedString(),
                                    "name": NearLink.deviceName]
        guard let d = try? JSONSerialization.data(withJSONObject: hello) else { return }
        sendRaw(d)      // 這一框是明文:金鑰還沒導出來,而它裡面也沒有秘密
    }

    // ── 收 ──

    private func receiveLoop() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lastReceivedAt = ProcessInfo.processInfo.systemUptime
                self.inBuf.append(data)
                self.drain()
            }
            if let err { self.close("斷線:\(err.localizedDescription)"); return }
            if isComplete { self.close(nil); return }
            if !self.closed { self.receiveLoop() }
        }
    }

    /// 把緩衝區裡完整的框都取出來。
    /// ⚠ 切片要用 Data(...) 再包一層:Data 的切片會**保留原始索引**,
    ///   不包的話下一輪的 startIndex 就不是 0,所有偏移量都會錯位。
    private func drain() {
        var offset = 0
        while inBuf.count - offset >= 4 {
            let len = NearLink.readBE32(inBuf, at: offset)
            if len <= 0 || len > NearLink.maxFrame { close("協定長度不合法(\(len))"); return }
            if inBuf.count - offset - 4 < len { break }
            let start = inBuf.startIndex + offset + 4
            let frame = Data(inBuf[start..<(start + len)])
            offset += 4 + len
            handle(frame)
            if closed { return }
        }
        if offset > 0 {
            inBuf = Data(inBuf[(inBuf.startIndex + offset)...])
        }
    }

    private func handle(_ frame: Data) {
        if key == nil {
            // 還沒握手:這框一定是對方的 hello(明文)
            guard let obj = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
                  let n64 = obj["n"] as? String,
                  let peerNonce = Data(base64Encoded: n64),
                  (obj["v"] as? Int) == NearLink.version else {
                close("對方不是這個版本的近場協定"); return
            }
            peerName = (obj["name"] as? String) ?? "對方"
            // salt 的順序兩邊要一致:固定「客戶端的 nonce 在前」。
            let salt = role == .client ? myNonce + peerNonce : peerNonce + myNonce
            key = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
                salt: salt,
                info: Data("lirichat-nearlink-v1".utf8),
                outputByteCount: 32)
            // 客戶端先敲一下;敲得開就代表兩邊的配對碼一樣。
            if role == .client { send(["t": "ping"]) }
            return
        }

        guard let key,
              let box = try? ChaChaPoly.SealedBox(combined: frame),
              let plain = try? ChaChaPoly.open(box, using: key) else {
            // 解不開只有一個原因:配對碼不一樣。講清楚,不要讓人以為是訊號問題。
            close("配對碼不符——兩邊要是同一串"); return
        }
        guard plain.count >= 4 else { return }
        let hlen = NearLink.readBE32(plain, at: 0)
        guard hlen >= 0, plain.count >= 4 + hlen else { return }
        let hstart = plain.startIndex + 4
        let hdata = Data(plain[hstart..<(hstart + hlen)])
        let body = Data(plain[(hstart + hlen)...])
        guard let header = try? JSONSerialization.jsonObject(with: hdata) as? [String: Any] else { return }

        switch header["t"] as? String {
        case "ping":
            send(["t": "pong"])
            markReady()                // 心跳不能再次發出「剛連上」通知
        case "pong":
            markReady()
        default:
            onFrame?(header, body)
        }
    }

    private func close(_ reason: String?) {
        if closed { return }
        closed = true
        handshakeDeadline?.cancel(); handshakeDeadline = nil
        heartbeat?.cancel(); heartbeat = nil
        conn.cancel()
        onClose?(reason)
    }
}
