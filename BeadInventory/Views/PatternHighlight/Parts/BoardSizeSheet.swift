//
//  BoardSizeSheet.swift
//  BeadInventory
//
//  「自定义尺寸」——自己填板子的列数和行数
//
//  原来挑板子只有六个常见规格（50×50 到 104×104），可桌上那块板不一定在里面：
//  长方形的板、几块并起来当一整块用的拼台、买到的杂牌板，格数都是别的数。选不到
//  自己那块的人只能挑一个「差不多大」的，然后板上排出来的位置跟手上的孔对不上 ——
//  多零件模式的整块布局、投影仪投出来的每一格，全建立在这个数上。
//
//  所以菜单里除了常见规格，还有「自定义…」：板子横着多少个孔填列数、竖着多少个填行数。
//  填过的板记着（最多三块，见 `BeadBoardSize.remember`），下次在菜单里直接点。
//
//  ## 为什么只在按「确定」时才管数字合不合规
//
//  边打边把数字夹回合法范围，会变成「输 1 出 5」：想打 100 的人第一下打的就是 1。
//  所以打字过程中一个字都不改，只把那句范围提示摆在下面，「确定」先按不动 ——
//  用户看得见自己打了什么，也看得见还差什么。
//

import SwiftUI

// MARK: - 菜单里那一份「挑板子格数」

/// 常见规格 + 自己填过的 + 「自定义…」。多零件模式的两个菜单和投影仪校准页共用这一份，
/// 三处列出来的板必须是同一批 —— 用户在其中一处填的板，另外两处点不到就等于没记住。
///
/// **只能放在 `Menu { }` 里**：body 返回的是一串平铺的按钮，塞进 VStack 会画出一堆散按钮。
///
/// 分组用 `Divider` 不用 `Section`：这份内容有一个调用方（「全部重排成」）本身已经
/// 包在一个 Section 里了，菜单里 Section 套 Section 各版本渲染不一致 ——
/// 轻则丢标题，重则整组不显示，而「最近使用」不显示 = 用户以为 App 把他填的板忘了。
struct BoardSizePicker: View {
    /// 已经选中的那个（打勾用）。没有就传 nil。
    var current: BeadBoardSize?
    /// 自己填过的那几块（`@AppStorage` 里那行字符串解出来的）
    var recents: [BeadBoardSize]
    let onPick: (BeadBoardSize) -> Void
    let onCustom: () -> Void

    var body: some View {
        ForEach(BeadBoardSize.presets) { size in
            button(size)
        }
        if !recents.isEmpty {
            Divider()
            ForEach(recents) { size in
                button(size)
            }
        }
        Divider()
        Button {
            onCustom()
        } label: {
            Label("自定义…", systemImage: "square.dashed")
        }
    }

    private func button(_ size: BeadBoardSize) -> some View {
        Button {
            onPick(size)
        } label: {
            if size == current {
                Label(size.label, systemImage: "checkmark")
            } else {
                Text(size.label)
            }
        }
    }
}

// MARK: - 填格数那一屏

struct BoardSizeCustomSheet: View {
    /// 打开时先填上现在这块板的格数 —— 大多数人是来改一个数的（100×100 想改成 100×50），
    /// 不是从零填两个。
    let initial: BeadBoardSize
    /// **在 `dismiss()` 之前调用。** 要接弹窗的调用方得自己把动作推到 `onDismiss`，
    /// 在这儿挂弹窗会被正在关闭的 sheet 吞掉（见 `PartsBoardStepView.applyCustomSize`）。
    let onCommit: (BeadBoardSize) -> Void

    @Environment(\.dismiss) private var dismiss

    /// 存成字符串不是 Int：`Int` 绑定在清空输入框那一下会退回 0，屏幕上凭空冒出个「0」，
    /// 而用户只是想把 50 删掉重打。
    @State private var colsText: String
    @State private var rowsText: String
    @FocusState private var focus: Field?

    private enum Field { case cols, rows }

