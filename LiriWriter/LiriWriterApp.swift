// LiriWriterApp.swift — 給主題、自動寫小說的 App(2026-11-10)
//
// 寫作在 Mac 上的 LiriChat 服務裡跑(Novel.cs):App 關掉也會繼續寫,打開再看進度。
import SwiftUI

@main
struct LiriWriterApp: App {
    @StateObject private var store = Store()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onChange(of: phase) { _, p in
                    if p == .active { Task { await store.resumeNear(); await store.refresh() } }
                }
        }
        .defaultSize(width: 1100, height: 760)
        #if os(macOS)
        Settings {
            ConnectionView().environmentObject(store).frame(width: 460).padding()
        }
        #endif
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @State private var selection: Int64?
    @State private var showNew = false
    @State private var showImport = false
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if !store.connected {
                    Label(store.lastError ?? "連線中…", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.secondary).font(.callout)
                }
                ForEach(store.novels) { n in
                    NavigationLink(value: n.id) { NovelRow(n: n) }
                        .contextMenu {
                            Button("刪除", role: .destructive) {
                                Task { await store.run("刪除") { try await store.api.delete(n.id) }
                                       if selection == n.id { selection = nil }
                                       await store.refresh() }
                            }
                        }
                }
            }
            .navigationTitle("作品")
            .refreshable { await store.refresh() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showNew = true } label: { Label("新作品", systemImage: "square.and.pencil") }
                }
                ToolbarItem(placement: .automatic) {
                    Button { showImport = true } label: { Label("匯入小說", systemImage: "square.and.arrow.down") }
                }
                ToolbarItem(placement: .automatic) {
                    Button { showSettings = true } label: { Label("連線", systemImage: "gearshape") }
                }
            }
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            #endif
        } detail: {
            if let id = selection {
                NovelView(id: id, store: store).id(id)
            } else {
                ContentUnavailableView("給我一個主題", systemImage: "book.pages",
                                       description: Text("按右上角「新作品」,輸入主題,剩下的交給我:書名、角色、性格、大綱,一章一章寫,每段寫完會自己做摘要記住。"))
            }
        }
        .sheet(isPresented: $showNew) {
            NewNovelView { id in selection = id }.environmentObject(store)
        }
        .sheet(isPresented: $showImport) {
            ImportNovelView { id in selection = id }.environmentObject(store)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                ConnectionView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false } } }
            }
            .environmentObject(store)
            #if os(macOS)
            .frame(width: 520, height: 700)
            #endif
        }
        .task {
            // 列表自己刷新:寫作在服務端跑,狀態(寫到第幾章、寫完了)要自己跟上;沒連上時更勤一點
            while !Task.isCancelled {
                await store.refresh()
                try? await Task.sleep(nanoseconds: store.connected ? 10_000_000_000 : 3_000_000_000)
            }
        }
    }
}

