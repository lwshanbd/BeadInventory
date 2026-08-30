//
//  BeadPartsBoard.swift
//  BeadInventory
//
//  多零件模式 · 拼豆板
//
//  前面几步的产物是「五十几个零件，每个零件哪一格是什么色号」。但人拼的时候
//  手上是一块**固定格数的拼豆板**，一块放不下就分几次烫。所以还差最后一层：
//  这些零件分别摆在第几块板的第几格。
//
//  ## 为什么零件之间必须空格
//
//  拼豆是要拿熨斗烫的，挨着的两颗豆子烫完就连成一片。两个零件在板上贴着放，
//  烫完得拿剪刀分开 —— 那一刀下去边缘就毁了。所以这里的「放得下」不是
//  「豆子不重叠」，而是**任意两个零件的豆子之间至少隔一格**（斜着挨着也算挨着，
//  拼豆板上斜角的两颗豆子是碰得到的）。
//
//  一格是**底线**，不是唯一答案：剪刀下得开不开、板子拿在手上顺不顺手，
//  这是买了什么剪刀、拼多大件的人自己知道的事。所以留多宽由用户选，
//  见 `BoardSpacing` —— 但没有「零间距」这一档：贴着摆当然摆得下，
//  只是烫完连成一片、那一刀下去边缘就毁了。
//
//  ## 坐标约定
//
//  板上的一切都是整数格：`PartPlacement.col/row` 是零件那张 `cells` 矩阵的
//  左上角落在板上的第几格。注意 `cells` 四周通常还带着一圈空白（它是从图纸上
//  切下来的矩形），所以真正占地方的是**去掉空白之后**的那一块，见 `PartFootprint`。
//

import Foundation

// MARK: - 板子尺寸

/// 一块板多少格。用户手上是哪一种由他自己选，不做检测也不做推荐 ——
/// 这是买板子时就定好的事实，不是算法能猜的东西。
///
/// `presets` 只是几个常见规格，**不是全集**：长方形的板、几块并起来当一整块用的拼台、
/// 买到的杂牌板，格数都不在这几个里。所以格数还可以自己填（见 `customRange` 和
/// `BoardSizeCustomSheet`），填过的记在 `recentsKey` 那份偏好里（写用 `remember`、
/// 读用 `decodeList`），下次在菜单里直接点。
struct BeadBoardSize: Hashable, Sendable, Identifiable {
    var cols: Int
    var rows: Int

    var id: String { "\(cols)x\(rows)" }
    var label: String { "\(cols) × \(rows)" }

    static let presets: [BeadBoardSize] = [
        BeadBoardSize(cols: 50, rows: 50),
        BeadBoardSize(cols: 52, rows: 52),
        BeadBoardSize(cols: 75, rows: 75),
        BeadBoardSize(cols: 78, rows: 78),
        BeadBoardSize(cols: 100, rows: 100),
        BeadBoardSize(cols: 104, rows: 104)
    ]

    /// 自己填的格数收在这个范围里。
    ///
    /// 下界是 5：输入框里手一抖打出个 `1` 是常事，而一块 1 × 1 的板什么都放不下 ——
    /// `PartsBoardPacker.placeOne` 在放不下时压根不新建板，用户得到的是「排了 0 块板、
    /// N 个零件没摆下」一屏空状态。上界 300 不是物理极限，是「再大就不是一块板了」：
    /// 市面上最大的一块是 104 格，几块拼台并起来当整块算也就一两百格。
    ///
    /// **这条只管手填那一屏。** 派生出来的板不受它管，也不该受 —— 外屏没内容时的
    /// 占位板是 1 × 1（`BoardExternalDisplay`），单图纸模式把整张图纸当一块板投，
    /// 列数直接来自图纸（可以超过 300）。所以这里不做成构造时的硬不变量。
    static let customRange = 5...300

    var isValidCustom: Bool {
        BeadBoardSize.customRange.contains(cols) && BeadBoardSize.customRange.contains(rows)
    }

    var isPreset: Bool { BeadBoardSize.presets.contains(self) }

    // MARK: - 自己填过的那几块板

    // 用户手上是哪几块板，是买板子时就定好的事实，不属于任何一张图纸 ——
    // 所以存在 `@AppStorage` 里（一行 `"60x40,29x29"`），跟着人走，不进 BeadPartsSheet。
    // 认不出的段直接丢掉：这份偏好坏了最多是菜单里少一项，不该把人卡在这儿。

