// TextHelpers.swift — 手機上的選取與編輯(2026-11-14)
//
// 1. SwiftUI 的 Text + .textSelection 在 iPhone 上只能「整塊複製」,選不了一段;正文改用 UITextView(唯讀、可選取)。
// 2. Form 裡的 TextEditor 在 iPhone 上用 minHeight 會跟著內容一直長高,打字時 Form 重新排版、畫面亂跳;
//    手機上改成固定高度、在框裡面捲。Mac 照舊。
import SwiftUI

#if os(iOS)
import UIKit

/// 唯讀、可以長按選一段字的正文(高度跟著內容,捲動交給外層 ScrollView)
struct SelectableText: UIViewRepresentable {
    let text: String
    var fontSize: CGFloat = 17
    var lineSpacing: CGFloat = 7
    var color: UIColor = .label

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false
        v.isSelectable = true
        v.isScrollEnabled = false
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.dataDetectorTypes = []
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        // 字沒變就不要重設:重設會把使用者正在選的範圍清掉(寫作中每 2 秒會刷新一次畫面)
        if context.coordinator.last == text, context.coordinator.lastColor == color { return }
        context.coordinator.last = text
        context.coordinator.lastColor = color
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineSpacing
        v.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize), .paragraphStyle: p, .foregroundColor: color])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let w = proposal.width ?? UIScreen.main.bounds.width
        let size = uiView.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        return CGSize(width: w, height: ceil(size.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var last: String?; var lastColor: UIColor? }
}
#endif

/// 正文:iPhone 用可選取一段的 UITextView,Mac 用原本的 Text(Mac 本來就能選一段)
struct ProseText: View {
    let text: String
    var secondary = false
    var body: some View {
        #if os(iOS)
        SelectableText(text: text, color: secondary ? .secondaryLabel : .label)
        #else
        Text(text).font(.system(size: 17)).lineSpacing(7)
            .foregroundStyle(secondary ? .secondary : .primary)
            .textSelection(.enabled)
        #endif
    }
}

extension View {
    /// 編輯框高度:Mac 用最小高度(跟著長),iPhone 用固定高度(框裡面捲,打字時畫面不跳)
    func editorHeight(_ h: CGFloat) -> some View {
        #if os(iOS)
        frame(height: h)
        #else
        frame(minHeight: h)
        #endif
    }
}

/// 多行輸入框(2026-11-14)。
/// iPhone:`TextField(axis: .vertical)` 在 Form 裡會邊打邊長高,超過 lineLimit 又改在框內捲,
/// Form 跟著重排、還會把游標那行捲到奇怪的位置 —— 打字時畫面亂跳、字被推到框底或切掉上半。
/// 手機上改成固定高度的 TextEditor(高度不再變,捲動只在框裡),Mac 照舊用會長高的 TextField。
struct LongField: View {
    @Binding var text: String
    let hint: String
    var lines: Int = 4
    var title: String = "編輯"

    var body: some View {
        #if os(iOS)
        TapToEdit(text: $text, hint: hint, title: title)
            .frame(height: CGFloat(lines) * 22 + 16)
        #else
        TextField("", text: $text, prompt: Hint(hint), axis: .vertical)
            .lineLimit(1...max(lines, 2))
            .labelsHidden().multilineTextAlignment(.leading)
        #endif
    }
}

#if os(iOS)
/// 注音、倉頡這類組字輸入法用的編輯框(2026-11-14)。
///
/// 病史:SwiftUI 的 TextEditor／TextField 在組字中(注音還有底線、還沒選字)每按一個鍵就把
/// 半成品寫回 binding,畫面重繪時又把字設回 UITextView —— 組字狀態被打斷、游標和捲動位置被重設,
/// 字被推到框底、上面空一大片,或第一行被切掉。固定高度也救不了,因為問題不在高度。
/// 這裡:組字中不回寫 binding、外面的字跟框裡一樣就不重設;捲動只在框裡,不讓系統替它加鍵盤留白。
struct IMETextView: UIViewRepresentable {
    @Binding var text: String
    var autoFocus = false

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.delegate = context.coordinator
        v.font = UIFont.preferredFont(forTextStyle: .body)
        v.adjustsFontForContentSizeCategory = true
        v.backgroundColor = .clear
        v.isScrollEnabled = true
        v.contentInsetAdjustmentBehavior = .never
        v.automaticallyAdjustsScrollIndicatorInsets = false
        v.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        v.textContainer.lineFragmentPadding = 5
        v.text = text
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        if autoFocus { DispatchQueue.main.async { v.becomeFirstResponder() } }
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        context.coordinator.parent = self
        // 組字中絕對不碰;字一樣也不碰(重設會把游標丟到最後、捲動歸零)
        guard v.markedTextRange == nil, v.text != text else { return }
        let sel = v.selectedRange
        v.text = text
        let n = (text as NSString).length
        v.selectedRange = NSRange(location: min(sel.location, n), length: 0)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: IMETextView
        init(_ p: IMETextView) { parent = p }
        func textViewDidChange(_ v: UITextView) {
            // 選字完成(沒有 markedText)才回寫;組字中的半成品不送出去
            guard v.markedTextRange == nil else { return }
            if parent.text != v.text { parent.text = v.text }
        }
        func textViewDidEndEditing(_ v: UITextView) {
            if parent.text != v.text { parent.text = v.text }
        }
    }
}
#endif

/// 多行編輯框。高度由外面的 editorHeight / frame 決定。
/// iPhone(2026-11-14):Form 裡直接打字,每打完一個字 Form 重排、把編輯中的那格捲到別處 —— 畫面一直跳。
/// 改成框裡只顯示內容,點一下開全螢幕編輯頁(外面沒有 Form,不會被捲)。Mac 照舊直接打。
struct Editor: View {
    @Binding var text: String
    var title: String = "編輯"
    var hint: String = "點一下開始輸入"
    var body: some View {
        #if os(iOS)
        TapToEdit(text: $text, hint: hint, title: title)
        #else
        TextEditor(text: $text).font(.body)
        #endif
    }
}

#if os(iOS)
/// 表單裡的預覽:點了開 FullTextEditor
struct TapToEdit: View {
    @Binding var text: String
    let hint: String
    let title: String
    @State private var editing = false

    var body: some View {
        Text(text.isEmpty ? hint : String(text.prefix(1500)))   // 整本小說貼進來時,預覽只排開頭
            .font(.body)
            .foregroundStyle(text.isEmpty ? .tertiary : .primary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.vertical, 8)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { editing = true }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "square.and.pencil").font(.caption).foregroundStyle(.tint)
                    .padding(4)
            }
            .sheet(isPresented: $editing) { FullTextEditor(text: $text, title: title) }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("點兩下編輯")
    }
}

/// 全螢幕編輯頁:只有一個 UITextView,鍵盤的留白交給 SwiftUI 的 safe area
struct FullTextEditor: View {
    @Binding var text: String
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            IMETextView(text: $text, autoFocus: true)
                .padding(.horizontal, 12)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            dismiss()
                        }
                    }
                }
        }
        .presentationDragIndicator(.visible)
    }
}
#endif