struct NovelRow: View {
    let n: NovelSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(n.title.isEmpty ? "(規劃中…)" : n.title).font(.headline).lineLimit(1)
            Text(n.theme).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 6) {
                StatusBadge(status: n.status, running: n.running)
                Text("\(n.chaptersDone)/\(n.targetChapters) 章").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct StatusBadge: View {
    let status: String
    var running: Bool = false
    var body: some View {
        let (t, c): (String, Color) = {
            switch status {
            case "planning": return ("規劃中", .orange)
            case "writing": return ("寫作中", .blue)
            case "done": return ("完成", .green)
            case "error": return ("出錯", .red)
            default: return (running ? "寫作中" : "暫停", .secondary)
            }
        }()
        Text(t).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(c.opacity(0.15), in: Capsule())
            .foregroundStyle(c)
    }
}

// ───────────── 新作品 ─────────────
struct NewNovelView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    var onCreated: (Int64) -> Void
    @State private var theme = ""
    @State private var style = ""
    @State private var chapters = 10
    @State private var words = 2500
    @State private var auto = false
    @State private var adult = false
    @State private var research = true
    @State private var researchHint = ""
    @State private var povName = ""
    @State private var pov = ""
    @State private var avoidOthers = true
    @State private var randomize = true
    /// 「複製之前的設定」:選一部舊作品,把主題、文風、「我」、查資料、成人向這些設定帶進來
    @State private var copyFrom: Int64 = 0
    @State private var copyCast = true
    @State private var copyCastCount = 0
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if !store.novels.isEmpty {
                    Section {
                        Picker("帶入設定", selection: $copyFrom) {
                            Text("不帶入,從頭填").tag(Int64(0))
                            ForEach(store.novels) { n in
                                Text(n.title.isEmpty ? n.theme : n.title).lineLimit(1).tag(n.id)
                            }
                        }
                        if copyFrom != 0 && copyCastCount > 0 {
                            Toggle("連角色卡一起帶(\(copyCastCount) 張)", isOn: $copyCast)
                        }
                    } header: { Text("複製之前的設定") } footer: {
                        Text("把那部作品的主題、文風、「我」、篇幅、查資料和成人向的設定填進下面,帶進來之後可以再改。角色卡帶過來會照用,不會被重新規劃改掉。")
                            .foregroundStyle(.tertiary)
                    }
                }
                Section("主題") {
                    LongField(text: $theme, hint: "例如:一個會修時鐘的少女,發現小鎮的時間每晚倒退一小時", lines: 8, title: "主題")
                }
                Section {
                    LongField(text: $style, hint: "例如:第一人稱、輕鬆幽默、像宮崎駿的動畫", lines: 3, title: "文風")
                } header: { Text("文風(選填)") } footer: {
                    Text("想特別強調或淡化的詞可以加權重:(溫柔:2) 加強、(冷酷:0.5) 減弱,1 是原樣,建議 0.3~3。寫範圍 (幽默:0.5~3) 就每次寫都隨機抽一個,讓每章氣氛不一樣。只有寫作模型是 gemma(story)時有效,其他模型會當成一般文字。")
                        .foregroundStyle(.tertiary)
                }
                Section {
                    TextField("", text: $povName, prompt: Hint("「我」的名字(選填,不填它會取)"))
                        .labelsHidden().multilineTextAlignment(.leading)
                    LongField(text: $pov, hint: "「我」是什麼樣的人(選填):\n32 歲男性,投資客,冷靜、話少、佔有慾強\n說話短、愛用命令句,私底下其實會心軟", lines: 6, title: "「我」")
                } header: { Text("我(第一人稱主角)") } footer: {
                    Text("有填就用第一人稱寫,「我」照你的設定來想、來做、來說話。之後也可以在「角色」裡改那張標著「我」的卡。")
                        .foregroundStyle(.tertiary)
                }
                Section("篇幅") {
                    Stepper("\(chapters) 章", value: $chapters, in: 1...100)
                    Stepper("每章約 \(words) 字", value: $words, in: 900...6000, step: 300)
                }
                Section {
                    Picker("寫法", selection: $auto) {
                        Text("一章一停(每章寫完等我)").tag(false)
                        Text("全自動寫到完").tag(true)
                    }
                    .pickerStyle(.inline)
                } footer: {
                    Text("一章一停:每寫完一章就停下來,你可以看、改大綱或角色、給下一章指示,再按繼續。之後隨時可以切換。")
                        .foregroundStyle(.tertiary)
                }
                Section {
                    Toggle("自己上網查資料", isOn: $research)
                    if research {
                        LongField(text: $researchHint, hint: "想讓它查的內容(選填,一行一件):\n昭和時代 喫茶店 菜單\n底片相機 操作 術語", lines: 5, title: "查資料")
                    }
                    Toggle("成人向", isOn: $adult)
                } footer: {
                    Text("上網查資料:你寫的「想讓它查的內容」開寫前會逐條先查;之後每章動筆前,它覺得哪裡不熟也會自己查。查到的整理成筆記存進這部作品的知識庫。\n成人向:角色卡多一欄「親密」。所有角色都是成年人,未成年角色一律不寫性內容。")
                        .foregroundStyle(.tertiary)
                }
                Section {
                    Toggle("避開之前作品的情節", isOn: $avoidOthers)
                    Toggle("隨機變化", isOn: $randomize)
                } footer: {
                    Text((avoidOthers
                         ? "開著:規劃時給它看最近幾部作品的大綱和口頭禪,要它換一個開場、換章節安排、換口頭禪。只在規劃時看,寫正文時不會讀到別本。"
                         : "關著:這部完全獨立規劃,不看其他作品。主題很像的話,寫出來可能會跟之前的很像。")
                         + "\n隨機變化:規劃時隨機抽一組開場、結構、節奏、衝突來源、氛圍和細節,每章再抽一兩個寫法,讓同樣的主題每次寫出來都不一樣。你的設定永遠優先,抽到的跟設定衝突就不用。")
                        .foregroundStyle(.tertiary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle("新作品")
            .onChange(of: copyFrom) { _, id in
                guard id != 0 else { copyCastCount = 0; return }
                Task {
                    do {
                        let d = try await store.api.detail(id)
                        theme = d.theme; style = d.style
                        chapters = d.targetChapters; words = d.chapterWords; auto = d.auto
                        adult = d.adult; research = d.research; researchHint = d.researchHint
                        povName = d.povName; pov = d.pov; avoidOthers = d.avoidOthers; randomize = d.randomize
                        copyCastCount = d.characters.filter { $0.source != "auto" }.count
                        error = nil
                    } catch { self.error = "讀不到那部作品的設定:\(error.localizedDescription)" }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "建立中…" : "開始") {
                        busy = true
                        Task {
                            do {
                                let d = try await store.api.create(theme: theme, style: style, chapters: chapters, words: words, auto: auto,
                                                                   adult: adult, research: research, researchHint: researchHint,
                                                                   povName: povName, pov: pov, avoidOthers: avoidOthers, randomize: randomize,
                                                                   castFrom: copyFrom != 0 && copyCast ? copyFrom : nil)
                                await store.refresh()
                                onCreated(d.id)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                            busy = false
                        }
                    }
                    .disabled(theme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                }
            }
        }
        #if os(macOS)
        .frame(width: 540, height: 720)
        #endif
    }
}

/// 輸入框的提示字:比正文暗,一看就知道是範例不是已經填好的內容。
func Hint(_ s: String) -> Text { Text(s).foregroundStyle(.tertiary) }
