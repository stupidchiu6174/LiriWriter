// ConnectionView.swift — 連線設定。
// Mac:直接連本機,並顯示配對 QR 給 iPhone 掃(不用另外開 LiriChat)。
// iPhone:掃 QR,或從剪貼簿貼上配對字串(Mac 上按「複製」,通用剪貼簿會帶過來)。
import SwiftUI
import CoreImage.CIFilterBuiltins

struct PairInfo: Decodable {
    let host: String
    let port: Int
    let key: String
    let payload: String
    let tailscale: Bool
    var lan: String? = nil
}

struct ConnectionView: View {
    @EnvironmentObject var store: Store
    @State private var url = ""
    @State private var key = ""
    @State private var paste = ""
    @State private var scanning = false
    @State private var note: String?
    #if os(iOS)
    @ObservedObject private var near = NearLinkClient.shared
    @State private var nearCode = ""
    #endif

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: store.connected ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(store.connected ? .green : .red)
                    Text(store.connected ? "已連上 \(store.serverURL)" : (store.lastError ?? "未連線"))
                }
            }
            #if os(macOS)
            Section("讓 iPhone 連上") { MacPairQR() }
            #else
            Section {
                Button { scanning = true } label: { Label("掃描配對 QR", systemImage: "qrcode.viewfinder") }
                Button { pasteFromClipboard() } label: { Label("從剪貼簿貼上配對字串", systemImage: "doc.on.clipboard") }
                if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("QR 在 Mac 版「Liri 寫作」→ 齒輪 裡(LiriChat 的配對 QR 也可以)。掃不到的話,在 Mac 按「複製配對字串」,再按上面的「從剪貼簿貼上」。")
                    .foregroundStyle(.tertiary)
            }
            Section {
                HStack {
                    Image(systemName: near.isReady ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(near.isReady ? .green : .secondary)
                    Text(store.nearCode.isEmpty ? "還沒有配對碼" : near.statusText)
                    if store.viaNear { Spacer(); Text("使用中").foregroundStyle(.green).font(.caption) }
                }
                TextField("近地配對碼", text: $nearCode, prompt: Hint("近地配對碼(掃 Chat App 的 QR 會自動填)"))
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                Button("套用配對碼") { store.nearCode = nearCode; store.applySettings() }
                    .disabled(nearCode == store.nearCode)
            } header: { Text("近地連結") } footer: {
                Text("出門沒網路時,不用開熱點:透過藍牙找到 Mac、用 Wi-Fi 直連。Mac 上的 Chat App 要開著、打開「近場直連」。掃 Mac 版 Chat App 的配對 QR 就會一起設好;網路連不上時自動切過去,網路通了自動切回。")
                    .foregroundStyle(.tertiary)
            }
            #endif
            Section("手動") {
                TextField("服務位址", text: $url, prompt: Hint("服務位址,例如 http://100.x.x.x:8090"))
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()
                SecureField("金鑰", text: $key, prompt: Hint("金鑰(Mac 本機連線可以留空)"))
                TextField("配對字串", text: $paste, prompt: Hint("或貼上配對字串 lirichat://pair?…"))
                    .autocorrectionDisabled()
                Button("套用") {
                    if let p = Store.parsePairing(paste) {
                        Task { _ = await store.applyPairing(hosts: p.hosts, port: p.port, key: p.key, near: p.near); url = store.serverURL; key = store.apiKey }
                    } else {
                        store.serverURL = url; store.apiKey = key; store.applySettings()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("連線")
        .onAppear {
            url = store.serverURL; key = store.apiKey
            #if os(iOS)
            nearCode = store.nearCode
            #endif
        }
        #if os(iOS)
        .sheet(isPresented: $scanning) {
            NavigationStack { QRScannerView().environmentObject(store) }
        }
        #endif
    }

    #if os(iOS)
    func pasteFromClipboard() {
        guard let s = UIPasteboard.general.string, let p = Store.parsePairing(s) else {
            note = "剪貼簿裡沒有配對字串。先在 Mac 上按「複製配對字串」。"; return
        }
        note = "連線中… \(p.host):\(p.port)"
        Task {
            let ok = await store.applyPairing(hosts: p.hosts, port: p.port, key: p.key, near: p.near)
            note = ok ? "已連上 \(p.host):\(p.port)" : (store.lastError ?? "連不上")
            url = store.serverURL; key = store.apiKey
        }
    }
    #endif
}

func makeQRImage(_ string: String) -> Image? {
    let context = CIContext()
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
          let cg = context.createCGImage(out, from: out.extent) else { return nil }
    #if os(macOS)
    return Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: out.extent.width, height: out.extent.height)))
    #else
    return Image(uiImage: UIImage(cgImage: cg))
    #endif
}

#if os(macOS)
import AppKit

