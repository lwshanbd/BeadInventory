//
//  PatternCalibrationView.swift
//  BeadInventory
//
//  拼图模式 - 网格标定页（默认 2 角矩形模式 + 放大镜 + ROI 自动检测）
//

import SwiftUI

/// 拼图模式诊断日志，仅 DEBUG 编译输出。
@inline(__always)
private func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}

struct PatternCalibrationView: View {
    let project: ProjectRecord
    var onComplete: (() -> Void)? = nil   // 由 parent 控制导航到高亮页

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var inventoryManager: InventoryManager

    @State private var corners: GridCorners = .initialQuad
    @State private var rows: Int = 29
    @State private var cols: Int = 29
    /// 是否任一行/列 TextField 当前有焦点。两个 TextField 都绑同一个
    /// `.focused($fieldsFocused)`，焦点在它们之间切换时 Bool 保持 true，
    /// 行末的收键盘按钮（`.opacity` + `.allowsHitTesting` 由 fieldsFocused 驱动）
    /// 因此不会在切换瞬间闪烁。
    /// 历史：先前试过 enum FocusState + `.toolbar(.keyboard)` accessory，
    /// sheet + 多 TextField 焦点切换场景下 SwiftUI 会丢 accessory，改走
    /// 纯 inline UI 路径。
    @FocusState private var fieldsFocused: Bool
    @State private var rectMode: Bool = true             // 默认矩形（2 角）模式
    /// 锁定网格：所有红角/网格整体拖手势被禁用，1 指拖一律走"平移图片"。
    /// 默认 false（可以正常调网格）。放大查看图片细节时点锁切到 true。
    @State private var gridLocked: Bool = false
    @State private var detectionRunning = false
    @State private var detectionConfidence: Double? = nil
    @State private var saving = false

    // 图片缩放/平移状态。pinch 改 scale，缩放后单指空白处拖可平移。
    // 红角点 + 网格内拖（GridBodyDragHandle）的 1 指手势优先级更高，
    // 在它们的热区里 1 指 drag 不会平移视图。
    @State private var viewScale: CGFloat = 1.0
    @State private var lastViewScale: CGFloat = 1.0
    @State private var viewOffset: CGSize = .zero
    @State private var lastViewOffset: CGSize = .zero
    @State private var savingPhase: String? = nil
    @State private var savingStartTime: Date? = nil
    @State private var savingDisplayElapsed: Int = 0
    private let savingTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    /// 当前正在拖动的角点（用于显示放大镜）。nil = 没在拖。
    @State private var draggingCorner: CornerLabel? = nil
    /// 拖动点在 displayRect 内的屏幕坐标
    @State private var draggingScreenPoint: CGPoint = .zero

    /// thumbnail 改成异步加载（v2.0.x 之后 ProjectRecord 不再持有 thumbnail Data）。
    @State private var image: UIImage?

