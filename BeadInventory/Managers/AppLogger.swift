//
//  AppLogger.swift
//  BeadInventory
//
//  轻量本地诊断日志：异步写入、滚动文件、仅用户导出可见
//

import Foundation
import UIKit

enum AppLogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

final class AppLogger {
    static let shared = AppLogger()

    private let queue = DispatchQueue(label: "com.beadinventory.logger", qos: .utility)
    /// 标记「当前是否已经在 `queue` 上」。
    ///
    /// `flushNow()` 要同步等落盘,实现是 `queue.sync`。但 `queue` 是**普通串行队列** ——
    /// 从队列自身再 `sync` 回去必然死锁。日志调用点遍布全工程(含 logger 自己的
    /// 失败分支),不能假设调用方一定在队列外。所以用 specific key 认一下身份:
    /// 已在队列上就直接调 `flushLocked()`,不再 `sync`。
    private static let queueIdentityKey = DispatchSpecificKey<UInt8>()
    private static let queueIdentityValue: UInt8 = 1
    private let formatter: ISO8601DateFormatter

    private var activeFileURL: URL?
    private var activeHandle: FileHandle?
    private var activeFileSize: UInt64 = 0
    private var buffer = Data()
    private var flushWorkItem: DispatchWorkItem?
    private var sequence: UInt64 = 0

    private let maxFileSizeBytes: UInt64 = 256 * 1024
    private let maxFileCount: Int = 8
    private let maxBufferedBytes: Int = 8 * 1024
    private let flushDelay: TimeInterval = 1.5
    private let maxFieldLength: Int = 400

    private init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.formatter = formatter

        queue.setSpecific(key: Self.queueIdentityKey, value: Self.queueIdentityValue)