/// 跟 LiriChat 的 /pair 拿配對資訊(只准本機拿,裡面有金鑰)。
struct MacPairQR: View {
    @EnvironmentObject var store: Store
    @State private var info: PairInfo?
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        VStack(spacing: 12) {
            if let info {
                let hasLan = !(info.lan ?? "").isEmpty
                if !info.tailscale && !hasLan {
                    Label("這台 Mac 的 Tailscale 沒開,也沒有區網位址,QR 裡只有 127.0.0.1,iPhone 連不到。",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                } else if !info.tailscale {
                    Label("Tailscale 沒開:只有同一個 Wi-Fi 的 iPhone 連得到,出門就連不上。",
                          systemImage: "wifi").foregroundStyle(.secondary).font(.callout)
                }
                if let img = makeQRImage(info.payload) {
                    img.interpolation(.none).resizable().scaledToFit()
                        .frame(width: 220, height: 220)
                        .padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14))
                }
                Text(([info.lan ?? ""].filter { !$0.isEmpty } + (info.tailscale ? [info.host] : []))
                        .map { "\($0):\(info.port)" }.joined(separator: " · "))
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                Text("同一個 Wi-Fi 走區網,出門自動改走 Tailscale").font(.caption).foregroundStyle(.tertiary)
                HStack {
                    Button(copied ? "已複製" : "複製配對字串") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(info.payload, forType: .string)
                        copied = true
                    }
                    Button("重新產生") { Task { await load() } }
                }
                Text("iPhone:Liri 寫作 → 齒輪 → 掃描配對 QR。掃不到就按「複製配對字串」,iPhone 那邊按「從剪貼簿貼上」(同一個 Apple 帳號的通用剪貼簿)。")
                    .font(.footnote).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            } else if let error {
                Text(error).foregroundStyle(.red)
                Button("再試一次") { Task { await load() } }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .task { await load() }
    }

    func load() async {
        do {
            var comps = URLComponents(url: store.api.baseURL, resolvingAgainstBaseURL: false)!
            comps.host = "127.0.0.1"; comps.path = "/pair"
            let (data, _) = try await URLSession.shared.data(from: comps.url!)
            info = try JSONDecoder().decode(PairInfo.self, from: data)
            error = nil; copied = false
        } catch { self.error = "拿不到配對資訊(LiriChat 服務有在跑嗎?):\(error.localizedDescription)" }
    }
}
#endif

#if os(iOS)
import AVFoundation

struct QRScannerView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var scanned = false
    @State private var message: String?

    var body: some View {
        ZStack {
            CameraScanner(onFound: { code in
                guard !scanned else { return }
                guard let p = Store.parsePairing(code) else { message = "這不是 LiriChat 的配對碼"; return }
                scanned = true
                message = "連線中… \(p.host):\(p.port)"
                Task {
                    if p.host == "127.0.0.1" {
                        message = "QR 裡是 127.0.0.1:Mac 的 Tailscale 沒開。打開後在 Mac 按「重新產生」再掃。"
                        scanned = false; return
                    }
                    if await store.applyPairing(hosts: p.hosts, port: p.port, key: p.key, near: p.near) {
                        message = "已連上"
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        dismiss()
                    } else {
                        message = store.lastError ?? "連不上——確認 Mac 的 Tailscale 開著"
                        scanned = false
                    }
                }
            }, onError: { message = $0 })
            .ignoresSafeArea()
            VStack {
                Spacer()
                Text(message ?? "把相機對準 Mac 上的 QR(離螢幕 20 公分以上比較好對焦)")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.bottom, 40)
            }
        }
        .navigationTitle("掃描 QR")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
    }
}

struct CameraScanner: UIViewControllerRepresentable {
    let onFound: (String) -> Void
    let onError: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC(); vc.onFound = onFound; vc.onError = onError; return vc
    }
    func updateUIViewController(_ vc: ScannerVC, context: Context) {}
}

/// 相機掃碼。
/// ⚠ iPhone 13 Pro 以後的 Pro 機型:主鏡頭(wide)最近對焦距離約 20 公分,拿近一點拍 Mac 螢幕就糊掉、永遠掃不到。
///   改用三鏡頭/雙鏡頭的「虛擬裝置」(會自己切超廣角做微距),再照 Apple 建議依最近對焦距離放大一點。
final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onFound: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { ok ? self.configure() : self.onError?("沒有相機權限:到 設定 → Liri 寫作 → 相機 打開") }
            }
        default: onError?("沒有相機權限:到 設定 → Liri 寫作 → 相機 打開")
        }
    }

    private func bestCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices
        for t in types { if let d = found.first(where: { $0.deviceType == t }) { return d } }
        return AVCaptureDevice.default(for: .video)
    }

    private func configure() {
        guard let device = bestCamera(),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { onError?("打不開相機"); return }
        session.beginConfiguration()
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }
        session.commitConfiguration()

        // 連續自動對焦＋依最近對焦距離放大(Apple 範例 AVCamBarcode 的算法):QR 約 6 公分寬時要多近才對得到焦
        try? device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
        let minFocus = Float(device.minimumFocusDistance)   // mm,-1 = 不知道
        if minFocus > 0 {
            let fov = device.activeFormat.videoFieldOfView
            let codeMM: Float = 60, coverage: Float = 0.4
            let needed = codeMM / coverage / (2 * tan(fov * .pi / 360))
            if needed < minFocus {
                let zoom = CGFloat(minFocus / needed)
                device.videoZoomFactor = min(max(zoom, 1), device.activeFormat.videoMaxZoomFactor)
            }
        }
        device.unlockForConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
    }

    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); if session.isRunning { session.stopRunning() } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let obj = objects.first as? AVMetadataMachineReadableCodeObject, let str = obj.stringValue else { return }
        onFound?(str)
    }
}
#endif
