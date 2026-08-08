//
//  F1BenchmarkRecorder.swift
//  BeadInventory
//
//  F1(启动期自动备份)内存实测的记录器。**实验设施,不参与发布构建。**
//
//  ## 为什么不用 AppLogger 当完成信号
//
//  实验脚本需要知道"这一步跑完了没有"。用日志轮询做不到可靠:
//    - `AppLogger` 是异步缓冲的(8KB / 1.5s),被杀前可能根本没落盘;
//    - 日志文件会轮转,还可能读到**上一轮遗留**的同名事件,造成假阳性;
//    - 崩溃场景下最需要证据的那一刻,恰恰是最可能丢日志的一刻。
//
//  所以本记录器写**独立的结构化结果文件**,并且:
//    - 每次启动由 `-F1RunID` 传入唯一 ID,文件名即该 ID —— 结构上不可能读到上一轮残留;
//    - 每次更新都**原子写 + fsync**(复用 LaunchDiagnostics 已实测验证的机制);
//    - `observedMaxSoFar` **增量更新** —— 进程中途被杀时,已观测到的峰值仍然留在盘上。
//      这一条是"中断也算有效结果"这句话能成立的前提,否则那只是一句空话。
//
//  ## 构建门控
//
//  `#if DEBUG || F1_BENCHMARK`。后者由命令行注入:
//
//      xcodebuild -configuration Release \
//        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) F1_BENCHMARK' build
//
//  **必须用 Release 级优化测量** —— Debug 的 `-Onone` 会改变对象释放时机、内存峰值
//  和执行时长,而这三样正好是本实验的核心指标。用 Debug 数值下生产结论是无效的。
//  该配置只存在于命令行,工程文件里没有它,所以不可能被误 Archive。

#if DEBUG || F1_BENCHMARK

import Foundation
import Darwin

/// 一次实验步骤的结构化结果。字段与实验计划 v3 §6.4 一一对应。
struct F1BenchmarkResult: Codable {
    var runID: String
    /// `started` → `reset_done` / `seed_done` / `completed`
    var state: String
    /// `F1_BENCHMARK` 还是 `DEBUG` —— 结论必须带这个,见文件头。
    var buildConfig: String

    // 生效配置**回显**。外部 `defaults write` 可能因模拟器偏好域路径问题静默失败,
    // 所以这里报告 App 实际读到的值,让脚本验证而不是假设。
    var effectiveCloudOptOut: Bool?
    var migrationDisabled: Bool?
    var backupDisabled: Bool?

    /// 六个检查点的 phys_footprint(字节)。键是检查点名。
    var checkpoints: [String: UInt64] = [:]
    /// 采样器观测到的最大 phys_footprint。**持续更新**,中断留证用。
    var observedMaxSoFar: UInt64 = 0
    /// 采样周期(毫秒)—— 结论里必须一并报告,峰值只能表述为"该周期下观测到的最大值"。
    var samplePeriodMillis: Int = 50

    // 横轴:备份实际读取的三个字段。**patternGridData 不在此列** —— createBackupData
    // 根本不读它,算进去会系统性压低斜率。
    var thumbnailCount: Int?
    var thumbnailBytes: Int64?
    var finishedImageCount: Int?
    var finishedImageBytes: Int64?
    var displayThumbnailCount: Int?
    var displayThumbnailBytes: Int64?

    /// 并列报告,供将来体积门控阈值换算参考。**不得直接换算成内存阈值** ——
    /// store 里含 patternGrid 等不参与备份的数据。
    var storeBytes: Int64?
    var walBytes: Int64?

    /// `performBackup()` 占用主线程的时长(单调时钟)。Q4。
    var mainThreadMillis: Double?
    var freeDiskBytes: Int64?

    // 反常排查(检查点 2 只涨 8 MB)。见 `F1Benchmark.measureRetainedBase64`。
    var retainedBase64Chars: Int64?
    var retainedBase64Fields: Int?
    var footprintAfterBase64Walk: UInt64?
    var vmInternal: UInt64?
    var vmCompressed: UInt64?
    var vmResident: UInt64?
}

enum F1Benchmark {

    // MARK: - 是否启用

    /// 本次进程是否是实验运行。没有 `-F1RunID` 就整体降级成 no-op。
    static var runID: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-F1RunID"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var isActive: Bool { runID != nil }

    static func hasFlag(_ flag: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }

    private static var buildConfig: String {
        #if F1_BENCHMARK
        return "F1_BENCHMARK"
        #else
        return "DEBUG"
        #endif
    }

    // MARK: - 状态

    private static let lock = NSLock()
    private static var result: F1BenchmarkResult?
    private static var sampler: Thread?
    private static var samplingActive = false

    // MARK: - 生命周期

    static func begin() {
        guard let runID else { return }
        lock.lock()
        result = F1BenchmarkResult(runID: runID, state: "started", buildConfig: buildConfig)
        lock.unlock()
        persist()
    }

    /// 回显实际生效的配置,供脚本验证(而非假设)外部设置是否真的生效了。
    static func recordEffectiveConfig(cloudOptOut: Bool, migrationDisabled: Bool, backupDisabled: Bool) {
        mutate {
            $0.effectiveCloudOptOut = cloudOptOut
            $0.migrationDisabled = migrationDisabled
            $0.backupDisabled = backupDisabled
        }
    }

    static func setState(_ state: String) {
        mutate { $0.state = state }
    }

    static func checkpoint(_ name: String) {
        guard let fp = physFootprint() else { return }
        mutate { $0.checkpoints[name] = fp }
    }

