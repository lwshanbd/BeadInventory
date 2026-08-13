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
//  ## 为什么零件之间必须空一格
//
//  拼豆是要拿熨斗烫的，挨着的两颗豆子烫完就连成一片。两个零件在板上贴着放，
//  烫完得拿剪刀分开 —— 那一刀下去边缘就毁了。所以这里的「放得下」不是
//  「豆子不重叠」，而是**任意两个零件的豆子之间至少隔一格**（斜着挨着也算挨着，
//  拼豆板上斜角的两颗豆子是碰得到的）。
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
/// 每颗豆子连同它周围一圈（含斜角）都记上，这样「放得下」直接查表就行，
/// 空一格的规矩自然而然被满足（见文件头）。
struct BoardOccupancy: Sendable {
    let cols: Int
    let rows: Int
    private var blocked: [Bool]

    init(cols: Int, rows: Int) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        blocked = Array(repeating: false, count: self.cols * self.rows)
    }

    /// 零件矩阵左上角放在 (col, row) 时，豆子是不是都落在板内、且都不挨着别的零件
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

    mutating func add(_ footprint: PartFootprint, col: Int, row: Int) {
        for bead in footprint.beads {
            for dr in -1...1 {
                for dc in -1...1 {
                    let c = col + bead.col + dc
                    let r = row + bead.row + dr
                    guard c >= 0, r >= 0, c < cols, r < rows else { continue }
                    blocked[r * cols + c] = true
                }
            }
        }
    }
}

// MARK: - 自动排

/// 把零件铺到板上。
///
/// 用的是「从上到下、从左到右找第一个放得下的地方」，零件按高矮排过序。
/// 不追求最优装箱：多塞进去一两个零件的收益，远不如「排出来的样子跟图纸上
/// 差不多、用户一眼认得出哪个是哪个」重要 —— 而且他随时能自己拖。
enum PartsBoardPacker {
    /// 板上已经摆了的东西占了哪些格。`ignoring` 用来在拖某个零件时把它自己排除掉。
    static func occupancy(of board: PartsBoard, parts: [BeadPart], ignoring: UUID? = nil) -> BoardOccupancy {
        var occupancy = BoardOccupancy(cols: board.cols, rows: board.rows)
        for placement in board.placements where placement.id != ignoring {
            guard let part = parts.first(where: { $0.id == placement.partId }) else { continue }
            occupancy.add(part.footprint(turns: placement.turns), col: placement.col, row: placement.row)
        }
        return occupancy
    }

    /// 在这块板上找第一个放得下的位置（返回的是零件矩阵左上角该放哪儿）
    static func firstFit(
        _ footprint: PartFootprint,
        occupancy: BoardOccupancy
    ) -> (col: Int, row: Int)? {
        guard !footprint.isEmpty,
              footprint.width <= occupancy.cols,
              footprint.height <= occupancy.rows else { return nil }
        for r in 0...(occupancy.rows - footprint.height) {
            for c in 0...(occupancy.cols - footprint.width) {
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
        size: BeadBoardSize
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

        var occupancy = BoardOccupancy(cols: size.cols, rows: size.rows)
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
        size: BeadBoardSize
    ) -> (boards: [PartsBoard], unplaced: [UUID]) {
        var boards: [PartsBoard] = []
        var occupancies: [BoardOccupancy] = []
        var unplaced: [UUID] = []

        for item in ordered(parts) {
            if placeOne(item.part, footprint: item.footprint,
                        into: &boards, occupancies: &occupancies, size: size) == nil {
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
