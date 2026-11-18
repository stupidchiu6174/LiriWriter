// ImportNovelView.swift — 匯入現有小說(2026-11-12)
//
// 選一個 .txt / .md 檔或直接貼上全文 → 服務端切章、每章做摘要、整理出書名/文風/世界/角色卡 → 從下一章接著寫。
import SwiftUI
import UniformTypeIdentifiers

struct ImportNovelView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    var onCreated: (Int64) -> Void

    @State private var text = ""
    @State private var fileName = ""
    @State private var title = ""
    @State private var direction = ""
    @State private var povName = ""
    @State private var pov = ""
    @State private var more = 10
    @State private var autoWords = true
    @State private var words = 3000
    @State private var auto = false
    @State private var adult = false
    @State private var research = false
    @State private var picking = false
    @State private var busy = false
    @State private var error: String?

    /// 跟服務端同一條規則:行首的「第X章」「序章」「Chapter 1」才算章節標題
    private var chapterCount: Int {
        let pattern = #"(?m)^[ \t　]*(第[0-9０-９一二三四五六七八九十百千零〇兩]+[章回節話卷部集篇]|序章|序幕|楔子|引子|終章|尾聲|後記|番外|Chapter\s*\d+|CHAPTER\s*\d+|Prologue|Epilogue)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { picking = true } label: {
                        Label(fileName.isEmpty ? "選擇檔案(.txt / .md)" : fileName, systemImage: "doc.text")
                    }
                    Editor(text: $text, title: "小說內容", hint: "")
                        .font(.body)
                        .editorHeight(220)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("或是把小說全文貼在這裡")
                                    .foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                    if !text.isEmpty {
                        let n = chapterCount
                        Text(n > 0 ? "\(text.count) 字,找到 \(n) 個章節標題" : "\(text.count) 字,沒找到「第X章」這類標題,會照段落自動切成每章約 \(autoWords ? 3000 : words) 字")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("小說內容") } footer: {
                    Text("行首寫「第一章」「第1章」「序章」「Chapter 1」的地方會被當成一章的開頭。原文一字不改,存成已經寫好的章節。")
                        .foregroundStyle(.tertiary)
                }

                Section {
                    TextField("", text: $title, prompt: Hint("書名(選填,不填它會從內容找或取一個)"))
                        .labelsHidden().multilineTextAlignment(.leading)
                    LongField(text: $direction, hint: "接下來想怎麼寫(選填):\n例如:兩人和好、多寫日常、加一個新的對手", lines: 4, title: "接下來想怎麼寫")
                } header: { Text("接著寫") } footer: {
                    Text("「接下來想怎麼寫」會放進作品的主題裡,寫作時最優先照著做。")
                        .foregroundStyle(.tertiary)
                }

                Section {
                    TextField("", text: $povName, prompt: Hint("「我」的名字(選填,第一人稱的小說它會自己認)"))
                        .labelsHidden().multilineTextAlignment(.leading)
                    LongField(text: $pov, hint: "「我」是什麼樣的人(選填,不填就照原文歸納)", lines: 3, title: "「我」")
                } header: { Text("我(第一人稱主角)") }

                Section("篇幅") {
                    Stepper("匯入之後再寫 \(more) 章", value: $more, in: 0...100)
                    Toggle("每章字數照原文的平均", isOn: $autoWords)
                    if !autoWords {
                        Stepper("每章約 \(words) 字", value: $words, in: 900...6000, step: 300)
                    }
                }

                Section {
                    Toggle("匯入完就一路寫到完", isOn: $auto)
                    Toggle("自己上網查資料", isOn: $research)
                    Toggle("成人向", isOn: $adult)
                } footer: {
                    Text("匯入時它會一章一章讀、做摘要記住,再整理出角色卡和文風;長篇要花一些時間,進度會顯示在作品頁。整理好的角色卡可以再改。")
                        .foregroundStyle(.tertiary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle("匯入小說")
            .fileImporter(isPresented: $picking, allowedContentTypes: [.plainText, .text, UTType(filenameExtension: "md") ?? .plainText]) { result in
                switch result {
                case .success(let url): load(url)
                case .failure(let e): error = "打不開檔案:\(e.localizedDescription)"
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "上傳中…" : "匯入") {
                        busy = true; error = nil
                        Task {
                            do {
                                let d = try await store.api.importNovel(text: text, title: title, direction: direction,
                                                                         povName: povName, pov: pov, more: more,
                                                                         words: autoWords ? 0 : words, auto: auto,
                                                                         adult: adult, research: research)
                                await store.refresh()
                                onCreated(d.id)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                            busy = false
                        }
                    }
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).count < 200)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 680)
        #endif
    }

    /// 讀檔:UTF-8 優先,再試 Big5、GB18030、UTF-16(舊的中文 txt 常不是 UTF-8)
    private func load(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { error = "讀不到這個檔案"; return }
        let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)))
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        for enc in [String.Encoding.utf8, big5, gb, .utf16] {
            if let s = String(data: data, encoding: enc), !s.isEmpty {
                text = s
                fileName = url.lastPathComponent
                if title.isEmpty { title = url.deletingPathExtension().lastPathComponent }
                error = nil
                return
            }
        }
        error = "看不懂這個檔案的編碼,請另存成 UTF-8 的 .txt 再試"
    }
}