    static func recordBlobBytes(
        thumbnail: (count: Int, bytes: Int64),
        finished: (count: Int, bytes: Int64),
        display: (count: Int, bytes: Int64)
    ) {
        mutate {
            $0.thumbnailCount = thumbnail.count;        $0.thumbnailBytes = thumbnail.bytes
            $0.finishedImageCount = finished.count;     $0.finishedImageBytes = finished.bytes
            $0.displayThumbnailCount = display.count;   $0.displayThumbnailBytes = display.bytes
        }
    }

    static func recordStoreMetrics(store: Int64?, wal: Int64?) {
        mutate { $0.storeBytes = store; $0.walBytes = wal }
    }

    /// 走一遍 `createBackupData` 的返回结构,统计三个图片字段的 base64 字符串**实际长度**,
    /// 以及此刻的 footprint。
    ///
    /// 用途:排查"检查点 2 只涨 8 MB"这个反常。它把两种可能分开 ——
    ///   · `retainedBase64Chars ≈ 预期` 而 footprint 不涨 → 字符串活着但没进 phys_footprint;
    ///   · `retainedBase64Chars` 本身就小 → 有东西在返回前释放了它们。
    ///
    /// 遍历本身**不复制字符串内容**(只读 `count`),因此不会显著抬高被测值;
    /// 但遍历会 touch 这些字符串 —— 如果它们此前被压缩换出,这一步会把它们换回来,
    /// 于是 `footprintAfterWalk` 相对 `checkpoint 2` 的涨幅本身就是一个信号。
    static func measureRetainedBase64(in backupData: [String: Any]) {
        guard isActive else { return }
        var chars: Int64 = 0
        var fields = 0
        if let projects = backupData["projects"] as? [[String: Any]] {
            for p in projects {
                for key in ["thumbnail", "finishedImage", "displayThumbnail"] {
                    if let s = p[key] as? String {
                        chars += Int64(s.count)
                        fields += 1
                    }
                }
            }
        }
        let after = physFootprint()
        let vm = vmBreakdown()
        mutate {
            $0.retainedBase64Chars = chars
            $0.retainedBase64Fields = fields
            $0.footprintAfterBase64Walk = after
            $0.vmInternal = vm?.internalBytes
            $0.vmCompressed = vm?.compressed
            $0.vmResident = vm?.resident
        }
    }

    /// `phys_footprint` 之外的几个 `task_vm_info` 分量。
    ///
    /// 排查用:已确证字典里活着 518 MB 的 base64 字符串,而 `phys_footprint` 完全不动。
    /// "被释放了"和"被压缩了"都已排除(前者有实测字符数,后者 base64 的熵不允许),
    /// 所以怀疑落在**记账口径**上。`internal` 是进程私有的匿名内存,`compressed` 是被
    /// 压缩器换出的部分 —— 三个数一起看就能判断这 518 MB 到底算在了哪里,
    /// 还是压根没被算。
    private static func vmBreakdown() -> (internalBytes: UInt64, compressed: UInt64, resident: UInt64)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return (info.internal, info.compressed, info.resident_size)
    }

    static func recordMainThreadDuration(millis: Double) {
        mutate { $0.mainThreadMillis = millis }
    }

    static func recordFreeDisk() {
        mutate { $0.freeDiskBytes = Self.freeDiskBytes() }
    }

    // MARK: - 采样器

    /// 启动 phys_footprint 采样。
    ///
    /// 用 `phys_footprint` 而不是 `resident_size` —— 前者才是 **jetsam 的记账口径**。
    /// 采样是有周期的,短于周期的尖峰会漏掉,所以结论里一律表述为
    /// 「50 ms 采样周期下**观测到的**最大值」,不能说成"峰值"。
    static func startSampling(periodMillis: Int = 50) {
        guard isActive, sampler == nil else { return }
        mutate { $0.samplePeriodMillis = periodMillis }
        samplingActive = true
        let t = Thread {
            while samplingActive {
                if let fp = physFootprint() {
                    lock.lock()
                    if var r = result, fp > r.observedMaxSoFar {
                        r.observedMaxSoFar = fp
                        result = r
                        lock.unlock()
                        // 每次刷新最大值就落盘 —— 进程被杀时盘上留着的就是最后观测值。
                        persist()
                    } else {
                        lock.unlock()
                    }
                }
                Thread.sleep(forTimeInterval: Double(periodMillis) / 1000)
            }
        }
        t.qualityOfService = .userInitiated   // 别被降频，否则采样周期名不副实
        t.start()
        sampler = t
    }

    static func stopSampling() {
        samplingActive = false
        sampler = nil
    }

    // MARK: - 内部

    private static func mutate(_ body: (inout F1BenchmarkResult) -> Void) {
        guard isActive else { return }
        lock.lock()
        guard var r = result else { lock.unlock(); return }
        body(&r)
        result = r
        lock.unlock()
        persist()
    }

    private static var resultURL: URL? {
        guard let runID,
              let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
              ).first else { return nil }
        let dir = base.appendingPathComponent("F1Benchmark", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("\(runID).json")
    }

    private static func persist() {
        lock.lock(); let snapshot = result; lock.unlock()
        guard let snapshot, let url = resultURL else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        // 原子写 + fsync：与 LaunchDiagnostics 同型。中断留证的前提是"写下去的真在盘上"。
        try? data.write(to: url, options: .atomic)
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.synchronize()
            try? handle.close()
        }
    }

    /// 当前进程的 phys_footprint(字节)—— jetsam 记账口径。
    private static func physFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    private static func freeDiskBytes() -> Int64? {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return capacity
    }
}

#endif
