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

/// 市面上常见的拼豆板规格。用户手上是哪一种由他自己选，不做检测也不做推荐 ——
/// 这是买板子时就定好的事实，不是算法能猜的东西。
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

    init(id: UUID = UUID(), size: BeadBoardSize, placements: [PartPlacement] = []) {
        self.id = id
        self.cols = size.cols
        self.rows = size.rows
        self.placements = placements
    }

    var size: BeadBoardSize { BeadBoardSize(cols: cols, rows: rows) }
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
/// （`firstFit` 的扫描范围和 `blockedByEdge` 另有一份 margin 算术，那两处一个是为了
/// 少扫、一个是为了分辨失败原因，都不参与判定。margin 要是哪天不再是 0/1，这三处一起改。）
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
/// 所以判定只写这一份，谁都不要各写各的：拼豆板进屏时跑一遍（把别处改出来的问题
/// 兜住），改完格子再跑一遍（增量）。
///
/// ## 三种结果，对应三种不同的话
///
///   拿下来  这个零件一颗豆子都不剩了。留着是一个画不出来、点不到、也拿不下来的
///           幽灵摆位，只会让板头那句「摆了 27 个零件」多算一个。
///   挪走    原地放不下，但同一块板上还有空地。挪过去，然后**说一句** ——
///           位置是用户自己摆的，动了他的东西必须让他知道。
///   挪不动  哪儿都放不下。**留在原地**，交给界面显式标出来：悄悄拿下来的话，
///           用户刚补完一格零件就从板上消失了；而一声不响留着，等于让他照着一块
///           拼出来会粘连的板去烫。
enum PartsBoardRepair {
    struct Outcome: Equatable {
        /// 挪到别处去了的零件
        var moved: [UUID] = []
        /// 一颗豆子都不剩、已经拿下来的零件
        var removed: [UUID] = []
        /// 还跟旁边挨着 / 出界，但哪儿都放不下的零件（仍留在板上）
        var invalid: [UUID] = []

        var isEmpty: Bool { moved.isEmpty && removed.isEmpty && invalid.isEmpty }
    }

    static func repair(
        boards: inout [PartsBoard],
        parts: [BeadPart],
        spacing: BoardSpacing
    ) -> Outcome {
        var outcome = Outcome()
        let byId = Dictionary(parts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for index in boards.indices {
            // 1. 空零件（连同已经不存在的零件）先拿下来
            boards[index].placements.removeAll { placement in
                let footprint = byId[placement.partId]?.footprint(turns: placement.turns)
                guard footprint?.isEmpty != false else { return false }
                outcome.removed.append(placement.partId)
                return true
            }

            // 2. 剩下的挑出真正站不住的那几个
            for offender in offenders(in: boards[index], parts: parts, spacing: spacing) {
                guard let slot = boards[index].placements.firstIndex(where: { $0.id == offender }),
                      let part = byId[boards[index].placements[slot].partId] else { continue }
                let placement = boards[index].placements[slot]
                let footprint = part.footprint(turns: placement.turns)
                let occupancy = PartsBoardPacker.occupancy(of: boards[index], parts: parts,
                                                           spacing: spacing, ignoring: placement.id)
                // 前一个零件挪走之后这个可能自己就合法了，所以每次都重新问一遍
                if occupancy.canPlace(footprint, col: placement.col, row: placement.row) { continue }
                if let spot = PartsBoardPacker.firstFit(footprint, occupancy: occupancy) {
                    boards[index].placements[slot].col = spot.col
                    boards[index].placements[slot].row = spot.row
                    outcome.moved.append(placement.partId)
                } else {
                    outcome.invalid.append(placement.partId)
                }
            }
        }
        return outcome
    }

    /// 这块板上哪些摆位站不住了。
    ///
    /// 一次扫完，不是每个摆位各建一张占位表：一块板上五十个零件、每个上千颗豆子，
    /// 各建一张就是五十遍全表，而进屏那一下要为每块板都跑一次。
    ///
    /// 办法是数「每一格被几个零件的**扩张区**盖住」。零件自己的扩张区一定盖住自己的豆子，
    /// 所以某颗豆子所在的格子被盖了两次以上 ⟺ 它挨上了别人。出界和压到留边另算。
    private static func offenders(
        in board: PartsBoard,
        parts: [BeadPart],
        spacing: BoardSpacing
    ) -> [UUID] {
        let cols = max(1, board.cols)
        let rows = max(1, board.rows)
        let gap = spacing.gap
        let margin = spacing.margin
        let byId = Dictionary(parts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var covered = [Int16](repeating: 0, count: cols * rows)
        var shapes: [(id: UUID, footprint: PartFootprint, col: Int, row: Int)] = []
        for placement in board.placements {
            guard let part = byId[placement.partId] else { continue }
            let footprint = part.footprint(turns: placement.turns)
            shapes.append((placement.id, footprint, placement.col, placement.row))
            for bead in footprint.beads {
                for dr in -gap...gap {
                    for dc in -gap...gap {
                        let c = placement.col + bead.col + dc
                        let r = placement.row + bead.row + dr
                        guard c >= 0, r >= 0, c < cols, r < rows else { continue }
                        covered[r * cols + c] += 1
                    }
                }
            }
        }

        var result: [UUID] = []
        for shape in shapes {
            var bad = false
            for bead in shape.footprint.beads {
                let c = shape.col + bead.col
                let r = shape.row + bead.row
                // 出板、压到四周留边：都是「站不住」
                if c < margin || r < margin || c >= cols - margin || r >= rows - margin {
                    bad = true
                    break
                }
                if covered[r * cols + c] >= 2 {
                    bad = true
                    break
                }
            }
            if bad { result.append(shape.id) }
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
