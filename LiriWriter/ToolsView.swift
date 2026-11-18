// ToolsView.swift — 分析報告、世界觀設定集、重寫章節(2026-11-13)
import SwiftUI

struct ToolsView: View {
    @ObservedObject var model: NovelModel
    let d: NovelDetail
    @State private var analyzeFocus = ""
    @State private var worldFocus = ""
    @State private var editingBible = false
    @State private var bibleDraft = ""

    var body: some View {
        Form {
            if !d.error.isEmpty && d.status != "error" {
                Section { Text("上次失敗:\(d.error)").font(.callout).foregroundStyle(.red) }
            }
            // ── 分析 ──
            Section {
                LongField(text: $analyzeFocus, hint: "特別想知道的(選填):例如「中段是不是太拖」「奏的性格有沒有走樣」", lines: 3, title: "想知道的")
                HStack {
                    Button(d.analysis.isEmpty ? "分析這部作品" : "重新分析") {
                        let f = analyzeFocus
                        Task { await model.act("分析") { try await $0.analyze(model.id, focus: f) } }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(d.job != nil || d.chapters.allSatisfy { $0.content.isEmpty })
                    if d.analysisAt > 0 { Text("上次:\(Self.date(d.analysisAt))").font(.caption).foregroundStyle(.secondary) }
                }
                if let j = d.job, j.phase.hasPrefix("分析") { LiveBlock(title: "分析中", text: j.live, phase: j.phase, lookups: []) }
                if !d.analysis.isEmpty {
                    Text(d.analysis).font(.callout).lineSpacing(4).textSelection(.enabled)
                }
            } header: { Text("分析") } footer: {
                Text("讀全書的摘要和原文樣本,寫一份編輯報告:結構節奏、角色一致性、文風壞習慣(附實際算出來的重複句和套話次數)、前後矛盾、跟你的設定比有沒有走樣、接下來的建議。")
                    .foregroundStyle(.tertiary)
            }

            // ── 世界觀設定集 ──
            Section {
                LongField(text: $worldFocus, hint: "這次想補充的(選填):例如「貴族爵位制度」「城市的地理」「這個國家的歷史」", lines: 3, title: "想補充的")
                HStack {
                    Button(d.worldBible.isEmpty ? "製作設定集" : "更新設定集") {
                        let f = worldFocus
                        Task { await model.act("製作設定集") { try await $0.worldbuild(model.id, focus: f) } }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(d.job != nil)
                    if !d.worldBible.isEmpty {
                        Button(editingBible ? "取消" : "自己改") {
                            if !editingBible { bibleDraft = d.worldBible }
                            editingBible.toggle()
                        }
                    }
                    if d.worldBibleAt > 0 { Text("上次:\(Self.date(d.worldBibleAt))").font(.caption).foregroundStyle(.secondary) }
                }
                if let j = d.job, j.phase.hasPrefix("世界觀") { LiveBlock(title: "整理中", text: j.live, phase: j.phase, lookups: []) }
                if editingBible {
                    Editor(text: $bibleDraft, title: "世界觀").editorHeight(320).font(.body)
                    Button("儲存設定集") {
                        let t = bibleDraft
                        Task { await model.act("儲存設定集") { _ = try await $0.patch(model.id, ["worldBible": t]) }
                               editingBible = false }
                    }
                } else if !d.worldBible.isEmpty {
                    Text(d.worldBible).font(.callout).lineSpacing(4).textSelection(.enabled)
                }
            } header: { Text("世界觀設定集") } footer: {
                Text("根據你的設定和已經寫好的內容,整理並補完地理、歷史、勢力、制度、日常生活、用語和伏筆;原文寫過的標(原文),新補的標(新增)。設定集會存進記憶,之後寫作回頭查時搜得到。再按一次會在上一版的基礎上補充。手動改過的版本要再按「更新設定集」才會存進記憶。")
                    .foregroundStyle(.tertiary)
            }

            // ── 重寫 ──
            Section {
                Button("重寫章節…") { model.rewriteTarget = d.chapters.first { $0.status == "done" } }
                    .disabled(d.job != nil || !d.chapters.contains { $0.status == "done" })
            } header: { Text("重寫") } footer: {
                Text("也可以在「正文」每章標題右邊的「⋯」選「重寫…」。可以只改一章,也可以從某章改到最後;第一次重寫會留原稿,隨時能還原。")
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $model.rewriteTarget) { c in RewriteSheet(model: model, d: d, chapter: c) }
    }

    static func date(_ ms: Int64) -> String {
        let f = DateFormatter(); f.dateFormat = "M/d HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}

struct RewriteSheet: View {
    @ObservedObject var model: NovelModel
    let d: NovelDetail
    let chapter: NovelChapter
    @Environment(\.dismiss) var dismiss
    @State private var from = 1
    @State private var to = 1
    @State private var instruction = ""

    private var presets: [String] {
        var p = ["去掉翻譯腔和多餘的副詞,句子更短更口語;情節不變",
                 "精簡囉嗦的地方,同一個動作只寫一次;情節不變",
                 "多加對話,少一點旁白說明",
                 "改成第三人稱",
                 "調性改得溫暖、甜一點,兩人互相疼愛",
                 "節奏加快,場景之間直接跳,不要每個過程都交代"]
        if d.adult { p.append("親密場面照成人向的寫法,寫得更直接具體") }
        return p
    }
    private var doneIdx: [Int] { d.chapters.filter { $0.status == "done" }.map(\.idx) }

    var body: some View {
        NavigationStack {
            Form {
                Section("範圍") {
                    Picker("從", selection: $from) { ForEach(doneIdx, id: \.self) { Text("第 \($0) 章").tag($0) } }
                    Picker("到", selection: $to) { ForEach(doneIdx.filter { $0 >= from }, id: \.self) { Text("第 \($0) 章").tag($0) } }
                    let n = doneIdx.filter { $0 >= from && $0 <= to }.count
                    Text(n == 1 ? "重寫 1 章" : "重寫 \(n) 章,一章一章來,可以隨時按停止").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Editor(text: $instruction, title: "重寫指示").editorHeight(100).font(.body)
                    ForEach(presets, id: \.self) { p in
                        Button(p) { instruction = instruction.isEmpty ? p : instruction + ";" + p }
                            .font(.callout)
                    }
                } header: { Text("要怎麼改") } footer: {
                    Text("沒說要改的部分(發生的事、順序、人名)都會保留。寫作規則(你的設定、「我」的性格、文風)照樣套用。")
                        .foregroundStyle(.tertiary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("重寫")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("開始重寫") {
                        let (f, t, ins) = (from, max(from, to), instruction)
                        Task { await model.act("重寫") { try await $0.rewrite(model.id, from: f, to: t, instruction: ins) } }
                        dismiss()
                    }
                    .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { from = chapter.idx; to = chapter.idx }
            .onChange(of: from) { _, v in if to < v { to = v } }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 600)
        #endif
    }
}
