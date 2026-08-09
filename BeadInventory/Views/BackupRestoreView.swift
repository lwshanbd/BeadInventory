//
//  BackupRestoreView.swift
//  BeadInventory
//
//  备份恢复视图 - 查看和恢复自动备份
//

import SwiftUI
import UniformTypeIdentifiers

struct BackupRestoreView: View {
    @EnvironmentObject var inventoryManager: InventoryManager
    @Environment(\.dismiss) private var dismiss

    @State private var backups: [BackupManager.BackupInfo] = []
    @State private var selectedBackup: BackupManager.BackupInfo?
    @State private var showingRestoreConfirm = false
    @State private var showingDeleteConfirm = false
    @State private var backupToDelete: BackupManager.BackupInfo?
    @State private var isRestoring = false
    @State private var restoreError: String?
    @State private var showingError = false
    /// 这次失败发生时 store 是否已被改动 —— 决定弹窗说"恢复失败"还是"恢复中断"。
    @State private var restoreDidMutateStore = false
    @State private var showingSuccess = false
    @State private var isBackingUp = false
    @State private var isSuppressed = false
    @State private var backupMessage: String?
    /// 上一次恢复没走完时的残留记录。**必须展示给用户** —— 只写日志的话，
    /// metadata 已替换、blob 恢复中断的用户会毫不知情地继续用一个半恢复的库。
    @State private var restoreResidual: RestoreJournalEntry?