    private var savingLabelText: String {
        guard let phase = savingPhase else { return "开始标定" }
        if savingDisplayElapsed > 0 {
            return "\(phase) (\(savingDisplayElapsed)s)"
        }
        return phase
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                imageCanvas
                confidenceBanner
                toolbar
            }
            .navigationTitle("标定网格")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle(isOn: $rectMode) {
                        Text(rectMode ? "矩形" : "四边形")
                            .font(.footnote)
                    }
                    .toggleStyle(.button)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        gridLocked.toggle()
                    } label: {
                        Image(systemName: gridLocked ? "lock.fill" : "lock.open")
                            .foregroundStyle(gridLocked ? Theme.ColorToken.Status.warning : Color.secondary)
                    }
                    .accessibilityLabel(gridLocked ? "解锁网格" : "锁定网格（仅平移图片）")
                }
            }
            .task {
                // 先把 thumbnail 和 patternGrid 从 SwiftData 取出来
                let id = project.id
                let loader = inventoryManager.imageLoader
                let thumbData = await loader?.thumbnail(for: id)
                let existing = await loader?.patternGrid(for: id)
                guard !Task.isCancelled else { return }
                self.image = thumbData.flatMap { UIImage(data: $0) }
                if let existing = existing {
                    corners = existing.corners
                    rows = existing.rows
                    cols = existing.cols
                } else {
                    runAutoDetect(restrictToCurrentROI: false)
                }
            }
            .onChange(of: rectMode) { _, newValue in
                if newValue { snapCornersToRect() }
            }
        }
    }

    // MARK: - Image canvas

    @ViewBuilder
    private var imageCanvas: some View {
        if let img = image {
            GeometryReader { geo in
                let displayRect = aspectFitRect(imageSize: img.size, in: geo.size)
                ZStack(alignment: .topLeading) {
                    // 图 + 网格线 + 整体拖手势 + 4 角点合并成一个 ZStack，整体 scale/offset。
                    // 这样所有元素一起放大；放大时 corners 的坐标继续在原 displayRect 系内
                    // 计算，DragGesture.value.location 来自子视图本地坐标，仍然是 displayRect 系，
                    // 所以现有 corner / body 拖动逻辑不需要改。
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.05)
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)

                        CalibrationGridOverlay(
                            corners: corners,
                            rows: rows, cols: cols,
                            displayRect: displayRect
                        )

                        GridBodyDragHandle(
                            corners: $corners,
                            displayRect: displayRect
                        )
                        .allowsHitTesting(!gridLocked)

                        ForEach(visibleHandles(), id: \.self) { label in
                            CornerHandle(
                                label: label,
                                corners: $corners,
                                displayRect: displayRect,
                                rectMode: rectMode,
                                draggingCorner: $draggingCorner,
                                draggingScreenPoint: $draggingScreenPoint
                            )
                            .allowsHitTesting(!gridLocked)
                            .opacity(gridLocked ? 0.4 : 1.0)   // 锁定时角点变淡作为视觉提示
                        }
                    }
                    .scaleEffect(viewScale, anchor: .center)
                    .offset(viewOffset)
                    .gesture(
                        SimultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    viewScale = max(1.0, min(5.0, lastViewScale * value))
                                }
                                .onEnded { _ in lastViewScale = viewScale },
                            DragGesture(minimumDistance: 10)
                                .onChanged { value in
                                    // 只在已放大时才允许平移；否则忽略（让 GridBodyDragHandle
                                    // 在 1x 时仍然能用整体拖网格的手势）
                                    guard viewScale > 1.05 else { return }
                                    viewOffset = CGSize(
                                        width: lastViewOffset.width + value.translation.width,
                                        height: lastViewOffset.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in lastViewOffset = viewOffset }
                        )
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            if viewScale > 1.05 {
                                viewScale = 1.0; lastViewScale = 1.0
                                viewOffset = .zero; lastViewOffset = .zero
                            } else {
                                viewScale = 2.5; lastViewScale = 2.5
                            }
                        }
                    }

                    // 进度提示 + 放大镜不参与缩放（保持屏幕固定大小 & 位置）
                    if detectionRunning {
                        Color.black.opacity(0.3)
                            .allowsHitTesting(false)
                        ProgressView("自动检测中...")
                            .padding()
                            .background(.regularMaterial)
                            .cornerRadius(Theme.Radius.sm)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                            .allowsHitTesting(false)
                    }

                    if let label = draggingCorner {
                        LoupeView(
                            image: img,
                            imageCenter: imagePoint(for: label, displayRect: displayRect, image: img)
                        )
                        .position(loupePosition(for: draggingScreenPoint, in: geo.size))
                        .allowsHitTesting(false)
                    }
                }
            }
            .clipped()
        } else {
            Text("项目无图片")
                .foregroundStyle(Theme.ColorToken.Text.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var confidenceBanner: some View {
        if let conf = detectionConfidence {
            HStack {
                Image(systemName: conf >= 0.7 ? "checkmark.circle.fill" :
                      conf >= 0.5 ? "info.circle.fill" : "exclamationmark.triangle.fill")
                Text(conf >= 0.7 ? "网格识别成功，请检查是否对齐" :
                     conf >= 0.5 ? "请确认网格对齐，必要时手动微调" :
                     "未能可靠识别。先把矩形对到图纸边缘，再点「区域内检测」")
                    .font(.footnote)
                Spacer()
            }
            .padding(8)
            .background(conf >= 0.7 ? Theme.ColorToken.Status.success.opacity(0.15) :
                        conf >= 0.5 ? Theme.ColorToken.Status.info.opacity(0.15) :
                        Theme.ColorToken.Status.warning.opacity(0.15))
        }
    }

    private var toolbar: some View {
        VStack(spacing: 12) {
            // 行列数（用户可直接修改；后续 "对齐网格" 会用这两个值）
            // HStack 末尾常驻 44×44 的收键盘按钮（HIG tap target），不用 `if`
            // 是为了避免行宽在聚焦/失焦时跳变；编辑时 opacity + allowsHitTesting
            // 由 fieldsFocused 翻成可见可点。不走 .toolbar(.keyboard) 的背景见
            // fieldsFocused 上方注释。
            HStack(spacing: 16) {
                stepperCell(title: "行", value: $rows)
                stepperCell(title: "列", value: $cols)
                Button {
                    fieldsFocused = false
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .opacity(fieldsFocused ? 1 : 0)
                .allowsHitTesting(fieldsFocused)
                .accessibilityLabel("收起键盘")
                .accessibilityHidden(!fieldsFocused)
            }
            .animation(.easeInOut(duration: 0.15), value: fieldsFocused)
            // 结束编辑（收键盘/失焦）时把行列夹回 [2,300]，补上 onChange 里
            // 故意不夹的下界——让用户打字途中可以自由出现瞬时的 "1"。
            .onChange(of: fieldsFocused) { _, focused in
                if !focused { normalizeRowsCols() }
            }

            // 检测按钮 + 提示
            VStack(spacing: 6) {
                Button {
                    runSnapToROI()
                } label: {
                    Label("按行列定位网格", systemImage: "viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .disabled(detectionRunning || image == nil)
                .buttonStyle(.bordered)

                Text("先把矩形大致框住网格区域，输好行列数，点这个按钮算法会精确对齐 4 个角")
                    .font(.caption2)
                    .foregroundStyle(Theme.ColorToken.Text.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                saveAndContinue()
            } label: {
                Label(savingLabelText,
                      systemImage: saving ? "hourglass" : "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(saving || image == nil)
            .onReceive(savingTimer) { _ in
                if let start = savingStartTime {
                    savingDisplayElapsed = Int(Date().timeIntervalSince(start))
                }
            }
        }
        .padding()
        .background(.regularMaterial)
    }

    // MARK: - Logic

    private func visibleHandles() -> [CornerLabel] {
        rectMode ? [.tl, .br] : CornerLabel.allCases
    }

    /// 把 4 角对齐成矩形（取 TL 和 BR 决定的轴对齐矩形）
    private func snapCornersToRect() {
        let tlx = min(corners.topLeft.x, corners.bottomLeft.x, corners.topRight.x, corners.bottomRight.x)
        let tly = min(corners.topLeft.y, corners.topRight.y, corners.bottomLeft.y, corners.bottomRight.y)
        let brx = max(corners.topLeft.x, corners.bottomLeft.x, corners.topRight.x, corners.bottomRight.x)
        let bry = max(corners.topLeft.y, corners.topRight.y, corners.bottomLeft.y, corners.bottomRight.y)
        corners = GridCorners(
            topLeft: CGPoint(x: tlx, y: tly),
            topRight: CGPoint(x: brx, y: tly),
            bottomLeft: CGPoint(x: tlx, y: bry),
            bottomRight: CGPoint(x: brx, y: bry)
        )
    }

    /// 行/列合法范围。下界 2（再小的网格没意义），上界 300。
    private static let rowsColsRange = 2...300

    /// 把 rows/cols 夹回合法范围。只在「结束编辑」（收键盘/失焦）和「消费前」
    /// 调用——不要在 TextField 每次按键时夹下界，否则输 "1" 会被顶成 "2"
    /// （详见 stepperCell 内 onChange 注释）。
    private func normalizeRowsCols() {
        let r = Self.rowsColsRange
        rows = min(max(rows, r.lowerBound), r.upperBound)
        cols = min(max(cols, r.lowerBound), r.upperBound)
    }

    /// 行/列输入单元：TextField 可直接打字 + 旁边 +/- 微调
    @ViewBuilder
    private func stepperCell(title: String, value: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.ColorToken.Text.secondary)
            Button {
                if value.wrappedValue > Self.rowsColsRange.lowerBound { value.wrappedValue -= 1 }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)

            TextField("", value: value, format: .number)
                .keyboardType(.numberPad)
                .focused($fieldsFocused)
                .multilineTextAlignment(.center)
                .font(.title3.monospacedDigit().bold())
                .frame(minWidth: 50, maxWidth: 70)
                .padding(.vertical, 4)
                .background(Theme.ColorToken.Surface.elevated)
                .cornerRadius(Theme.Radius.sm)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .stroke(Theme.ColorToken.Border.default, lineWidth: 1)
                )
                .onChange(of: value.wrappedValue) { _, newValue in
                    // 打字途中只夹「上界」：输到第 4 位超 300 时回拉，不影响
                    // 正常输入（建到 ≤300 的目标值中途不会越界）。
                    // 「下界」(最小 2) 绝不在每次按键时夹——否则用户清空后想
                    // 输 "1x"（如 12/19）时，中途出现的瞬时值 "1" 会被立刻
                    // 顶成 "2"，表现为「输 1 出 2」。下界在结束编辑（收键盘/
                    // 失焦）时由 normalizeRowsCols() 统一补齐，消费处亦兜底。
                    if newValue > Self.rowsColsRange.upperBound {
                        value.wrappedValue = Self.rowsColsRange.upperBound
                    }
                }

            Button {
                if value.wrappedValue < Self.rowsColsRange.upperBound { value.wrappedValue += 1 }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(Theme.Radius.sm)
    }

    /// 按用户输入的 rows/cols + 当前矩形（ROI）反推最佳 corners。
    /// 这是新的约束拟合算法：在 Canny 边缘投影上搜索使 rows+1 / cols+1
    /// 条等距线得分最高的 (offset, period) 组合。
    private func runSnapToROI() {
        guard let img = image else { return }
        // 兜底：点按钮不会让 TextField 失焦，正在编辑的瞬时 "1" 可能还没被
        // 失焦补夹，这里消费前先夹回合法范围。
        normalizeRowsCols()
        detectionRunning = true
        let currentCorners = corners
        let rowsCopy = rows
        let colsCopy = cols
        Task {
            let result = await GridDetectionService.shared.fitWithUserRowsCols(
                image: img,
                rows: rowsCopy,
                cols: colsCopy,
                roi: roiRect(from: currentCorners, imageSize: img.size)
            )
            await MainActor.run {
                detectionRunning = false
                if let r = result {
                    // 约束拟合返回的 rows/cols 跟用户输入一致，只更新 corners
                    corners = r.corners
                    if rectMode { snapCornersToRect() }
                    detectionConfidence = r.confidence
                } else {
                    detectionConfidence = 0
                }
            }
        }
    }

    private func runAutoDetect(restrictToCurrentROI: Bool) {
        guard let img = image else { return }
        detectionRunning = true
        let currentCorners = corners
        let useROI = restrictToCurrentROI
        Task {
            let result: GridDetectionResult?
            if useROI {
                result = await GridDetectionService.shared.detect(
                    image: img,
                    roi: roiRect(from: currentCorners, imageSize: img.size)
                )
            } else {
                result = await GridDetectionService.shared.detect(image: img)
            }
            await MainActor.run {
                detectionRunning = false
                if let r = result {
                    if useROI {
                        // 用户已确定 ROI，保留用户的 corners，只更新行列数
                        rows = r.rows
                        cols = r.cols
                    } else {
                        corners = r.corners
                        rows = r.rows
                        cols = r.cols
                    }
                    // 检测器低置信度兜底拟合可能返回 1（或越界值），夹回合法范围，
                    // 别让非法行列数落进 State / 灌给 live 网格预览。
                    normalizeRowsCols()
                    if rectMode { snapCornersToRect() }
                    detectionConfidence = r.confidence
                } else {
                    detectionConfidence = 0
                }
            }
        }
    }

    private func roiRect(from corners: GridCorners, imageSize: CGSize) -> CGRect {
        let tlx = min(corners.topLeft.x, corners.bottomLeft.x)
        let tly = min(corners.topLeft.y, corners.topRight.y)
        let brx = max(corners.topRight.x, corners.bottomRight.x)
        let bry = max(corners.bottomLeft.y, corners.bottomRight.y)
        return CGRect(x: tlx * imageSize.width,
                      y: tly * imageSize.height,
                      width: (brx - tlx) * imageSize.width,
                      height: (bry - tly) * imageSize.height)
    }

    private func saveAndContinue() {
        guard let img = image else { return }
        // 兜底：点保存不会让 TextField 失焦，消费前先把行列夹回合法范围。
        normalizeRowsCols()
        saving = true
        savingPhase = "准备图像..."
        savingStartTime = Date()
        savingDisplayElapsed = 0
        let cornersCopy = rectMode ? rectangleCorners(from: corners) : corners
        let rowsCopy = rows
        let colsCopy = cols
        let projectId = project.id
        let colorSystem = project.colorSystem
        let legendCodes = Set(project.beadUsage.map { $0.colorCode })
        // 采样用的候选池：MARD 下永远加 H2 兜底空白格识别。
        // 采样后会把匹到 H2 但 H2 不在 legendCodes 的格子降级为 nil（空白）。
        var allowedCodes = legendCodes
        if project.colorSystem == .mard {
            allowedCodes.insert("H2")
        }
        debugLog("[PatternCal] start; image.size=\(img.size), rows=\(rowsCopy), cols=\(colsCopy), allowed=\(allowedCodes.count)")
        Task.detached(priority: .userInitiated) {
            let t0 = Date()
            debugLog("[PatternCal] T+0.0s downsampling")
            let processingImage = GridOCRSampler.downsampledForOCR(img)
            debugLog("[PatternCal] T+\(String(format: "%.2f", Date().timeIntervalSince(t0)))s downsampled to \(processingImage.size)")

            await MainActor.run { savingPhase = "颜色采样中..." }
            let availableColors = await MainActor.run { inventoryManager.beadColors }
            debugLog("[PatternCal] T+\(String(format: "%.2f", Date().timeIntervalSince(t0)))s got \(availableColors.count) bead colors")
            let placeholder = BeadPatternGrid(
                corners: cornersCopy, rows: rowsCopy, cols: colsCopy,
                cellColorCodes: Array(repeating: Array(repeating: nil, count: colsCopy), count: rowsCopy),
                lastCalibratedAt: Date(),
                sourceImageSize: img.size,
                colorSystem: colorSystem
            )

            debugLog("[PatternCal] T+\(String(format: "%.2f", Date().timeIntervalSince(t0)))s color sampling start (downsampled)")
            // 颜色采样在降采样图上跑（normalizeToRGBA8 易爆内存，需要小图）。
            // 返回每格的 avg Lab + 匹配的色号，下游用 avg Lab 做 OCR 校验。
            let detailedCells = GridCellSampler.shared.sampleDetailed(
                image: processingImage, grid: placeholder,
                availableColors: availableColors,
                allowedCodes: allowedCodes.isEmpty ? nil : allowedCodes
            )
            let colorMatchedCount = detailedCells.flatMap { $0 }.compactMap { $0.matchedCode }.count
            debugLog("[PatternCal] T+\(String(format: "%.2f", Date().timeIntervalSince(t0)))s color sampling done, matched \(colorMatchedCount)")

            var cells: [[String?]] = detailedCells.map { row in row.map { $0.matchedCode } }

            // 构建 code → Lab 的查询表（用所有可用 BeadColor，含图例外色号如 H2）。
            // OCR 多候选 disambig + 交叉校验都要用。
            var codeToLab: [String: LabColor] = [:]
            for color in availableColors {
                let code = color.displayCode(for: colorSystem)
                if color.hasCode(for: colorSystem),
                   let lab = GridCellSampler.lab(forHex: color.colorHex) {
                    codeToLab[code] = lab
                }
            }

            if !allowedCodes.isEmpty {
                await MainActor.run { savingPhase = "OCR 识别中" }
                debugLog("[PatternCal] T+\(String(format: "%.2f", Date().timeIntervalSince(t0)))s per-cell OCR start (using ORIGINAL image)")
                // OCR 用原图！per-cell 裁剪小图不会爆内存，但分辨率高对识别准确度
                // 至关重要（原图每格 ~140x175 vs 降采样后 ~33x73）。
                // 同时把 cellLabs + codeToLab 传给 OCR，让它对 E2/E3 这种近邻色
                // 用颜色 disambig（避免靠 OCR 置信度选错）。
                let cellLabs: [[LabColor?]] = detailedCells.map { row in row.map { $0.avgLab } }
                let ocrCells = await GridOCRSampler.shared.sampleAllCellsPerCell(
                    image: img, grid: placeholder, allowedCodes: allowedCodes,
                    cellLabs: cellLabs,
                    codeToLab: codeToLab,
                    progress: { done, total in
                        if done == 1 || done % 50 == 0 || done == total {
                            debugLog("[PatternCal] per-cell OCR \(done)/\(total)")
                        }
                        Task { @MainActor in
                            savingPhase = "OCR \(done)/\(total)"
                        }
                    }
                )
                let ocrMatchedCount = ocrCells.flatMap { $0 }.compactMap { $0 }.count
                debugLog("[PatternCal] T+\(String(format: "%.2f", Date().timeIntervalSince(t0)))s per-cell OCR done, matched \(ocrMatchedCount)")

                // 交叉校验：OCR 结果只在颜色一致时才采纳。
                // 阈值：ΔE 25 — 同色族浅深变化算可信，跨色族（黄变白）算 OCR 误读。
                let ocrVerifyThreshold: Double = 25.0
                var ocrAccepted = 0
                var ocrRejected = 0
                for r in 0..<rowsCopy {
                    for c in 0..<colsCopy {
                        guard let ocrCode = ocrCells[r][c] else { continue }
                        let sample = detailedCells[r][c]
                        if let avgLab = sample.avgLab, let ocrLab = codeToLab[ocrCode] {
                            let de = GridCellSampler.deltaE(avgLab, ocrLab)
                            if de < ocrVerifyThreshold {
                                cells[r][c] = ocrCode
                                ocrAccepted += 1
                            } else {
                                // OCR 离谱，留颜色采样结果
                                ocrRejected += 1
                            }
                        } else {
                            // 无法校验（无 avgLab 或 OCR code 不在 BeadColor 库）→ 信 OCR
                            cells[r][c] = ocrCode
                            ocrAccepted += 1
                        }
                    }
                }
                debugLog("[PatternCal] T+\(String(format: "%.2f", Date().timeIntervalSince(t0)))s OCR cross-check: \(ocrAccepted) accepted, \(ocrRejected) rejected (color inconsistent)")
            }
            // 注意：候选池里加过的兜底色号（如 MARD 的 H2）保留在 cells 里，
            // 即使它不在原图例。调色板会用 "(空白格)" 标注让用户能区分。
            var extraCount = 0
            for r in 0..<rowsCopy {
                for c in 0..<colsCopy {
                    if let code = cells[r][c], !legendCodes.contains(code) {
                        extraCount += 1
                    }
                }
            }
            debugLog("[PatternCal] T+\(String(format: "%.2f", Date().timeIntervalSince(t0)))s extra-code cells (e.g. H2 blank): \(extraCount)")
            let grid = BeadPatternGrid(
                corners: cornersCopy, rows: rowsCopy, cols: colsCopy,
                cellColorCodes: cells,
                lastCalibratedAt: Date(),
                sourceImageSize: img.size,
                colorSystem: colorSystem
            )
            await MainActor.run {
                debugLog("[PatternCal] T+\(String(format: "%.2f", Date().timeIntervalSince(t0)))s all done; saving + dismissing")
                inventoryManager.updateProjectPatternGrid(projectId, grid: grid)
                saving = false
                savingPhase = nil
                savingStartTime = nil
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    onComplete?()
                }
            }
        }
    }

    private func rectangleCorners(from c: GridCorners) -> GridCorners {
        let tlx = min(c.topLeft.x, c.bottomRight.x)
        let tly = min(c.topLeft.y, c.bottomRight.y)
        let brx = max(c.topLeft.x, c.bottomRight.x)
        let bry = max(c.topLeft.y, c.bottomRight.y)
        return GridCorners(
            topLeft: CGPoint(x: tlx, y: tly),
            topRight: CGPoint(x: brx, y: tly),
            bottomLeft: CGPoint(x: tlx, y: bry),
            bottomRight: CGPoint(x: brx, y: bry)
        )
    }

    private func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        let s = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * s
        let h = imageSize.height * s
        return CGRect(x: (container.width - w) / 2,
                      y: (container.height - h) / 2,
                      width: w, height: h)
    }

    /// 给定角点 label 和 displayRect，返回该角点在源图像素坐标系的位置
    private func imagePoint(for label: CornerLabel, displayRect: CGRect, image: UIImage) -> CGPoint {
        let norm: CGPoint
        switch label {
        case .tl: norm = corners.topLeft
        case .tr: norm = corners.topRight
        case .bl: norm = corners.bottomLeft
        case .br: norm = corners.bottomRight
        }
        return CGPoint(x: norm.x * image.size.width, y: norm.y * image.size.height)
    }

    /// 放大镜位置：默认在触点正上方 100pt，越界时移到下方
    private func loupePosition(for touch: CGPoint, in container: CGSize) -> CGPoint {
        let preferredY = touch.y - 110
        if preferredY > 60 { return CGPoint(x: touch.x, y: preferredY) }
        return CGPoint(x: touch.x, y: touch.y + 110)
    }
}

extension GridCorners {
    /// 默认四角占图片 10%~90%
    static let initialQuad = GridCorners(
        topLeft: CGPoint(x: 0.1, y: 0.1),
        topRight: CGPoint(x: 0.9, y: 0.1),
        bottomLeft: CGPoint(x: 0.1, y: 0.9),
        bottomRight: CGPoint(x: 0.9, y: 0.9)
    )
}

enum CornerLabel: CaseIterable, Hashable {
    case tl, tr, bl, br
}

private struct CornerHandle: View {
    let label: CornerLabel
    @Binding var corners: GridCorners
    let displayRect: CGRect
    let rectMode: Bool
    @Binding var draggingCorner: CornerLabel?
    @Binding var draggingScreenPoint: CGPoint

    var body: some View {
        let p = currentPoint
        // 60pt 透明热区 + 28pt 可见红点
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.001))   // 几乎透明但接收触摸
                .frame(width: 64, height: 64)
            Circle()
                .fill(Theme.ColorToken.Status.error.opacity(0.85))
                .frame(width: 28, height: 28)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
        }
        .contentShape(Circle().scale(2))            // 显式扩大命中区
        .position(x: p.x, y: p.y)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let clamped = CGPoint(
                        x: max(displayRect.minX, min(displayRect.maxX, value.location.x)),
                        y: max(displayRect.minY, min(displayRect.maxY, value.location.y))
                    )
                    update(to: GridGeometry.normalize(clamped, in: displayRect))
                    draggingCorner = label
                    draggingScreenPoint = clamped
                }
                .onEnded { _ in
                    draggingCorner = nil
                }
        )
    }

    private var currentPoint: CGPoint {
        let norm: CGPoint = {
            switch label {
            case .tl: return corners.topLeft
            case .tr: return corners.topRight
            case .bl: return corners.bottomLeft
            case .br: return corners.bottomRight
            }
        }()
        return GridGeometry.denormalize(norm, in: displayRect)
    }

    private func update(to norm: CGPoint) {
        switch label {
        case .tl:
            corners.topLeft = norm
            if rectMode {
                corners.topRight.y = norm.y
                corners.bottomLeft.x = norm.x
            }
        case .tr:
            corners.topRight = norm
            if rectMode {
                corners.topLeft.y = norm.y
                corners.bottomRight.x = norm.x
            }
        case .bl:
            corners.bottomLeft = norm
            if rectMode {
                corners.topLeft.x = norm.x
                corners.bottomRight.y = norm.y
            }
        case .br:
            corners.bottomRight = norm
            if rectMode {
                corners.bottomLeft.y = norm.y
                corners.topRight.x = norm.x
            }
        }
    }
}

