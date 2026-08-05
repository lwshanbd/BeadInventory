//
//  HistorySnapshotCompactor.swift
//  BeadInventory
//
//  给 `SDHistoryRecord.beforeSnapshot / afterSnapshot` 里的图片瘦身。
//
//  ## 为什么历史表是第二个独立的膨胀源
//
//  快照是 `JSONEncoder` 编出来的，而 `JSONEncoder` 把 `Data` 编成 **base64**（+33%）。
//  `capturesImages: true` 的操作（改封面图、改成品图、删项目）会把整张原图塞进快照：
//
//      13 MB 原图 → base64 ≈ 17 MB
//      `.projectUpdate` 还会把同一份快照**同时**写进 before 和 after 两列 → 单条 ~34 MB
//      `maxRecords = 100` → 历史表单独可达 GB 级
//
//  项目表瘦身之后如果不管历史表，库照样是 GB 级，CoreData+CloudKit 的
//  vacuum / WAL checkpoint 照样持 EXCLUSIVE 锁数十秒，scene-create 看门狗照样杀。
//
//  ## 为什么按 JSON 通用遍历做，而不是按类型解码
//
//  快照有好几种形状（`ProjectSnapshot`、`MergeSnapshot`、删除快照里还嵌着子项目数组），
//  按具体类型解码就要在这里枚举全部类型 —— 以后新增一种就漏一种，而且漏了没有任何症状
//  （只是那类快照永远不瘦身）。
//
//  改成把快照当**普通 JSON** 递归遍历，遇到叫 `thumbnail` / `finishedImage` /
//  `displayThumbnail` 的 base64 字符串就重编码。形状无关，嵌套多深都覆盖得到，
//  新增快照类型自动生效。其余字段原样透传。
//
//  ## 撤回语义完全不变
//
//  图片**还在**快照里，只是变小了 —— 跟项目行的瘦身是同一个取舍（同分辨率、撤回无损 PNG）。
//  这里刻意**不**做「删掉老快照里的图」那种省地方的做法：`.projectDelete` 的快照是那张图
//  删除之后的唯一拷贝，删了就是永久数据丢失。

import Foundation

enum HistorySnapshotCompactor {

    /// 快照 JSON 里承载图片字节的字段名。与 `ProjectSnapshot` 的 CodingKeys 对应。
    private static let imageKeys: Set<String> = ["thumbnail", "finishedImage", "displayThumbnail"]

    struct Result {
        let data: Data
        let bytesSaved: Int
    }

    /// 重编码快照里的图片。
    /// - Returns: 新字节；无需改动 / 解不开 → nil（调用方保持原样）。
    static func compact(_ snapshotJSON: Data) -> Result? {
        guard let root = try? JSONSerialization.jsonObject(
            with: snapshotJSON, options: [.fragmentsAllowed]
        ) else {
            AppLogger.shared.error("HistorySnapshotCompactor", "snapshot_not_json", metadata: [
                "bytes": snapshotJSON.count
            ])
            return nil
        }

        var changed = false
        let rewritten = rewrite(root, changed: &changed)
        guard changed else { return nil }

        guard let out = try? JSONSerialization.data(
            withJSONObject: rewritten, options: [.fragmentsAllowed]
        ) else {
            AppLogger.shared.error("HistorySnapshotCompactor", "reencode_failed", metadata: [
                "bytes": snapshotJSON.count
            ])
            return nil
        }
        // 理论上不该发生（图变小了整体就该变小），但如果真变大了就别写回去。
        guard out.count < snapshotJSON.count else { return nil }
        return Result(data: out, bytesSaved: snapshotJSON.count - out.count)
    }

    private static func rewrite(_ node: Any, changed: inout Bool) -> Any {
        if let dict = node as? [String: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (key, value) in dict {
                if imageKeys.contains(key),
                   let base64 = value as? String,
                   let raw = Data(base64Encoded: base64),
                   let recompressed = ProjectImageEncoder.recompress(raw) {
                    out[key] = recompressed.data.base64EncodedString()
                    changed = true
                } else {
                    out[key] = rewrite(value, changed: &changed)
                }
            }
            return out
        }
        if let array = node as? [Any] {
            return array.map { rewrite($0, changed: &changed) }
        }
        return node
    }
}