    // 导入状态。
    //
    // `importSource` 是**持有 security scope 的**外部 URL —— 从 picker 返回一直握到
    // materialize 结束或用户取消。scope 必须跨越那次确认交互（用户在确认框里做决定时，
    // 我们还没开始复制）。任何退出路径都要成对 stopAccessing，见 releaseImportSource()。
    @State private var importSource: URL?
    @State private var importPlan: BackupImportStaging.Plan?
    @State private var showingImporter = false
    @State private var showingImportConfirm = false
    @State private var isImporting = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                restoreResidualBanner
                suppressionBanner
                messageBanner
                if backups.isEmpty {
                    emptyView
                } else {
                    backupListView
                }
            }
            .navigationTitle("备份与恢复")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
                // 手动备份入口。
                //
                // 它不只是"方便" —— 自动备份被中断后会**抑制当周**，而被抑制时它压根
                // 不运行，所以无法靠自己成功来解除。手动成功是唯一的主动解除路径
                //（另一条是跨周自然失效）。没有这个入口，用户遇到中断就只能干等一周。
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("导入备份", systemImage: "square.and.arrow.down")
                    }
                    .disabled(isImporting || isRestoring)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await performManualBackup() }
                    } label: {
                        if isBackingUp {
                            ProgressView()
                        } else {
                            Label("立即备份", systemImage: "arrow.clockwise.icloud")
                        }
                    }
                    .disabled(isBackingUp)
                }
            }
            .onAppear {
                loadBackups()
                isSuppressed = BackupManager.shared.isAutomaticBackupSuppressed
                restoreResidual = RestoreJournal.residual()
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.beadInventoryBackup],
                allowsMultipleSelection: false
            ) { result in
                handleImportSelection(result)
            }
            .confirmationDialog(
                "导入将替换全部数据",
                isPresented: $showingImportConfirm,
                titleVisibility: .visible
            ) {
                Button("导入并替换", role: .destructive) {
                    Task { await performImport() }
                }
                Button("取消", role: .cancel) { releaseImportSource() }
            } message: {
                if let plan = importPlan {
                    Text("将导入 \(plan.manifest.projects.count) 个项目，约 \(plan.totalBytes / 1024 / 1024) MB。当前所有数据会被替换，此操作不可撤销。")
                }
            }
            .confirmationDialog(
                "确定要恢复这个备份吗？",
                isPresented: $showingRestoreConfirm,
                titleVisibility: .visible
            ) {
                Button("恢复备份", role: .destructive) {
                    performRestore()
                }
                Button("取消", role: .cancel) {}
            } message: {
                if let backup = selectedBackup {
                    Text("这将用 \(backup.formattedDate) 的备份替换当前所有数据。此操作不可撤销。")
                }
            }
            .confirmationDialog(
                "确定要删除这个备份吗？",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let backup = backupToDelete {
                        deleteBackup(backup)
                    }
                }
                Button("取消", role: .cancel) {}
            }
            // 标题按"库有没有被改过"分开。两者对用户的含义完全不同：
            // 「恢复失败」= 你的数据没被动，可以放心重试；
            // 「恢复中断」= 库现在可能是半恢复的，必须重跑。
            // 混成一句会让人以为库还是干净的，然后就此走开。
            .alert(restoreFailureTitle, isPresented: $showingError) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(restoreError ?? String(localized: "未知错误"))
            }
            .alert("恢复成功", isPresented: $showingSuccess) {
                Button("确定") {
                    dismiss()
                }
            } message: {
                Text("数据已成功恢复")
            }
        }
    }

    // MARK: - 顶部横幅
    //
    // 抽成独立属性而不是内联进 body：SwiftUI 的 body 里堆条件分支会让 Swift 类型检查器
    // 指数级退化（SourceKit 实测报 "unable to type-check this expression in reasonable
    // time"）。本仓库 ScanView 甚至为此专门有个 `.pipe` helper。

    /// 上一次恢复中断的持久提示。
    ///
    /// 这是**数据可能已经半损坏**的告知，比抑制提示严重一个等级：metadata 已被替换、
    /// 图片只恢复了一部分。归档还在盘上且重跑幂等，所以直接给一个"重新恢复该归档"的动作。
    /// 提示在成功恢复后自动消失（RestoreJournal 届时被清除）。
    @ViewBuilder
    private var restoreResidualBanner: some View {
        if let residual = restoreResidual {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("上次恢复未完成，当前数据可能不完整")
                            .font(.footnote.weight(.semibold))
                        Text("中断于：\(residual.phase)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text((residual.archivePath as NSString).lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                Button("重新恢复该归档") {
                    retryResidualRestore(residual)
                }
                .font(.footnote.weight(.semibold))
            }
            .padding(12)
            .background(Color.red.opacity(0.12))
        }
    }

    /// 被抑制时必须让用户看得见 —— 否则"这周怎么没备份"无从得知，
    /// 而解除办法（点一次"立即备份"）就在同一屏上。
    @ViewBuilder
    private var suppressionBanner: some View {
        if isSuppressed {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("上次自动备份被中断，本周已暂停自动备份。手动备份成功后会自动恢复。")
                    .font(.footnote)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.orange.opacity(0.12))
        }
    }

    @ViewBuilder
    private var messageBanner: some View {
        if let backupMessage {
            Text(backupMessage)
                .font(.footnote)
                .padding(8)
        }
    }

    // MARK: - 空状态视图

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.clockwise.icloud")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("暂无备份")
                .font(.title2)
                .fontWeight(.medium)

            Text("App 会在每周首次打开时自动备份数据")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - 备份列表视图

    private var backupListView: some View {
        List {
            Section {
                ForEach(backups) { backup in
                    BackupRow(backup: backup)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedBackup = backup
                            showingRestoreConfirm = true
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                backupToDelete = backup
                                showingDeleteConfirm = true
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            // **只有新格式能导出。**
                            //
                            // 旧 JSON 看似"也能分享"，但它导入不回来（导入只接受
                            // .beadbackup），而且它本身就漏 patternGrid。给它一个导出按钮
                            // 等于产出一份"用户带得走、重装后却用不回来"的备份 ——
                            // 那正是这次事故的形状：他以为自己有备份。
                            if backup.format == .archiveV1 {
                                ShareLink(
                                    item: BackupExport(archiveURL: backup.fileURL),
                                    preview: SharePreview(backup.fileName)
                                ) {
                                    Label("导出", systemImage: "square.and.arrow.up")
                                }
                                .tint(.blue)
                            }
                        }
                }
            } header: {
                Text("点击备份进行恢复")
            } footer: {
                Text("自动保留最近 8 周的备份。向左滑动可删除备份。")
            }
        }
        .overlay {
            if isRestoring {
                restoringOverlay
            }
        }
    }

    // MARK: - 恢复中遮罩

    private var restoringOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("正在恢复...")
                    .font(.headline)
                    .foregroundColor(.white)
            }
            .padding(30)
            .background(Theme.ColorToken.Surface.subtle)
            .cornerRadius(Theme.Radius.lg)
        }
    }

    // MARK: - 方法

    // MARK: - 导入

    /// picker 回调：取 security scope → **只做轻量预检** → 弹确认。
    ///
    /// 这里**不复制任何东西**。复制那 422 MB 必须发生在用户确认之后 ——
    /// 先复制再问，等于用户还没同意就已经付出了全部磁盘与时间代价，
    /// 而且"取消"时那份副本已经在盘上了。
    private func handleImportSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            restoreError = "\(error)"; showingError = true
        case .success(let urls):
            guard let url = urls.first else { return }
            // scope 从这里一直握到 materialize 结束或用户取消（见 releaseImportSource）。
            guard url.startAccessingSecurityScopedResource() else {
                restoreError = BackupImportStaging.StagingError.securityScopeDenied.description
                showingError = true
                return
            }
            importSource = url
            do {
                importPlan = try BackupImportStaging.makePlan(source: url)
                showingImportConfirm = true
            } catch {
                releaseImportSource()
                restoreError = "\(error)"
                showingError = true
            }
        }
    }

    /// 确认之后才开始的重活：复制 → 校验 → 应用。
    private func performImport() async {
        guard let plan = importPlan, let source = importSource else { return }
        isImporting = true
        defer { isImporting = false }

        var staged: URL?
        do {
            // **复制与校验必须离开 UI actor。**
            //
            // 这个 Task 继承 View 的 MainActor 隔离，而 materialize 是阻塞 I/O、
            // validate 要对全部 blob 算 SHA-256 —— 直接在这儿同步跑，422 MB 期间
            // 主线程整个卡住：进度遮罩不刷新，Files/iCloud 慢的时候界面直接僵住。
            //
            // 只有 apply 留在主线程 —— 它写 SwiftData，本来就必须在 mainContext 上。
            // **materialize 与 validate 必须分两步 await。**
            //
            // 合成一个 detached task 的话，validate 抛错时整个 task 不返回值 ——
            // 外层的 staged 仍是 nil，catch 里就清理不到**已经落地的**那份 package。
            // 反复导入"能落地但校验失败"的恶意归档就会一份份堆在盘上。
            let stagedURL = try await Task.detached(priority: .userInitiated) {
                try BackupImportStaging.materialize(plan, source: source)
            }.value
            staged = stagedURL          // ← 先记下来，之后任何失败 catch 都清理得到

            let report = try await Task.detached(priority: .userInitiated) {
                try BackupArchiveReader.validate(archiveAt: stagedURL)
            }.value
            // 复制完就可以放掉外部 scope —— 后续一律在我们自己的不可变副本上做，
            // 源文件此后怎么变都影响不到校验与应用（TOCTOU 就此关闭）。
            releaseImportSource()

            let staging = stagedURL
            try BackupArchiveReader.apply(report, to: inventoryManager)

            // 成功：journal 已被 apply 清除，staging 可以回收。
            BackupImportStaging.cleanupIfSafe(staging)
            restoreResidual = RestoreJournal.residual()
            loadBackups()
            showingSuccess = true
        } catch {
            releaseImportSource()
            // **失败时不无条件删 staging** —— 若 apply 中断，RestoreJournal 正指向它，
            // 用户要靠它重跑。cleanupIfSafe 自己会判断。
            if let staging = staged { BackupImportStaging.cleanupIfSafe(staging) }
            presentRestoreFailure(error)
        }
    }

    /// 失败弹窗标题。**不要内联成三元表达式** —— 放进 `.alert(...)` 的修饰符链里会让
    /// Swift 类型检查器超时（SourceKit 实测 "unable to type-check in reasonable time"）。
    private var restoreFailureTitle: String {
        restoreDidMutateStore
            ? String(localized: "恢复中断")
            : String(localized: "恢复失败")
    }

    /// 统一的恢复失败呈现。
    ///
    /// 所有恢复相关的 catch 都走这里，理由有三：
    ///   1. `"\(error)"` 而非 `localizedDescription` —— 这些错误只符合
    ///      `CustomStringConvertible`，后者会产出 "…error 3." 之类的系统乱码；
    ///   2. `RestoreError.didMutateStore` 决定标题，让"数据没动"和"数据可能不完整"
    ///      不再被混成同一句；
    ///   3. 顺手刷新残留横幅 —— 半恢复必须当场可见，而不是等用户退出再进来。
    private func presentRestoreFailure(_ error: Error) {
        restoreDidMutateStore = (error as? BackupArchiveReader.RestoreError)?.didMutateStore ?? false
        restoreError = "\(error)"
        restoreResidual = RestoreJournal.residual()
        showingError = true
    }

    /// 成对释放 security scope。任何退出路径都必须走到这里。
    private func releaseImportSource() {
        importSource?.stopAccessingSecurityScopedResource()
        importSource = nil
        importPlan = nil
    }

    /// 重跑中断的恢复。归档还在盘上，重跑是幂等的。
    private func retryResidualRestore(_ residual: RestoreJournalEntry) {
        let url = URL(fileURLWithPath: residual.archivePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            restoreError = "找不到该归档，可能已被删除。请从下方列表选择其它备份恢复。"
            showingError = true
            return
        }
        isRestoring = true
        Task {
            do {
                // 与 performImport / restoreBackup 同样的拆分：校验（读遍并哈希全部 blob）
                // 离开主 actor，只有 apply 留在主线程。
                //
                // 这条路径尤其不能卡主线程：它是给**已知半恢复**的库做修复的。
                // 在这里被看门狗杀掉，只会再制造一次中断记录，把用户留在原地。
                let report = try await Task.detached(priority: .userInitiated) {
                    try BackupArchiveReader.validate(archiveAt: url)
                }.value
                try BackupArchiveReader.apply(report, to: inventoryManager)
                isRestoring = false
                restoreResidual = RestoreJournal.residual()   // 成功后应为 nil
                showingSuccess = true
            } catch {
                isRestoring = false
                presentRestoreFailure(error)
            }
        }
    }

    /// 手动备份。成功后解除抑制并刷新列表。
    private func performManualBackup() async {
        isBackingUp = true
        backupMessage = nil
        let ok = await BackupManager.shared.performArchiveBackup(
            inventoryManager: inventoryManager, isManual: true
        )
        isBackingUp = false
        isSuppressed = BackupManager.shared.isAutomaticBackupSuppressed
        backupMessage = ok ? "备份完成" : "备份失败，请检查存储空间后重试"
        loadBackups()
    }

    private func loadBackups() {
        backups = BackupManager.shared.getBackupList()
    }

    private func performRestore() {
        guard let backup = selectedBackup else { return }

        isRestoring = true

        Task {
            do {
                // restoreBackup 内部把校验放到了 detached 任务上（见其注释）。
                try await BackupManager.shared.restoreBackup(from: backup, to: inventoryManager)
                isRestoring = false
                restoreResidual = RestoreJournal.residual()   // 成功后应为 nil
                showingSuccess = true
            } catch {
                isRestoring = false
                presentRestoreFailure(error)
            }
        }
    }

    private func deleteBackup(_ backup: BackupManager.BackupInfo) {
        if BackupManager.shared.deleteBackup(backup) {
            loadBackups()
        }
    }
}