    /// 三处挑板子的菜单读的是同一份偏好。key 写死在各自文件里的话，打错一个字母
    /// 不报错也不崩，只是用户在投影仪那屏填的板在拼豆板那屏点不到 —— 看起来像没记住。
    static let recentsKey = "boardCustomSizes"

    static func decodeList(_ raw: String) -> [BeadBoardSize] {
        raw.split(separator: ",").compactMap { chunk in
            let parts = chunk.split(separator: "x")
            guard parts.count == 2,
                  let cols = Int(parts[0]), let rows = Int(parts[1]) else { return nil }
            let size = BeadBoardSize(cols: cols, rows: rows)
            return size.isValidCustom ? size : nil
        }
    }

    /// 只给 `remember` 用 —— 别处直接写这份偏好就绕过了「最多三块 / 不重复 / 不记常见规格」。
    private static func encodeList(_ sizes: [BeadBoardSize]) -> String {
        sizes.map(\.id).joined(separator: ",")
    }

    /// 把刚用上的这块记到最前面，最多留三块。已经在列表里的会挪到最前，不会重复。
    ///
    /// 只留三块是因为这是个菜单里的快捷入口，不是一份清单 —— 手上真有第四块板的人，
    /// 再填一次也就两下的事，而一串记不清哪个是哪个的数字反而让常用那块更难找。
    ///
    /// 常见规格原样返回、不记：菜单里本来就有它，记了等于同一块板列两遍。越界的同理。
    /// 所以调用方不用自己先判断，尺寸真正生效的地方调一下就行。
    static func remember(_ size: BeadBoardSize, in raw: String) -> String {
        guard size.isValidCustom, !size.isPreset else { return raw }
        var list = decodeList(raw).filter { $0 != size }
        list.insert(size, at: 0)
        return encodeList(Array(list.prefix(3)))
    }
}

// MARK: - 摆得多松

/// 零件之间、以及零件跟板子边缘之间留多宽。
///
/// 三档不是三个算法参数，是三种**动手时的打算**：一块板多塞几个，还是留出下剪刀
/// 和拿板子的余地。所以名字和说明都按「手上会不一样在哪儿」写，不写格数以外的东西。
///
/// 为什么最紧的一档仍然是一格：烫的时候挨着的豆子会连成一片（见文件头），
/// 「零间距」不是一个更省地方的选项，是一个拼完得报废的选项。
///
/// **加第四档之前先看这里**：`rawValue` 会跟着图纸存进 `BeadPartsSheet`，而
/// `BackupManager` 是带着图纸原始字节跨设备走的。合成的 Decodable 遇到不认识的
/// rawValue 会**抛**（不像 `@AppStorage` 那样退回默认值），一抛就是整张图纸解不出来
/// —— 用户丢的是零件和色号，不是一个装饰性字段。真要加，得先给这个字段写个
/// 认不出就当 nil 的自定义 `init(from:)`。
enum BoardSpacing: String, CaseIterable, Codable, Sendable, Identifiable {
    /// 零件之间空一格，板子边上也用满 —— 一块板放得最多。
    case tight
    /// 零件之间空一格，板子最外面一圈留空。
    case standard
    /// 零件之间空两格，板子最外面一圈也留空。
    case loose

    var id: String { rawValue }

    /// 两个零件的豆子之间至少空几格
    var gap: Int {
        switch self {
        case .tight, .standard: return 1
        case .loose: return 2
        }
    }

    /// 板子四周留几行/几列不放豆子
    var margin: Int {
        switch self {
        case .tight: return 0
        case .standard, .loose: return 1
        }
    }

    var label: String {
        switch self {
        case .tight: return String(localized: "紧凑")
        case .standard: return String(localized: "默认")
        case .loose: return String(localized: "宽松")
        }
    }

    /// 菜单里跟在名字后面的一句话。说的是选了它板子上会变成什么样，不是它怎么算的。
    var detail: String {
        switch self {
        case .tight: return String(localized: "零件之间空一格，板边也用满，一块板放得最多")
        case .standard: return String(localized: "零件之间空一格，板子最外面一圈留空")
        case .loose: return String(localized: "零件之间空两格，板子最外面一圈留空")
        }
    }
}

// MARK: - 一个零件摆在板上