    init(initial: BeadBoardSize, onCommit: @escaping (BeadBoardSize) -> Void) {
        self.initial = initial
        self.onCommit = onCommit
        _colsText = State(initialValue: "\(initial.cols)")
        _rowsText = State(initialValue: "\(initial.rows)")
    }

    /// 现在这两个框凑得出一块板吗。凑不出时不猜、不夹 —— 见文件头。
    private var size: BeadBoardSize? {
        guard let cols = Int(colsText.trimmingCharacters(in: .whitespaces)),
              let rows = Int(rowsText.trimmingCharacters(in: .whitespaces)) else { return nil }
        let size = BeadBoardSize(cols: cols, rows: rows)
        return size.isValidCustom ? size : nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    fields
                    summary
                }
                .padding()
            }
            .background(Theme.ColorToken.Surface.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("自定义尺寸")
            .navigationBarTitleDisplayMode(.inline)
            // 半屏：统共两个框加两行字。而且底下那块板是用户正在拼的东西，
            // 不该被整个盖掉 —— 他填的数正是从那儿数出来的。
            .presentationDetents([.medium, .large])
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                // 数字键盘没有回车键，所以「填完了」这一下只能靠按钮。放在导航栏：
                // 键盘弹起来时它照样在眼前（键盘上方那条自定义栏在 sheet 里不可靠）。
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确定") { commit() }
                        .fontWeight(.semibold)
                        .disabled(size == nil)
                }
            }
        }
    }

    /// 点进框里就把原来那个数整个选中，打第一个数字就替换掉。
    ///
    /// 框里预填的是现在这块板（多半是 50），而人来这儿就是要换成别的数。不选中的话，
    /// 光标停在数字中间，打「60」得到的是「6050」—— 他得先按两下退格，
    /// 而数字键盘上退格在右下角，跟数字键长得不一样，找一下才看得见。
    ///
    /// 直接设选区，不用 `selectAll(_:)`：后者是编辑菜单的那个动作，会连带弹出
    /// 「拷贝 / 粘贴」气泡盖在框上 —— 而这里要的只是选中。
    private var fields: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            field(title: String(localized: "列数"), text: $colsText, field: .cols)
            Text("×")
                .font(.title3)
                .foregroundColor(Theme.ColorToken.Text.tertiary)
                .padding(.top, 34)
            field(title: String(localized: "行数"), text: $rowsText, field: .rows)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UITextField.textDidBeginEditingNotification)) { note in
            guard let field = note.object as? UITextField else { return }
            // 系统在这个通知之后还会自己摆一次光标，同步选中会被它盖掉。
            DispatchQueue.main.async {
                field.selectedTextRange = field.textRange(from: field.beginningOfDocument,
                                                          to: field.endOfDocument)
            }
        }
    }

    private func field(title: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(.caption)
                .foregroundColor(Theme.ColorToken.Text.secondary)
            TextField("", text: text)
                .keyboardType(.asciiCapableNumberPad)
                .font(.title2.monospacedDigit())
                .multilineTextAlignment(.center)
                .focused($focus, equals: field)
                .padding(.vertical, Theme.Spacing.sm)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .fill(Theme.ColorToken.Surface.elevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .stroke(focus == field
                                ? Theme.ColorToken.Morandi.mauve
                                : Theme.ColorToken.Border.default,
                                lineWidth: focus == field ? 2 : 1)
                )
        }
    }

    /// 填对了就把这块板换算成「一共多少格」。拼豆的人认颗数 ——
    /// 100 × 50 是多大，看到 5000 格才有实感。
    @ViewBuilder
    private var summary: some View {
        if let size {
            Text("\(size.label) · \(size.cols * size.rows) 格")
                .font(.subheadline.monospacedDigit())
                .foregroundColor(Theme.ColorToken.Text.primary)
        } else {
            Text("列数和行数需在 \(BeadBoardSize.customRange.lowerBound) - \(BeadBoardSize.customRange.upperBound) 之间")
                .font(.subheadline)
                .foregroundColor(Theme.ColorToken.Status.warning)
        }
    }

    private func commit() {
        guard let size else { return }
        onCommit(size)
        dismiss()
    }
}
