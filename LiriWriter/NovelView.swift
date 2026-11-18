// NovelView.swift — 一部作品:正文 / 角色 / 設定與大綱 / 記憶
import SwiftUI

enum NovelTab: String, CaseIterable, Identifiable {
    case text = "正文", cast = "角色", plan = "設定與大綱", tools = "分析與世界觀", memory = "記憶與資料"
    var id: String { rawValue }
}

struct NovelView: View {
    @StateObject private var model: NovelModel
    @State private var tab: NovelTab = .text
    @State private var note = ""
    @State private var confirmDeleteLast = false

    init(id: Int64, store: Store) {
        _model = StateObject(wrappedValue: NovelModel(id: id, store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let d = model.detail {
                header(d)
                Picker("", selection: $tab) {
                    ForEach(NovelTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal).padding(.bottom, 8)
                Divider()
                switch tab {
                case .text: ChaptersView(model: model, d: d)
                case .cast: CastView(model: model, d: d)
                case .plan: PlanView(model: model, d: d)
                case .tools: ToolsView(model: model, d: d)
                case .memory: MemoryView(model: model, d: d)
                }
            } else if let e = model.error {
                ContentUnavailableView("讀不到", systemImage: "exclamationmark.triangle", description: Text(e))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(model.detail?.title.isEmpty == false ? model.detail!.title : "規劃中…")
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .confirmationDialog("刪掉最後一章?", isPresented: $confirmDeleteLast, titleVisibility: .visible) {
            Button("刪掉,之後重寫", role: .destructive) {
                Task { await model.act("刪除最後一章") { try await $0.deleteLastChapter(model.id) } }
            }
        } message: { Text("這章的正文、摘要記憶、這章才登場的角色都會一起刪掉。") }
    }

    @ViewBuilder
    func header(_ d: NovelDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                StatusBadge(status: d.status, running: d.job != nil)
                Text("\(d.chaptersDone)/\(d.targetChapters) 章 · \(d.chapters.reduce(0) { $0 + $1.chars }) 字 · 記憶 \(d.memoryCount) 筆")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            Text(d.theme).font(.callout).foregroundStyle(.secondary).lineLimit(2)

            if let j = d.job {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(j.phase.isEmpty ? "準備中…" : j.phase).font(.callout)
                    Spacer()
                    Button("停止", role: .destructive) {
                        Task { await model.act("停止") { try await $0.stop(model.id) } }
                    }
                }
            } else if d.status != "planning" {
                if d.status == "error" && !d.error.isEmpty {
                    Text(d.error).font(.callout).foregroundStyle(.red)
                }
                if d.status != "done" {
                    HStack {
                        TextField("", text: $note, prompt: Hint("給下一章的指示(選填):例如「讓兩人吵一架」"))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                HStack {
                    if d.status == "error" && d.chapters.isEmpty {
                        Button("重新規劃") { Task { await model.act("重新規劃") { try await $0.replan(model.id) } } }
                            .buttonStyle(.borderedProminent)
                    } else if d.status != "done" {
                        Button(d.chapters.contains { $0.status != "done" } ? "繼續寫這章" : "寫下一章") {
                            let n = note; note = ""
                            Task { await model.act("寫作") { try await $0.write(model.id, all: false, note: n.isEmpty ? nil : n) } }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("一路寫到完") {
                            let n = note; note = ""
                            Task { await model.act("寫作") { try await $0.write(model.id, all: true, note: n.isEmpty ? nil : n) } }
                        }
                    } else {
                        Text("全部寫完了。要加長就到「設定與大綱」把章數加上去。").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !d.chapters.isEmpty {
                        Button("刪掉最後一章") { confirmDeleteLast = true }
                            .buttonStyle(.borderless).foregroundStyle(.red)
                    }
                }
            }
            if let e = model.error { Text(e).font(.caption).foregroundStyle(.red) }
        }
        .padding()
    }
}

// ───────────── 正文 ─────────────
struct ChaptersView: View {
    @ObservedObject var model: NovelModel
    let d: NovelDetail
    @State private var rewriting: NovelChapter?
    @State private var confirmRevert: NovelChapter?
    @State private var showSummary = false
    /// 寫作中自動捲到最新的字(手機上一章很長,不捲就看不到正在寫的地方)
    @State private var follow = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if d.status == "planning", let j = d.job {
                        LiveBlock(title: "規劃中", text: j.live, phase: j.phase, lookups: j.lookups)
                    }
                    if d.chapters.isEmpty && d.status != "planning" {
                        Text("還沒開始寫。按上面的「寫下一章」。").foregroundStyle(.secondary)
                    }
                    ForEach(d.chapters) { c in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("第 \(c.idx) 章" + (c.title.isEmpty ? "" : " \(c.title)"))
                                    .font(.title2.weight(.semibold))
                                Spacer()
                                if c.status == "done" && d.job == nil {
                                    Menu {
                                        Button { rewriting = c } label: { Label("重寫…", systemImage: "pencil.and.outline") }
                                        if c.hasOriginal {
                                            Button(role: .destructive) { confirmRevert = c } label: { Label("還原原稿", systemImage: "arrow.uturn.backward") }
                                        }
                                    } label: { Image(systemName: "ellipsis.circle") }
                                    .menuStyle(.borderlessButton).fixedSize()
                                }
                            }
                            if c.hasOriginal {
                                Text("已重寫" + (c.rewriteNote.isEmpty ? "" : ":\(c.rewriteNote)")).font(.caption).foregroundStyle(.orange)
                            }
                            if showSummary && !c.technique.isEmpty {
                                Text("這章抽到的寫法:" + c.technique).font(.caption).foregroundStyle(.purple)
                            }
                            if showSummary && !c.summary.isEmpty {
                                Text("摘要:" + c.summary).font(.callout).foregroundStyle(.secondary)
                                    .padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                            }
                            if !c.content.isEmpty {
                                ProseText(text: c.content)
                            }
                            if let j = d.job, j.chapter == c.idx, !j.live.isEmpty {
                                ProseText(text: j.live, secondary: true)
                            }
                            if c.status != "done" {
                                Text("已寫 \(c.segDone)/\(c.segTotal) 段").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .id(c.idx)
                    }
                    if let j = d.job, d.status == "writing", !d.chapters.contains(where: { $0.idx == j.chapter }) {
                        LiveBlock(title: "第 \(j.chapter) 章", text: j.live, phase: j.phase, lookups: j.lookups)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: (d.job?.live.count ?? -1) + (d.job?.phase.hashValue ?? 0)) { _, _ in
                guard follow, d.job != nil else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear {
                if d.job != nil { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .sheet(item: $rewriting) { c in
                RewriteSheet(model: model, d: d, chapter: c)
            }
            .confirmationDialog("還原第 \(confirmRevert?.idx ?? 0) 章的原稿?", isPresented: Binding(get: { confirmRevert != nil }, set: { if !$0 { confirmRevert = nil } }), titleVisibility: .visible) {
                Button("還原", role: .destructive) {
                    if let c = confirmRevert {
                        Task { await model.act("還原") { try await $0.revert(model.id, chapter: c.idx) } }
                    }
                }
            } message: { Text("重寫過的版本會被丟掉,回到第一次重寫之前的原稿。") }
            .toolbar {
                ToolbarItem {
                    Toggle(isOn: $follow) { Label("跟著寫", systemImage: "text.line.last.and.arrowtriangle.forward") }
                }
                ToolbarItem {
                    Toggle(isOn: $showSummary) { Label("顯示摘要", systemImage: "text.badge.checkmark") }
                }
                ToolbarItem {
                    Button { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
                        Label("到最後", systemImage: "arrow.down.to.line")
                    }
                }
            }
        }
    }
}

struct LiveBlock: View {
    let title: String
    let text: String
    var phase: String = ""
    var lookups: [String] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title2.weight(.semibold))
            // 查資料、整理筆記這些步驟沒有正文可看,至少讓人知道它在做什麼
            if !phase.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(phase).font(.callout).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(lookups.enumerated()), id: \.offset) { _, l in
                Text("· " + l).font(.caption).foregroundStyle(.tertiary)
            }
            if !text.isEmpty {
                Text(text).font(.system(size: 17)).lineSpacing(7).foregroundStyle(.secondary)
            } else if phase.isEmpty {
                Text("…").foregroundStyle(.secondary)
            }
        }
    }
}

// ───────────── 角色 ─────────────
struct CastView: View {
    @ObservedObject var model: NovelModel
    let d: NovelDetail
    @State private var editing: NovelCharacter?

    var body: some View {
        List {
            ForEach(d.characters) { c in
                Button { editing = c } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(c.name).font(.headline)
                            Text(c.role).font(.caption).foregroundStyle(.secondary)
                            if !c.profile.isEmpty { Text(c.profile).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if c.source == "auto" {
                                Text("第 \(c.firstChapter) 章自動加入").font(.caption2).foregroundStyle(.blue)
                            }
                        }
                        if !c.personality.isEmpty { Text("性格:" + c.personality).font(.callout) }
                        if !c.voice.isEmpty { Text("說話:" + c.voice).font(.caption).foregroundStyle(.secondary) }
                        if !c.state.isEmpty { Text(c.state).font(.caption).foregroundStyle(.orange) }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .toolbar {
            ToolbarItem { Button { editing = .blank() } label: { Label("新增角色", systemImage: "person.badge.plus") } }
        }
        .sheet(item: $editing) { c in
            CharacterEditor(c: c, onSave: { nc in
                Task { await model.act("儲存角色") { try await $0.saveCharacter(model.id, nc) } }
            }, onDelete: c.id == 0 ? nil : {
                Task { await model.act("刪除角色") { try await $0.deleteCharacter(model.id, c.id) } }
            })
        }
    }
}

struct CharacterEditor: View {
    @State var c: NovelCharacter
    var onSave: (NovelCharacter) -> Void
    var onDelete: (() -> Void)?
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Toggle("這是「我」(第一人稱敘事者)", isOn: Binding(
                    get: { c.role.contains("我") },
                    set: { on in
                        if on { c.role = "主角(我)" }
                        else { c.role = c.role.replacingOccurrences(of: "(我)", with: "").replacingOccurrences(of: "（我）", with: "").replacingOccurrences(of: "我", with: "") ; if c.role.isEmpty { c.role = "主角" } }
                    }))
                field("名字", $c.name)
                field("定位(主角/重要配角/反派/配角)", $c.role)
                field("性別年齡(例如:32歲,男性)", $c.profile)
                field("外貌", $c.look)
                field("性格", $c.personality)
                field("說話方式", $c.voice)
                field("背景", $c.background)
                field("目標", $c.goal)
                field("關係", $c.relations)
                field("親密(成人向作品用:相處的樣子、喜好)", $c.desire)
                field("目前狀態(每章寫完會自動更新)", $c.state)
                if let onDelete {
                    Button("刪除這個角色", role: .destructive) { onDelete(); dismiss() }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(c.id == 0 ? "新增角色" : c.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") { onSave(c); dismiss() }.disabled(c.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 620)
        #endif
    }

    /// 標題放在欄位上面:填了字之後 placeholder 就不見了,看不出哪欄是哪欄
    func field(_ label: String, _ b: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            LongField(text: b, hint: label, lines: 4, title: label)
        }
    }
}

// ───────────── 設定與大綱 ─────────────
struct PlanView: View {
    @ObservedObject var model: NovelModel
    let d: NovelDetail
    @State private var title = ""
    @State private var style = ""
    @State private var world = ""
    @State private var outline = ""
    @State private var spine = ""
    @State private var ledger = ""
    @State private var rules = ""
    @State private var maps = ""
    @State private var target = 10
    @State private var words = 2500
    @State private var auto = false
    @State private var adult = false
    @State private var research = true
    @State private var avoidOthers = true
    @State private var shareKb = false
    @State private var randomize = true
    @State private var variation = ""
    @State private var researchHint = ""
    @State private var loaded = false

    var dirty: Bool {
        title != d.title || style != d.style || world != d.world || outline != d.outline ||
        spine != d.spine || ledger != d.ledger || rules != d.rules || maps != d.maps || shareKb != (d.shareKb ?? false) ||
        target != d.targetChapters || words != d.chapterWords || auto != d.auto ||
        adult != d.adult || research != d.research || researchHint != d.researchHint || avoidOthers != d.avoidOthers ||
        randomize != d.randomize || variation != d.variation
    }

    var body: some View {
        Form {
            Section {
                TextField("書名", text: $title, prompt: Hint("書名"))
                LongField(text: $style, hint: "文風", lines: 3, title: "文風")
                Stepper("共 \(target) 章", value: $target, in: max(1, d.chaptersDone)...200)
                Stepper("每章約 \(words) 字", value: $words, in: 900...6000, step: 300)
                Toggle("全自動寫到完(關掉 = 每章寫完停下來)", isOn: $auto)
                Toggle("自己上網查資料", isOn: $research)
                Toggle("成人向", isOn: $adult)
                Toggle("重新規劃時避開之前作品的情節", isOn: $avoidOthers)
                Toggle("共用其他作品查到的資料(關掉 = 只用這部自己查的)", isOn: $shareKb)
                Toggle("隨機變化(每章抽寫法、重新規劃時重抽)", isOn: $randomize)
            } header: { Text("作品") } footer: {
                Text("想特別強調或淡化的詞可以加權重:(溫柔:2) 加強、(冷酷:0.5) 減弱,1 是原樣,建議 0.3~3。寫範圍 (幽默:0.5~3) 就每次寫都隨機抽一個,讓每章氣氛不一樣。只有寫作模型是 gemma(story)時有效,其他模型會當成一般文字。")
                    .foregroundStyle(.tertiary)
            }
            if randomize || !variation.isEmpty {
                Section {
                    Editor(text: $variation, title: "隨機變化").editorHeight(110).font(.body)
                } header: { Text("這次抽到的變化") } footer: {
                    Text("規劃時隨機抽的,一行一條;可以直接改或刪。按「重新規劃」會重抽一組。每章抽到的寫法,在正文打開「顯示摘要」就看得到。")
                        .foregroundStyle(.tertiary)
                }
            }
            Section {
                Editor(text: $researchHint, title: "查資料").editorHeight(80).font(.body)
            } header: { Text("想讓它查的內容") } footer: {
                Text("一行一件。還沒查過的,下一章動筆前會先查;它自己判斷要查什麼時也會往這些方向想。要馬上查,到「記憶與資料」用「上網查」。")
                    .foregroundStyle(.tertiary)
            }
            Section {
                Editor(text: $rules, title: "硬性規定").editorHeight(160).font(.body)
            } header: { Text("硬性規定") } footer: {
                Text("從你的設定整理出來、絕對不能違反的規定(第幾章要發生什麼、角色的性格和態度、例外)。規劃、分段、寫作都會照著做,分段後還會再檢查一次。整理錯了可以直接改;改了主題設定會重新整理。")
                    .foregroundStyle(.tertiary)
            }
            Section("世界") {
                Editor(text: $world, title: "世界").editorHeight(110).font(.body)
            }
            Section {
                Editor(text: $outline, title: "大綱").editorHeight(260).font(.body)
            } header: { Text("大綱") } footer: {
                Text("一行一章,格式:第N章|章名|這章發生什麼(後面的「起因」「推進」是這章跟前面的因果和推進哪條線)。還沒寫的章可以直接改;超出大綱的章,寫到時會依前面的發展自己想。")
                    .foregroundStyle(.tertiary)
            }
            Section {
                Editor(text: $spine, title: "主線").editorHeight(160).font(.body)
            } header: { Text("主線") } footer: {
                Text("核心衝突、劇情線(第幾章開始、轉折、收尾)、伏筆(第幾章埋、第幾章用上)。規劃時自動產生,寫每一章都會照著它推進;可以直接改。")
                    .foregroundStyle(.tertiary)
            }
            Section {
                Editor(text: $ledger, title: "伏筆表").editorHeight(160).font(.body)
            } header: { Text("伏筆表") } footer: {
                Text("還沒收的伏筆、懸念、秘密、進行中的計畫,每章寫完自動更新。寫作時會拿來用,最後兩章會收掉。想讓它記得或忘掉什麼,可以直接加或刪一行。")
                    .foregroundStyle(.tertiary)
            }
            Section {
                Editor(text: $maps, title: "結構圖").editorHeight(260).font(.body)
            } header: { Text("結構圖") } footer: {
                Text("心智圖(主題往外的分支)、流程結構圖(每章事件 → 結果,「待接」的下一章要接上)、區塊連結圖(人物、地點、勢力之間現在的關係)。開寫時自動產生,每章寫完自動更新;分段和寫作會照著它,可以直接改。")
                    .foregroundStyle(.tertiary)
            }
            if !d.recap.isEmpty {
                Section("前情提要(自動濃縮的舊章節)") { Text(d.recap).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem {
                Button("儲存") {
                    let f: [String: Any] = ["title": title, "style": style, "world": world, "outline": outline,
                                            "spine": spine, "ledger": ledger, "rules": rules, "maps": maps, "shareKb": shareKb,
                                            "targetChapters": target, "chapterWords": words, "auto": auto,
                                            "adult": adult, "research": research, "researchHint": researchHint, "avoidOthers": avoidOthers,
                                            "randomize": randomize, "variation": variation]
                    Task { await model.act("儲存設定") { _ = try await $0.patch(model.id, f) } }
                }
                .disabled(!dirty)
            }
        }
        .onAppear(perform: sync)
        .onChange(of: d.status) { _, _ in if !dirty { sync() } }
        .onChange(of: d.ledger) { old, new in if ledger == old { ledger = new } }
        .onChange(of: d.rules) { old, new in if rules == old { rules = new } }
        .onChange(of: d.maps) { old, new in if maps == old { maps = new } }   // 每章寫完伏筆表會變,沒在改就跟著更新
    }

    func sync() {
        title = d.title; style = d.style; world = d.world; outline = d.outline; spine = d.spine; ledger = d.ledger; rules = d.rules; maps = d.maps; shareKb = d.shareKb ?? false
        target = d.targetChapters; words = d.chapterWords; auto = d.auto
        adult = d.adult; research = d.research; researchHint = d.researchHint; avoidOthers = d.avoidOthers; randomize = d.randomize; variation = d.variation
    }
}

// ───────────── 記憶與搜尋 ─────────────
struct MemoryView: View {
    @ObservedObject var model: NovelModel
    let d: NovelDetail
    @State private var q = ""
    @State private var hits: [SearchHit] = []
    @State private var searching = false
    @State private var webQ = ""
    @State private var showAdd = false
    @State private var addTopic = ""
    @State private var addText = ""

    func research() {
        let q = webQ.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        webQ = ""
        Task { await model.act("上網查") { try await $0.research(model.id, query: q) } }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("", text: $q, prompt: Hint("搜尋前面寫過的事:人名、物品、某句話…"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(search)
                    Button("搜尋", action: search).disabled(q.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if searching { ProgressView() }
                ForEach(hits) { h in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(h.kind)\(h.chapter > 0 ? " · 第 \(h.chapter) 章" : "") · \(String(format: "%.2f", h.score))")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(h.text).font(.callout).textSelection(.enabled)
                    }
                }
            } header: { Text("搜尋") } footer: {
                Text("同一套搜尋也是 AI 自己用的:每章動筆前,它會先列出要回頭確認的事,拿去查。").foregroundStyle(.tertiary)
            }
            Section {
                HStack {
                    TextField("", text: $webQ, prompt: Hint("上網查:例如「昭和時代 喫茶店 菜單」"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(research)
                    Button("上網查", action: research)
                        .disabled(webQ.trimmingCharacters(in: .whitespaces).isEmpty || d.job != nil)
                }
                DisclosureGroup("手動加一筆資料", isExpanded: $showAdd) {
                    TextField("", text: $addTopic, prompt: Hint("主題"))
                    LongField(text: $addText, hint: "內容:設定、參考段落、你想讓它知道的事", lines: 6, title: "知識庫內容")
                    Button("加入知識庫") {
                        let t = addTopic, x = addText
                        addTopic = ""; addText = ""
                        Task { await model.act("加入資料") { try await $0.addKnowledge(model.id, topic: t, text: x) } }
                    }
                    .disabled(addText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(d.knowledge) { k in
                    DisclosureGroup {
                        Text(k.text).font(.callout).textSelection(.enabled)
                        if !k.source.isEmpty {
                            Text(k.source).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                        }
                        if k.shared {
                            Text("這筆是「\(k.from)」查的,所有作品共用;刪掉的話其他作品也會看不到。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Button("刪除這筆", role: .destructive) {
                            Task { await model.act("刪除資料") { try await $0.deleteKnowledge(model.id, k.id) } }
                        }
                        .buttonStyle(.borderless)
                    } label: {
                        HStack {
                            Text(k.topic.isEmpty ? "資料" : k.topic)
                            Spacer()
                            Text(k.shared ? "共用" : (k.source == "手動" ? "手動" : (k.chapter > 0 ? "第 \(k.chapter) 章前查的" : "開寫前查的")))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("知識庫(\(d.knowledge.count) 筆)") } footer: {
                Text(d.research ? "知識庫是所有作品共用的:別部查過的這裡也搜得到,不會重查(一般作品看不到成人向作品查的)。它動筆前會自己判斷要不要上網查;你也可以自己查或手動加。"
                                : "這部作品關掉了「自己上網查資料」(設定與大綱裡可以打開),手動查和手動加照樣可以。")
                    .foregroundStyle(.tertiary)
            }
            if let j = d.job, !j.lookups.isEmpty {
                Section("正在查的") { ForEach(j.lookups, id: \.self) { Text($0).font(.callout) } }
            }
            ForEach(d.chapters.reversed()) { c in
                Section("第 \(c.idx) 章" + (c.title.isEmpty ? "" : " \(c.title)")) {
                    if !c.summary.isEmpty { Text(c.summary).font(.callout) }
                    if !c.lookups.isEmpty {
                        Text("動筆前查了:\n" + c.lookups).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    func search() {
        let text = q.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        Task {
            do { hits = try await model.store.api.search(model.id, text) } catch { model.error = error.localizedDescription }
            searching = false
        }
    }
}