struct PartPlacement: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var partId: UUID
    /// 零件 `cells` 矩阵左上角在板上的格坐标
    var col: Int
    var row: Int
    /// 顺时针转了几个 90°（0~3）。拼豆转 90° 拼出来是一样的，
    /// 细长的零件竖着放不下、横着放得下时全靠它。
    var turns: Int

    init(id: UUID = UUID(), partId: UUID, col: Int, row: Int, turns: Int = 0) {
        self.id = id
        self.partId = partId
        self.col = col
        self.row = row
        // 转 4 次等于没转，所以只有 0~3 有意义。这里就归一化掉：
        // 形状缓存是拿 turns 当键的，留着 4 的话同一个朝向会被当成两种形状白算一遍。
        self.turns = ((turns % 4) + 4) % 4
    }
}

// MARK: - 一块板

struct PartsBoard: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var cols: Int
    var rows: Int
    var placements: [PartPlacement]
    /// 这块板上哪些色号已经拼完了。key 是色号（`PartCellFill.groupKey`），
    /// value 是**按下「已完成」那一刻，这块板上这个色号有多少颗**。
    ///
    /// 记颗数而不是只记一个「拼过了」：板上的格子随时能擦 / 补（`PartCellBrushView`），
    /// 补进来三颗 H7 之后那个勾还挂着的话，用户照着勾把它跳过去，正好漏掉那三颗 ——
    /// 而这个标记本来就是为了防漏。颗数对不上就当没标记过，勾自己消失。
    ///
    /// 跟着板走，不是跟着零件走：同一个色号在第 1 块板上拼完了，第 2 块板上还没拼。
    ///
    /// 刻意用 Optional（理由同 `BeadPartsSheet.boards`）：合成的 `init(from:)` 不认
    /// 属性默认值，缺字段一律抛错 —— 存量图纸会整份打不开。
    var doneColors: [String: Int]?

    init(id: UUID = UUID(), size: BeadBoardSize, placements: [PartPlacement] = [],
         doneColors: [String: Int]? = nil) {
        self.id = id
        self.cols = size.cols
        self.rows = size.rows
        self.placements = placements
        self.doneColors = doneColors
    }

    var size: BeadBoardSize { BeadBoardSize(cols: cols, rows: rows) }

    // MARK: - 这个色拼完了

    /// 这个色号在这块板上算不算已经拼完。`count` 传板上现在有多少颗。
    func isColorDone(_ key: String, count: Int) -> Bool {
        doneColors?[key] == count
    }

    mutating func markColorDone(_ key: String, count: Int) {
        var next = doneColors ?? [:]
        next[key] = count
        doneColors = next
    }

    mutating func clearColorDone(_ key: String) {
        guard var next = doneColors else { return }
        next.removeValue(forKey: key)
        doneColors = next.isEmpty ? nil : next
    }

    /// 板上已经没有的色号，标记跟着作废 —— 零件被挪去别的板、或者那个色号被擦光了。
    /// 留着的话，用户把零件挪回来时会看到一个不知道哪来的勾。
    mutating func pruneDoneColors(keeping keys: Set<String>) {
        guard let current = doneColors else { return }
        let kept = current.filter { keys.contains($0.key) }
        doneColors = kept.isEmpty ? nil : kept
    }
}

// MARK: - 色号条的顺序

/// 色号条 / 色号列表的排序规则 —— 判色、拼板、投影、补格子四处共用这一份。
///
/// **颗数一样时必须有一个说得死的次序。** 只写「颗数从多到少」的话，几个颗数相同的
/// 色号谁前谁后由字典的遍历顺序决定：改一格色号、翻一块板、重进一次这一屏，它们的
/// 相对位置就换一次。而用户是照着这条色号条一个一个抓豆子拼的 —— 两个色号前后一换，
/// 他会以为后面那个已经拼过，直接跳过去，那一板就漏了一个色，得拆开重拼。
///
/// 并列时按色号本身排，并且用 `localizedStandardCompare`：H7 在 H10 前面
///（纯字典序会把 H10 排到 H7 前面，色号条上看着就是乱的）。
enum BeadColorTally {
    /// 颗数多的在前；一样多时按色号排。
    static func precedes(_ lhs: (key: String, count: Int), _ rhs: (key: String, count: Int)) -> Bool {
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
    }

    /// 把「色号 → 颗数」按上面这条规矩排成一条。
    static func ordered(_ counts: [String: Int]) -> [(key: String, count: Int)] {
        counts.map { (key: $0.key, count: $0.value) }.sorted { precedes($0, $1) }
    }
}

// MARK: - 零件转向之后长什么样

extension PartCellFill {
    /// 同一类格子的共用标识。色号用色号本身，空和任意色用两个不会跟色号撞的名字。
    var groupKey: String {
        switch self {
        case .empty: return "#empty"
        case .anyColor: return "#any"
        case .code(let code): return code
        }
    }
}