private struct CalibrationGridOverlay: View {
    let corners: GridCorners
    let rows: Int
    let cols: Int
    let displayRect: CGRect

    var body: some View {
        // 实时渲染：rows/cols 是可编辑 State，打字途中可能瞬时为 0/1（用户清空后
        // 输 "0"）。这里是唯一的「live 消费者」，不走 normalizeRowsCols() 的失焦/
        // 消费兜底，故在本视图内自夹下界 1——既避免 `CGFloat(c)/CGFloat(0)` 出 NaN
        // 灌进 Canvas Path，也避免 cols<0 时 `0...cols` 直接崩。
        let safeCols = max(cols, 1)
        let safeRows = max(rows, 1)
        return Canvas { context, _ in
            for c in 0...safeCols {
                let u = CGFloat(c) / CGFloat(safeCols)
                let p1 = GridGeometry.bilinear(u: u, v: 0, corners: corners, in: displayRect)
                let p2 = GridGeometry.bilinear(u: u, v: 1, corners: corners, in: displayRect)
                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                context.stroke(path, with: .color(.cyan.opacity(0.7)), lineWidth: 0.7)
            }
            for r in 0...safeRows {
                let v = CGFloat(r) / CGFloat(safeRows)
                let p1 = GridGeometry.bilinear(u: 0, v: v, corners: corners, in: displayRect)
                let p2 = GridGeometry.bilinear(u: 1, v: v, corners: corners, in: displayRect)
                var path = Path()
                path.move(to: p1)
                path.addLine(to: p2)
                context.stroke(path, with: .color(.cyan.opacity(0.7)), lineWidth: 0.7)
            }
        }
    }
}