        queue.async { [weak self] in
            guard let self else { return }
            self.setupLocked()
            self.logLocked(
                level: .info,
                category: "App",
                message: "logger_initialized",
                metadata: [
                    "appVersion": Self.appVersion(),
                    "build": Self.buildVersion(),
                    "ios": UIDevice.current.systemVersion,
                    "device": Self.deviceModelIdentifier(),
                    "timezone": TimeZone.current.identifier
                ]
            )
        }
    }

    deinit {
        queue.sync {
            flushLocked()
            closeActiveFileLocked()
        }
    }

    /// 同步把缓冲刷到磁盘,并对文件做一次 `synchronize()`。
    ///
    /// **为什么需要它:** 常规写入是异步缓冲的(`maxBufferedBytes` 8KB / `flushDelay` 1.5s),
    /// 启动阶段那几条关键面包屑在被看门狗或 jetsam 杀掉时**大概率还没落盘** ——
    /// 崩得越早证据越少,这正是"实在定位不出原因"的结构性成因之一。
    /// 关键节点(开库前后、阶段标记变更)后必须调本方法。
    ///
    /// **不要在高频路径上调** —— 它是同步的,且带一次 fsync。
    ///
    /// 关于 `synchronize()`:对「进程被 SIGKILL」这个主要威胁模型,普通写入其实已经够了
    /// (字节进了内核页缓存,进程死亡不影响)。这里仍然 fsync 是为了覆盖掉电 / panic,
    /// 代价在关键节点上可以接受。
    func flushNow() {
        // 已经在 queue 上就直接干活 —— 再 sync 回自己是死锁(见 queueIdentityKey)。
        if DispatchQueue.getSpecific(key: Self.queueIdentityKey) == Self.queueIdentityValue {
            flushLocked()
            syncActiveFileLocked()
            return
        }
        queue.sync {
            flushLocked()
            syncActiveFileLocked()
        }
    }

    private func syncActiveFileLocked() {
        guard let handle = activeHandle else { return }
        // 失败不上报:logger 永远不该打断 App 流程,而且这里已经是尽力而为的最后一步。
        try? handle.synchronize()
    }

    func debug(_ category: String, _ message: String, metadata: [String: Any] = [:]) {
        enqueue(level: .debug, category: category, message: message, metadata: metadata)
    }

    func info(_ category: String, _ message: String, metadata: [String: Any] = [:]) {
        enqueue(level: .info, category: category, message: message, metadata: metadata)
    }

    func warning(_ category: String, _ message: String, metadata: [String: Any] = [:]) {
        enqueue(level: .warning, category: category, message: message, metadata: metadata)
    }

    func error(_ category: String, _ message: String, metadata: [String: Any] = [:]) {
        enqueue(level: .error, category: category, message: message, metadata: metadata)
    }

    func exportDiagnostics(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.flushLocked()
            do {
                let url = try self.exportLocked()
                DispatchQueue.main.async {
                    completion(.success(url))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func clearLogs(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.flushWorkItem?.cancel()
            self.flushWorkItem = nil
            self.flushLocked()
            self.closeActiveFileLocked()

            let files = self.logFilesLocked()
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
            self.setupLocked()
            self.logLocked(level: .info, category: "App", message: "logs_cleared")

            if let completion {
                DispatchQueue.main.async {
                    completion()
                }
            }
        }
    }

    private func enqueue(level: AppLogLevel, category: String, message: String, metadata: [String: Any]) {
        queue.async { [weak self] in
            self?.logLocked(level: level, category: category, message: message, metadata: metadata)
        }
    }

    private func logLocked(level: AppLogLevel, category: String, message: String, metadata: [String: Any] = [:]) {
        let timestamp = formatter.string(from: Date())
        sequence += 1

        var line = "\(timestamp) #\(sequence) [\(level.rawValue)] [\(sanitize(message: category))] \(sanitize(message: message))"

        if !metadata.isEmpty {
            let rendered = metadata
                .map { key, value -> String in
                    let keySanitized = sanitize(message: key)
                    let valueString = String(describing: value)
                    let valueSanitized = redactIfNeeded(key: keySanitized, value: sanitize(message: valueString))
                    return "\(keySanitized)=\(valueSanitized)"
                }
                .sorted()
                .joined(separator: " ")
            if !rendered.isEmpty {
                line += " | \(rendered)"
            }
        }

        line += "\n"

        guard let data = line.data(using: .utf8) else { return }
        buffer.append(data)

        if buffer.count >= maxBufferedBytes {
            flushLocked()
        } else {
            scheduleFlushLocked()
        }
    }

    private func scheduleFlushLocked() {
        flushWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushLocked()
        }
        flushWorkItem = workItem
        queue.asyncAfter(deadline: .now() + flushDelay, execute: workItem)
    }

    private func flushLocked() {
        guard !buffer.isEmpty else { return }
        do {
            try ensureActiveFileLocked()
            if activeFileSize + UInt64(buffer.count) > maxFileSizeBytes {
                try rotateLogFileLocked()
            }
            try ensureActiveFileLocked()
            guard let handle = activeHandle else { return }
            try handle.write(contentsOf: buffer)
            activeFileSize += UInt64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
        } catch {
            buffer.removeAll(keepingCapacity: true)
        }
    }

    private func setupLocked() {
        do {
            _ = try logDirectoryLocked()
            try rotateLogFileLocked()
            cleanupOldFilesLocked()
        } catch {
            // keep silent: logger should never break app flow
        }
    }

    private func logDirectoryLocked() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("DiagnosticsLogs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func rotateLogFileLocked() throws {
        closeActiveFileLocked()
        let directory = try logDirectoryLocked()
        let fileName = "log_\(fileTimestamp()).txt"
        let fileURL = directory.appendingPathComponent(fileName)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        activeFileURL = fileURL
        activeHandle = try FileHandle(forWritingTo: fileURL)
        activeFileSize = 0
        cleanupOldFilesLocked()
    }

    private func closeActiveFileLocked() {
        try? activeHandle?.close()
        activeHandle = nil
        activeFileURL = nil
        activeFileSize = 0
    }

    private func ensureActiveFileLocked() throws {
        guard let activeFileURL else {
            try rotateLogFileLocked()
            return
        }
        if activeHandle == nil {
            activeHandle = try FileHandle(forWritingTo: activeFileURL)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: activeFileURL.path),
               let size = attrs[.size] as? UInt64 {
                activeFileSize = size
            }
        }
    }

    private func cleanupOldFilesLocked() {
        let files = logFilesLocked()
        guard files.count > maxFileCount else { return }
        let toDelete = files.prefix(files.count - maxFileCount)
        for file in toDelete {
            if file != activeFileURL {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func logFilesLocked() -> [URL] {
        guard let dir = try? logDirectoryLocked(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.creationDateKey],
                options: .skipsHiddenFiles
              ) else {
            return []
        }

        return files
            .filter { $0.lastPathComponent.hasPrefix("log_") && $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func exportLocked() throws -> URL {
        let files = logFilesLocked()
        let tempDir = FileManager.default.temporaryDirectory
        let exportURL = tempDir.appendingPathComponent("BeadInventory_diagnostics_\(fileTimestamp()).txt")
        FileManager.default.createFile(atPath: exportURL.path, contents: nil)

        let handle = try FileHandle(forWritingTo: exportURL)
        defer { try? handle.close() }

        let header = """
        BeadInventory Diagnostics
        generatedAt=\(formatter.string(from: Date()))
        appVersion=\(Self.appVersion())
        build=\(Self.buildVersion())
        ios=\(UIDevice.current.systemVersion)
        device=\(Self.deviceModelIdentifier())
        locale=\(Locale.current.identifier)
        timezone=\(TimeZone.current.identifier)
        logFileCount=\(files.count)
        ---

        """

        if let headerData = header.data(using: .utf8) {
            try handle.write(contentsOf: headerData)
        }

        for file in files {
            let separator = "\n===== \(file.lastPathComponent) =====\n"
            if let separatorData = separator.data(using: .utf8) {
                try handle.write(contentsOf: separatorData)
            }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            try handle.write(contentsOf: data)
        }

        return exportURL
    }

    private func sanitize(message: String) -> String {
        let sanitized = message
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if sanitized.count <= maxFieldLength {
            return sanitized
        }
        let endIndex = sanitized.index(sanitized.startIndex, offsetBy: maxFieldLength)
        return "\(sanitized[..<endIndex])..."
    }

    private func redactIfNeeded(key: String, value: String) -> String {
        let lowerKey = key.lowercased()
        let sensitiveHints = ["key", "token", "password", "secret", "authorization"]
        if sensitiveHints.contains(where: { lowerKey.contains($0) }) {
            return "***"
        }
        return value
    }

    private func fileTimestamp() -> String {
        let fileFormatter = DateFormatter()
        fileFormatter.calendar = Calendar(identifier: .gregorian)
        fileFormatter.locale = Locale(identifier: "en_US_POSIX")
        fileFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        fileFormatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return fileFormatter.string(from: Date())
    }

    private static func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private static func buildVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { cString in
                String(cString: cString)
            }
        }
    }
}