/// 一个零件（转过若干次之后）在板上真正占的那一块。
///
/// `cells` 是从图纸上按矩形切下来的，四周多半带着一圈背景空白。摆板子时要是按
/// 整个矩形算，零件之间会凭空多出好几格的缝，一块板少放好几个零件。所以这里
/// 把有豆子的格子单独拎出来（`beads`），并记下它们相对矩形原点的偏移范围。
struct PartFootprint: Sendable {
    struct Bead: Sendable {
        let col: Int
        let row: Int
        /// 这颗豆子是什么色号（或任意色），画板子时按它取颜色
        let key: String
    }

    let beads: [Bead]
    /// 有豆子的那一块相对 `cells` 原点的偏移和大小
    let minCol: Int
    let minRow: Int
    let width: Int
    let height: Int
    /// 哪些格有豆子。画轮廓时要判断「这一边外面还是不是自己」，
    /// 一个零件上千颗豆子，逐颗去数组里找会卡。
    private let occupied: Set<Int>

    var isEmpty: Bool { beads.isEmpty }

    /// 这一格（相对 `cells` 原点）是不是自己的豆子
    func hasBead(col: Int, row: Int) -> Bool {
        // 负坐标是常态（描轮廓要问「上面一格是不是自己」，板上点选也会算出负的相对坐标），
        // 而 key 的位移编码把 -1 编成 65535，跟第 65535 行撞。零件的格子不可能是负的，直接挡掉。
        guard col >= 0, row >= 0 else { return false }
        return occupied.contains(Self.key(col: col, row: row))
    }

    private static func key(col: Int, row: Int) -> Int { (col << 16) | (row & 0xFFFF) }

    init(cells: [[PartCellFill]]) {
        var beads: [Bead] = []
        var occupied: Set<Int> = []
        var minC = Int.max, minR = Int.max, maxC = Int.min, maxR = Int.min
        for (r, row) in cells.enumerated() {
            for (c, cell) in row.enumerated() where cell.needsBead {
                beads.append(Bead(col: c, row: r, key: cell.groupKey))
                occupied.insert(Self.key(col: c, row: r))
                minC = min(minC, c); maxC = max(maxC, c)
                minR = min(minR, r); maxR = max(maxR, r)
            }
        }
        self.beads = beads
        self.occupied = occupied
        if beads.isEmpty {
            minCol = 0; minRow = 0; width = 0; height = 0
        } else {
            minCol = minC; minRow = minR
            width = maxC - minC + 1
            height = maxR - minR + 1
        }
    }
}

extension BeadPart {
    /// 顺时针转 `turns` 个 90° 之后的格子内容
    func rotatedCells(turns: Int) -> [[PartCellFill]] {
        var result = cells
        for _ in 0..<((turns % 4) + 4) % 4 {
            result = Self.rotatedOnce(result)
        }
        return result
    }

    private static func rotatedOnce(_ matrix: [[PartCellFill]]) -> [[PartCellFill]] {
        guard let first = matrix.first else { return matrix }
        let rows = matrix.count
        let cols = first.count
        var out = Array(repeating: Array(repeating: PartCellFill.empty, count: rows), count: cols)
        for r in 0..<rows {
            for c in 0..<min(cols, matrix[r].count) {
                out[c][rows - 1 - r] = matrix[r][c]
            }
        }
        return out
    }

    func footprint(turns: Int) -> PartFootprint {
        PartFootprint(cells: rotatedCells(turns: turns))
    }
}

// MARK: - 板上哪些格被占了

/// 板子的占位表。存的不是「有豆子」，而是「**不能再放豆子**」——
/// 每颗豆子连同它周围 `spacing.gap` 圈（含斜角）都记上，这样「放得下」直接查表就行，
/// 空格子的规矩自然而然被满足（见文件头）。
///
/// 边上要留的那一圈也是这么处理的：建表时就把它标成「占了」。这样「放得下吗」
/// 只有 `canPlace` 一处判定，自动排、点零件条落位、拖动校验全都走它 ——
/// 少判一处就是一条能钻的缝，而钻进去的后果要等用户拼到那儿才发现。
///
/// （`firstFit` 的扫描范围、`blockedByEdge`、`PartsBoardRepair.offendingPlacements` 各有
/// 一份 margin 算术：一个为了少扫、一个为了分辨失败原因、一个为了一次扫完整块板。
/// 前两处不参与判定，第三处参与。margin 要是哪天不再是 0/1，这四处一起改。）
struct BoardOccupancy: Sendable {
    let cols: Int
    let rows: Int
    let spacing: BoardSpacing
    private var blocked: [Bool]