/// 整体移动手势：在网格内部（角点热区外）单指拖，平移所有 4 个 corners。
/// 不改变形状/大小，只是整体挪位置。用于把识别到的矩形挪到不含 index 标号的区域。
private struct GridBodyDragHandle: View {
    @Binding var corners: GridCorners
    let displayRect: CGRect

    @State private var dragStart: GridCorners? = nil

    var body: some View {
        let bb = boundingBox(of: corners, in: displayRect)
        Rectangle()
            .fill(Color.white.opacity(0.001))   // 几乎透明但接收触摸
            .frame(width: bb.width, height: bb.height)
            .position(x: bb.midX, y: bb.midY)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 5)   // 5pt 移动后才触发，避免误吞 tap
                    .onChanged { value in
                        if dragStart == nil { dragStart = corners }
                        guard let start = dragStart else { return }
                        let dx = value.translation.width / displayRect.width
                        let dy = value.translation.height / displayRect.height
                        corners = translate(start, dx: dx, dy: dy)
                    }
                    .onEnded { _ in
                        dragStart = nil
                    }
            )
    }

    /// 整体平移 4 个角，并 clamp 整体到 [0,1] 范围内（不变形）
    private func translate(_ c: GridCorners, dx: CGFloat, dy: CGFloat) -> GridCorners {
        let xs = [c.topLeft.x, c.topRight.x, c.bottomLeft.x, c.bottomRight.x]
        let ys = [c.topLeft.y, c.topRight.y, c.bottomLeft.y, c.bottomRight.y]
        let actualDx = max(-(xs.min() ?? 0), min(1 - (xs.max() ?? 1), dx))
        let actualDy = max(-(ys.min() ?? 0), min(1 - (ys.max() ?? 1), dy))
        return GridCorners(
            topLeft: CGPoint(x: c.topLeft.x + actualDx, y: c.topLeft.y + actualDy),
            topRight: CGPoint(x: c.topRight.x + actualDx, y: c.topRight.y + actualDy),
            bottomLeft: CGPoint(x: c.bottomLeft.x + actualDx, y: c.bottomLeft.y + actualDy),
            bottomRight: CGPoint(x: c.bottomRight.x + actualDx, y: c.bottomRight.y + actualDy)
        )
    }

    private func boundingBox(of c: GridCorners, in rect: CGRect) -> CGRect {
        let xs = [c.topLeft.x, c.topRight.x, c.bottomLeft.x, c.bottomRight.x]
        let ys = [c.topLeft.y, c.topRight.y, c.bottomLeft.y, c.bottomRight.y]
        let minX = (xs.min() ?? 0) * rect.width + rect.minX
        let maxX = (xs.max() ?? 1) * rect.width + rect.minX
        let minY = (ys.min() ?? 0) * rect.height + rect.minY
        let maxY = (ys.max() ?? 1) * rect.height + rect.minY
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// 放大镜：圆形窗口显示拖动点附近的原图像素，3 倍放大，避免被手指遮挡。
private struct LoupeView: View {
    let image: UIImage
    let imageCenter: CGPoint    // 原图像素坐标系

    private let loupeSize: CGFloat = 120
    private let zoom: CGFloat = 1.6

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: image.size.width * zoom,
                   height: image.size.height * zoom)
            .offset(x: loupeSize / 2 - imageCenter.x * zoom,
                    y: loupeSize / 2 - imageCenter.y * zoom)
            .frame(width: loupeSize, height: loupeSize, alignment: .topLeading)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white, lineWidth: 3))
            .overlay(crosshair)
            .shadow(color: .black.opacity(0.4), radius: 6)
    }

    private var crosshair: some View {
        ZStack {
            Rectangle().fill(Color.red).frame(width: 16, height: 1.5)
            Rectangle().fill(Color.red).frame(width: 1.5, height: 16)
        }
    }
}