// MARK: - 备份行视图

struct BackupRow: View {
    let backup: BackupManager.BackupInfo

    var body: some View {
        HStack(spacing: 12) {
            // 图标
            Image(systemName: "doc.zipper")
                .font(.title2)
                .foregroundColor(Theme.ColorToken.Status.info)
                .frame(width: 40)

            // 信息
            VStack(alignment: .leading, spacing: 4) {
                Text(backup.formattedDate)
                    .font(.headline)

                HStack(spacing: 12) {
                    if let stats = backup.stats {
                        Label("\(stats.brandsCount) 品牌", systemImage: "tag")
                        Label("\(stats.projectsCount) 项目", systemImage: "folder")
                    }
                    Text(backup.formattedSize)
                        .foregroundColor(.secondary)
                }
                .font(.caption)
                .foregroundColor(.secondary)

                // 旧格式的两个已知短板必须让用户看见：
                //  ① 恢复时会把整个 JSON（可达数百 MB）一次性读进内存 —— 既有行为，未重写；
                //  ② 它压根没写 patternGrid 字段，恢复后网格标定会丢。
                // 不提示的话，用户会以为两种备份等价。
                if backup.format == .legacyJSON {
                    // 旧格式的短板必须让用户看见，并给出**可执行的下一步** ——
                    // 它不能导出（导入只接受新格式，给它导出按钮就是造一份带得走却
                    // 用不回来的"备份"），恢复时还要整份读入内存、且不含拼图网格。
                    Label("旧格式：不可导出、不含拼图网格。请点右上角「立即备份」生成新版完整备份。",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    BackupRestoreView()
        .environmentObject(InventoryManager())
}