    /// 板子上真正能放豆子的范围（去掉四周留边之后）
    var usableCols: Int { cols - 2 * spacing.margin }
    var usableRows: Int { rows - 2 * spacing.margin }

    init(cols: Int, rows: Int, spacing: BoardSpacing) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        self.spacing = spacing
        blocked = Array(repeating: false, count: self.cols * self.rows)

        let margin = spacing.margin
        guard margin > 0 else { return }
        for r in 0..<self.rows {
            for c in 0..<self.cols
            where r < margin || c < margin || r >= self.rows - margin || c >= self.cols - margin {
                blocked[r * self.cols + c] = true
            }
        }
    }

    /// 零件矩阵左上角放在 (col, row) 时，豆子是不是都落在可用范围内、且都不挨着别的零件
    func canPlace(_ footprint: PartFootprint, col: Int, row: Int) -> Bool {
        guard !footprint.isEmpty else { return false }
        for bead in footprint.beads {
            let c = col + bead.col
            let r = row + bead.row
            guard c >= 0, r >= 0, c < cols, r < rows else { return false }
            if blocked[r * cols + c] { return false }
        }
        return true
    }

    /// 放不下是因为顶到了板子的边（板外，或者边上留的那一圈），而不是挨着了别的零件。
    /// 两种情况下用户该做的事完全不同 —— 一个是「往里挪」，一个是「先挪开别的」，
    /// 所以拖动失败时得分得清，不能都甩一句「这儿放不下」。
    func blockedByEdge(_ footprint: PartFootprint, col: Int, row: Int) -> Bool {
        let margin = spacing.margin
        for bead in footprint.beads {
            let c = col + bead.col
            let r = row + bead.row
            if c < margin || r < margin || c >= cols - margin || r >= rows - margin { return true }
        }
        return false
    }

    mutating func add(_ footprint: PartFootprint, col: Int, row: Int) {
        let gap = spacing.gap
        for bead in footprint.beads {
            for dr in -gap...gap {
                for dc in -gap...gap {
                    let c = col + bead.col + dc
                    let r = row + bead.row + dr
                    guard c >= 0, r >= 0, c < cols, r < rows else { continue }
                    blocked[r * cols + c] = true
                }
            }
        }
    }
}

// MARK: - 板上摆位的体检

/// 走一遍所有板子，把已经不成立的摆位挑出来、能修的就地修好。
///
/// ## 为什么需要它
///
/// 摆位是在**当时那个零件形状**下算出来的合法位置。零件的格子后来还能改（擦掉 / 补上），
/// 而改格子的入口有两个：拼豆板那屏（改完就在眼前），和核对颜色那屏（改完人还在别的屏，
/// 板子在后台被悄悄推翻）。少了这一遍，第二条路上补出来的格子会让两个零件贴上，
/// **而贴着的零件烫完连成一片，那一刀下去边缘就毁了**（见文件头）—— 用户是在熨斗底下
/// 发现的，那时候豆子已经摆完了。
///
/// 所以判定只写这一份，谁都不要各写各的：拼豆板进屏时跑一遍（把别处改出来的问题兜住），
/// 改完格子再跑一遍（同一遍，全量 —— 一块板五十个零件也就几毫秒，不值得为「只查一个」
/// 再写一条会跟这条漂移的路）。
///
/// ## 三种结果，对应三种不同的话
///
///   拿下来  这个零件一颗豆子都不剩了（或者零件本身已经不在图纸上了）。留着是一个
///           画不出来、点不到、也拿不下来的幽灵摆位，只会让板头那句
///           「摆了 27 个零件」多算一个。
///   挪走    原地放不下，但同一块板上还有空地。挪过去，然后**说一句**（还报名字，
///           只挪了一个的时候）—— 位置是用户自己摆的，动了他的东西必须让他知道。
///   挪不动  这块板上哪儿都放不下（`firstFit` 只在同一块板里找）。**留在原地**，
///           由界面显式标出来（描红边 + 常驻提示 + 拦「完成」）：悄悄拿下来的话，
///           用户刚补完一格零件就从板上消失了；而一声不响留着，等于让他照着一块
///           拼出来会粘连的板去烫。这一类不进返回值 —— 它是板子**当下**的状态，
///           随时用 `offendingPlacements(in:)` 问，别缓存。
enum PartsBoardRepair {
    struct Outcome: Equatable {
        /// 挪到别处去了的零件
        var moved: [UUID] = []
        /// 一颗豆子都不剩、已经拿下来的零件
        var removed: [UUID] = []
        /// 板上已经没有对应零件、被当成孤儿清掉的摆放（对应的零件 id）。
        /// 跟 `removed` 分开，是因为对用户说的话不一样：那种「回核对页补格子」找得回来，
        /// 这种找不回来 —— 零件本身已经不在图纸上了。
        var orphaned: [UUID] = []

        var isEmpty: Bool { moved.isEmpty && removed.isEmpty && orphaned.isEmpty }
    }

    /// 把板子修到合法，并报告改了什么。
    ///
    /// **不报告「还挨着的有哪些」** —— 那是板子**当下**的状态，不是这一次调用干了什么。
    /// 早先它也在返回值里，调用方顺手把它缓存进 @State，然后用户一拖一转一重排，
    /// 缓存就开始骗人：红的还红着、「完成」还拦着，而板子明明已经好了。
    /// 要问「现在还有谁站不住」，随时调 `offendingPlacements(in:)`，它不改任何东西。
    @discardableResult
    static func repair(
        boards: inout [PartsBoard],
        parts: [BeadPart],
        spacing: BoardSpacing
    ) -> Outcome {
        var outcome = Outcome()
        let byId = Dictionary(parts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for index in boards.indices {
            // 1. 空零件、以及已经不存在的零件，先拿下来
            boards[index].placements.removeAll { placement in
                guard let part = byId[placement.partId] else {
                    outcome.orphaned.append(placement.partId)
                    return true
                }
                guard part.footprint(turns: placement.turns).isEmpty else { return false }
                outcome.removed.append(placement.partId)
                return true
            }

            // 2. 剩下的挑出真正站不住的那几个
            for offender in offendingPlacements(in: boards[index], parts: parts, spacing: spacing) {
                guard let slot = boards[index].placements.firstIndex(where: { $0.id == offender }),
                      let part = byId[boards[index].placements[slot].partId] else { continue }
                let placement = boards[index].placements[slot]
                let footprint = part.footprint(turns: placement.turns)
                let occupancy = PartsBoardPacker.occupancy(of: boards[index], parts: parts,
                                                           spacing: spacing, ignoring: placement.id)
                // 前一个零件挪走之后这个可能自己就合法了，所以每次都重新问一遍
                if occupancy.canPlace(footprint, col: placement.col, row: placement.row) { continue }
                // 挪得动就挪。挪不动就留在原地 —— 悄悄拿下来的话，用户刚补完一格
                // 零件就从板上消失了。留下的那些由 `offendingPlacements` 随时报得出来。
                guard let spot = PartsBoardPacker.firstFit(footprint, occupancy: occupancy) else { continue }
                boards[index].placements[slot].col = spot.col
                boards[index].placements[slot].row = spot.row
                outcome.moved.append(placement.partId)
            }
        }
        return outcome
    }

    /// 这块板上现在有哪些摆放站不住（**摆放** id）。纯查询，不改任何东西。
    ///
    /// 判定跟 `BoardOccupancy.canPlace` 完全等价，只是一次扫完，不是每个摆位各建一张
    /// 占位表：一块板上五十个零件、每个上千颗豆子，各建一张就是五十遍全表，
    /// 而这个查询要在每次画板子、每次改动之后跑。
    ///
    /// 办法是数「每一格被**几个零件**的扩张区盖住」：某颗豆子所在的格子被两个以上零件
    /// 盖住 ⟺ 它挨上了别人。出界和压到留边另算。
    ///
    /// **每个零件对同一格只能记一次。** 早先这里是按「豆子×扩张」逐次 +1 的，
    /// 于是零件自己相邻的豆子把自己的格子叠到了 2 —— 板上每个多颗豆子的零件都成了
    /// 「挨着别人」。当时靠 `repair` 里那道 `canPlace` 复查兜住了结果，
    /// 但整个「一次扫完」的省事全白搭：每个摆位照样各建了一张全表。
    static func offendingPlacements(
        in board: PartsBoard,
        parts: [BeadPart],
        spacing: BoardSpacing
    ) -> Set<UUID> {
        guard !board.placements.isEmpty else { return [] }
        let cols = max(1, board.cols)
        let rows = max(1, board.rows)
        let gap = spacing.gap
        let margin = spacing.margin
        let byId = Dictionary(parts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var covered = [Int32](repeating: 0, count: cols * rows)
        /// 这一格上一次是被第几个摆位盖的。同一个摆位重复盖到就不再记 —— 见上面那段。
        var stamp = [Int32](repeating: -1, count: cols * rows)
        var shapes: [(id: UUID, footprint: PartFootprint, col: Int, row: Int)] = []
        for (order, placement) in board.placements.enumerated() {
            guard let part = byId[placement.partId] else { continue }
            let footprint = part.footprint(turns: placement.turns)
            shapes.append((placement.id, footprint, placement.col, placement.row))
            let tag = Int32(order)
            for bead in footprint.beads {
                for dr in -gap...gap {
                    for dc in -gap...gap {
                        let c = placement.col + bead.col + dc
                        let r = placement.row + bead.row + dr
                        guard c >= 0, r >= 0, c < cols, r < rows else { continue }
                        let index = r * cols + c
                        guard stamp[index] != tag else { continue }
                        stamp[index] = tag
                        covered[index] += 1
                    }
                }
            }
        }

        var result: Set<UUID> = []
        for shape in shapes {
            for bead in shape.footprint.beads {
                let c = shape.col + bead.col
                let r = shape.row + bead.row
                // 出板、压到四周留边：都是「站不住」。这一条也覆盖了「整个零件都在板外」
                // —— 那种情况下面那句根本读不到格子。
                if c < margin || r < margin || c >= cols - margin || r >= rows - margin {
                    result.insert(shape.id)
                    break
                }
                if covered[r * cols + c] >= 2 {
                    result.insert(shape.id)
                    break
                }
            }
        }
        return result
    }

    /// 所有板子上还站不住的摆放，按板子分。给界面画红和数数用。
    static func offendingPlacements(
        in boards: [PartsBoard],
        parts: [BeadPart],
        spacing: BoardSpacing
    ) -> Set<UUID> {
        var result: Set<UUID> = []
        for board in boards {
            result.formUnion(offendingPlacements(in: board, parts: parts, spacing: spacing))
        }
        return result
    }
}

// MARK: - 自动排

/// 把零件铺到板上。
///
/// 用的是「从上到下、从左到右找第一个放得下的地方」，零件按高矮排过序。
/// 不追求最优装箱：多塞进去一两个零件的收益，远不如「排出来的样子跟图纸上
/// 差不多、用户一眼认得出哪个是哪个」重要 —— 而且他随时能自己拖。
///
/// 留多宽（`BoardSpacing`）由调用方给，这里不挑也不猜：它是用户选的，
/// 而且必须跟拖动校验用的是同一档，否则自动排出来的样子一拖就变成非法的。
enum PartsBoardPacker {
    /// 板上已经摆了的东西占了哪些格。`ignoring` 用来在拖某个零件时把它自己排除掉。
    static func occupancy(
        of board: PartsBoard,
        parts: [BeadPart],
        spacing: BoardSpacing,
        ignoring: UUID? = nil
    ) -> BoardOccupancy {
        var occupancy = BoardOccupancy(cols: board.cols, rows: board.rows, spacing: spacing)
        for placement in board.placements where placement.id != ignoring {
            guard let part = parts.first(where: { $0.id == placement.partId }) else { continue }
            occupancy.add(part.footprint(turns: placement.turns), col: placement.col, row: placement.row)
        }
        return occupancy
    }

    /// 在这块板上找第一个放得下的位置（返回的是零件矩阵左上角该放哪儿）。
    /// 扫的范围是**去掉留边之后**那一块 —— 留边里的格子建表时就标死了，
    /// 扫进去只是白扫一遍。
    ///
    /// 但底下那两个 `usable` 判断松不得：换回 `<= occupancy.rows` 的话，
    /// 50 行的板配 49 高的零件、margin 为 1，下面那个区间会变成 `1...0` —— 直接崩，
    /// 不是返回 nil。
    static func firstFit(
        _ footprint: PartFootprint,
        occupancy: BoardOccupancy
    ) -> (col: Int, row: Int)? {
        guard !footprint.isEmpty,
              footprint.width <= occupancy.usableCols,
              footprint.height <= occupancy.usableRows else { return nil }
        let margin = occupancy.spacing.margin
        for r in margin...(occupancy.rows - margin - footprint.height) {
            for c in margin...(occupancy.cols - margin - footprint.width) {
                let col = c - footprint.minCol
                let row = r - footprint.minRow
                if occupancy.canPlace(footprint, col: col, row: row) {
                    return (col, row)
                }
            }
        }
        return nil
    }

    /// 一个零件的一种摆法
    struct Candidate: Sendable {
        let turns: Int
        let footprint: PartFootprint
    }

    /// 这个零件可以怎么摆。先试原方向（跟图纸上看到的一致，用户好认），
    /// 再试转 90°（细长件常常转过来才放得下）。
    /// `footprint` 是已经算好的原方向形状 —— 算它要重建一整个旋转矩阵，能省则省。
    static func candidates(for part: BeadPart, footprint: PartFootprint? = nil) -> [Candidate] {
        [
            Candidate(turns: 0, footprint: footprint ?? part.footprint(turns: 0)),
            Candidate(turns: 1, footprint: part.footprint(turns: 1))
        ]
    }

    /// 在一块板上找第一个放得下的摆法
    static func fit(
        _ candidates: [Candidate],
        in occupancy: BoardOccupancy
    ) -> (candidate: Candidate, col: Int, row: Int)? {
        for candidate in candidates {
            guard let spot = firstFit(candidate.footprint, occupancy: occupancy) else { continue }
            return (candidate, spot.col, spot.row)
        }
        return nil
    }

    /// 把一个零件放到已有的板里第一块放得下的那块上；都放不下就新开一块。
    ///
    /// 「先塞现有的板、塞不下再开新板」这条规矩有两个调用方（进屏自动排、「自动排」按钮），
    /// 所以只写这一份 —— 各抄一遍的话两份会各自漂移。
    /// 「点零件条里的零件」不走这里：那条只认用户当时看着的那块板（见 PartsBoardStepView.place），
    /// 它复用的是 `candidates` + `fit`，不是这条逐块板试过去的规矩。
    /// `occupancies` 跟 `boards` 一一对应，会跟着一起更新。
    ///
    /// - Returns: 落在第几块板上；连一整块空板都放不下（零件比板子还大）时返回 nil。
    @discardableResult
    static func placeOne(
        _ part: BeadPart,
        footprint: PartFootprint? = nil,
        into boards: inout [PartsBoard],
        occupancies: inout [BoardOccupancy],
        size: BeadBoardSize,
        spacing: BoardSpacing
    ) -> Int? {
        let options = candidates(for: part, footprint: footprint)

        for index in boards.indices {
            guard let hit = fit(options, in: occupancies[index]) else { continue }
            boards[index].placements.append(PartPlacement(
                partId: part.id, col: hit.col, row: hit.row, turns: hit.candidate.turns
            ))
            occupancies[index].add(hit.candidate.footprint, col: hit.col, row: hit.row)
            return index
        }

        var occupancy = BoardOccupancy(cols: size.cols, rows: size.rows, spacing: spacing)
        guard let hit = fit(options, in: occupancy) else { return nil }
        var board = PartsBoard(size: size)
        board.placements.append(PartPlacement(
            partId: part.id, col: hit.col, row: hit.row, turns: hit.candidate.turns
        ))
        occupancy.add(hit.candidate.footprint, col: hit.col, row: hit.row)
        boards.append(board)
        occupancies.append(occupancy)
        return boards.count - 1
    }

    /// 把 `parts` 全部铺到尺寸为 `size` 的板上，一块放不下就再开一块。
    /// 比板子还大的零件放不进去，会留在返回值的 `unplaced` 里 —— 这种情况用户
    /// 只能换更大的板，得让他看见，不能悄悄吞掉。
    static func pack(
        parts: [BeadPart],
        size: BeadBoardSize,
        spacing: BoardSpacing
    ) -> (boards: [PartsBoard], unplaced: [UUID]) {
        var boards: [PartsBoard] = []
        var occupancies: [BoardOccupancy] = []
        var unplaced: [UUID] = []

        for item in ordered(parts) {
            if placeOne(item.part, footprint: item.footprint, into: &boards,
                        occupancies: &occupancies, size: size, spacing: spacing) == nil {
                unplaced.append(item.part.id)
            }
        }

        return (boards, unplaced)
    }

    /// 摆放顺序：先大后小 —— 大件先占位，小件才好往缝里塞。
    /// 形状先算好再排序，别放进比较器里：那样每比一次都要重建一遍旋转矩阵。
    static func ordered(_ parts: [BeadPart]) -> [(part: BeadPart, footprint: PartFootprint)] {
        parts
            .map { (part: $0, footprint: $0.footprint(turns: 0)) }
            .filter { !$0.footprint.isEmpty }
            .sorted {
                ($0.footprint.height, $0.footprint.width) > ($1.footprint.height, $1.footprint.width)
            }
    }
}
