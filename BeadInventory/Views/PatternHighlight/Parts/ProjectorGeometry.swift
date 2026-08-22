//
//  ProjectorGeometry.swift
//  BeadInventory
//
//  投影仪投出来的画面，怎么按四个角掰回到豆板上
//
//  ## 为什么两个点不够
//
//  投影仪很少能正对着桌面：它多半架在旁边、斜着往下照。斜着照出来的正方形画面落在桌上
//  就是个**梯形** —— 近的一边短、远的一边长。这时候不管怎么挪位置、怎么改格子大小，
//  都只能对上一个角：左上角对准了，右下角就差出去半格甚至一整格，照着投影按豆子，
//  越往远处越错。
//
//  两个点（左上角 + 格距）能表达的只有「平移 + 等比缩放」，梯形不在里面。四个角才够：
//  用户把画面里那个方框的四个角分别拖到豆板的四个角上，剩下的形变由这里算出来 ——
//  这就是投影仪自带的「梯形校正」在做的事，只不过那个旋钮只能校上下两边，
//  而且校完整块画面都缩水；这里是 App 自己画，一格都不浪费。
//
//  ## 单应（homography）
//
//  桌面是平的、投影仪的成像也是平面透视，所以「豆板上的格子」到「画面上的位置」
//  之间是一个 3×3 的射影变换 —— 四对点就唯一确定它。确定之后**中间的格子自动就对了**，
//  不需要用户再对第五个点：这是平面透视的性质，不是近似。
//
//  这里算的是 Heckbert 那套「单位正方形 → 任意四边形」的闭式解，比解 8 元线性方程组
//  短得多，也不会引入迭代误差。
//
//  ## 为什么要自己画四边形，而不是给图层加个 3D 变换
//
//  `CATransform3D` 也能表达同一个变换，但那是**把画好的位图再拉一遍**：拉完是重采样，
//  像素画那种一格一色的图会糊成渐变（`scaleEffect` 毁掉最近邻是同一个坑）。
//  这里换成：每一格的四个角各自算一遍，然后直接填这个四边形。画出来的边永远是实的，
//  投多大都清楚。
//

import CoreGraphics

// MARK: - 豆板的四个角

/// 桌上那块豆板的四个角，在外屏画面里的位置。
///
/// 单位是**外屏宽度**（x 和 y 都是）—— 换一台投影仪、或者同一台换个输出分辨率，
/// 点数全变、比例还在。两个方向用同一个单位是为了少一次换算、少一个出错的地方。
struct ProjectorQuad: Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    subscript(corner: ProjectorCorner) -> CGPoint {
        get {
            switch corner {
            case .topLeft: return topLeft
            case .topRight: return topRight
            case .bottomRight: return bottomRight
            case .bottomLeft: return bottomLeft
            }
        }
        set {
            switch corner {
            case .topLeft: topLeft = newValue
            case .topRight: topRight = newValue
            case .bottomRight: bottomRight = newValue
            case .bottomLeft: bottomLeft = newValue
            }
        }
    }

    /// 顺时针一圈。画框、判凸、算外接矩形都按这个顺序走。
    var clockwise: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// 换算成外屏上的点数
    func points(in screen: CGSize) -> [CGPoint] {
        clockwise.map { CGPoint(x: $0.x * screen.width, y: $0.y * screen.width) }
    }

    func point(_ corner: ProjectorCorner, in screen: CGSize) -> CGPoint {
        CGPoint(x: self[corner].x * screen.width, y: self[corner].y * screen.width)
    }

    /// 四个角围出来那块地方的外接矩形（外屏点数）。图例要躲开的就是它。
    func boundingBox(in screen: CGSize) -> CGRect {
        let pts = points(in: screen)
        let xs = pts.map(\.x), ys = pts.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 四个角还围得成一块正经地方吗。
    ///
    /// 拖角是可以把四边形拖成「8」字或者拧成一条线的，而那时候单应算出来的东西
    /// 是乱的：格子会翻面、会飞到画面外。与其画出一团乱码让用户以为功能坏了，
    /// 不如在拖的那一刻就不让它变成这样（见 `BoardProjector.setCorner`）。
    ///
    /// 判据是四个叉积**都不为零且同号**（凸、不自交、也不三点共线）。零叉积得排除：
    /// 三点共线时单应的分母能算出零，格子会整片消失或飞出画面。
    ///
    /// 面积下限只用来挡「拧成一条线」这种退化，所以取得很小。**不要往大了调**：
    /// 它是以「外屏宽度的平方」为单位的，1e-4 已经相当于边长 1% 画面宽；
    /// 之前取 0.01 等于要求方框边长至少占画面宽的 10%，而投影仪打出三米宽的画面、
    /// 桌上一块 25cm 的豆板只占 8%，四个角**永远拖不到板子上**，而且拖不动时
    /// 界面上一个字都没有（`BoardProjector.setCorner` 是静默不采纳）。
    var isUsable: Bool {
        let p = clockwise
        var positive = false, negative = false
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if cross > 1e-9 { positive = true }
            else if cross < -1e-9 { negative = true }
            else { return false }   // 三点共线
        }
        guard positive != negative else { return false }
        // 鞋带公式
        var area: CGFloat = 0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4]
            area += a.x * b.y - b.x * a.y
        }
        return abs(area) / 2 >= 1e-4
    }

    /// 一块四四方方、居中放着的板：第一次进校准页时的起点。
    /// 用户一进来就该有个方框可以拖，而不是对着一片黑猜该点哪儿。
    static func centered(cols: Int, rows: Int, in screen: CGSize) -> ProjectorQuad {
        let bottom = screen.height / screen.width          // 画面高度，同样以宽度为单位
        let cell = min(bottom * 0.8 / CGFloat(max(rows, 1)), 0.8 / CGFloat(max(cols, 1)))
        let width = cell * CGFloat(max(cols, 1))
        let height = cell * CGFloat(max(rows, 1))
        let x = (1 - width) / 2
        let y = (bottom - height) / 2
        return ProjectorQuad(
            topLeft: CGPoint(x: x, y: y),
            topRight: CGPoint(x: x + width, y: y),
            bottomRight: CGPoint(x: x + width, y: y + height),
            bottomLeft: CGPoint(x: x, y: y + height)
        )
    }
}

/// 四个角各自的身份。用户在手机上选中哪个、微调按钮作用在哪个，靠它。
///
/// ⚠️ **case 的声明顺序就是顺时针顺序，别重排。** `ProjectorQuad.clockwise`、
/// `points(in:)`、存进 UserDefaults 的那八个数（TL TR BR BL），以及
/// `BoardProjectorSheet` 里按下标取把手（`allCases.enumerated()` 配 `points[index]`）
/// 全都依赖它。调换一下不会报错，表现是手机上拖 ① 动的是 ③。
enum ProjectorCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomRight, bottomLeft

    var id: String { rawValue }

    /// 说明里写的序号。顺时针从左上开始 —— 人绕着板子对角也是这么绕的。
    var number: String {
        switch self {
        case .topLeft: return "①"
        case .topRight: return "②"
        case .bottomRight: return "③"
        case .bottomLeft: return "④"
        }
    }
}

// MARK: - 格子 → 画面

/// 「豆板上第几行第几列」到「外屏上哪一点」的射影变换。
///
/// 输入坐标是**格**：(0,0) 是豆板左上角那个孔的左上角，(cols,rows) 是右下角那个孔的
/// 右下角。小数也认（画一格里的内缩、画半格的辅助线都要用）。
struct ProjectorMapping {
    // p' = ((a·u + b·v + c) / (g·u + h·v + 1), (d·u + e·v + f) / (g·u + h·v + 1))
    private let a, b, c, d, e, f, g, h: CGFloat
    private let cols: CGFloat
    private let rows: CGFloat

    /// 板子多少格。渲染时要判断一格在不在板上。
    let boardCols: Int
    let boardRows: Int

    /// nil = 这四个角围不成一块正经地方（拖坏了 / 存坏了），调用方据此退回铺满。
    init?(quad: ProjectorQuad, screen: CGSize, cols: Int, rows: Int) {
        guard screen.width > 0, cols > 0, rows > 0, quad.isUsable else { return nil }
        let p = quad.points(in: screen)
        let (x0, y0) = (p[0].x, p[0].y)   // 单位方格 (0,0)
        let (x1, y1) = (p[1].x, p[1].y)   //          (1,0)
        let (x2, y2) = (p[2].x, p[2].y)   //          (1,1)
        let (x3, y3) = (p[3].x, p[3].y)   //          (0,1)

        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3

        if abs(dx3) < 1e-9 && abs(dy3) < 1e-9 {
            // 平行四边形（投影仪正对着桌子时就是这种）：没有透视项，退化成仿射。
            a = x1 - x0; b = x2 - x1; c = x0
            d = y1 - y0; e = y2 - y1; f = y0
            g = 0; h = 0
        } else {
            let den = dx1 * dy2 - dy1 * dx2
            guard abs(den) > 1e-9 else { return nil }
            g = (dx3 * dy2 - dy3 * dx2) / den
            h = (dx1 * dy3 - dy1 * dx3) / den
            a = x1 - x0 + g * x1
            b = x3 - x0 + h * x3
            c = x0
            d = y1 - y0 + g * y1
            e = y3 - y0 + h * y3
            f = y0
        }
        self.cols = CGFloat(cols)
        self.rows = CGFloat(rows)
        boardCols = cols
        boardRows = rows
    }

    /// 第 `col` 列、第 `row` 行那个位置在画面上的点。
    ///
    /// nil = 这一点落在「地平线」的另一侧（分母 ≤ 0）。斜着投的时候，画面之外足够远的
    /// 地方会翻到透视中心背后去，硬画出来是一片翻转的乱纹。图纸比豆板大时确实会算到
    /// 那么远的格子，所以这里必须能说「这一格没有」。
    func point(col: CGFloat, row: CGFloat) -> CGPoint? {
        let u = col / cols
        let v = row / rows
        let w = g * u + h * v + 1
        guard w > 1e-6 else { return nil }
        return CGPoint(x: (a * u + b * v + c) / w, y: (d * u + e * v + f) / w)
    }

    /// 一格的四个角（顺时针）。`inset` 是每边往里缩多少格 —— 缩一点，
    /// 挨着的两格才不会连成一片，用户一眼能数清是几个孔。
    func cellCorners(col: Int, row: Int, inset: CGFloat = 0) -> [CGPoint]? {
        let c0 = CGFloat(col) + inset, c1 = CGFloat(col + 1) - inset
        let r0 = CGFloat(row) + inset, r1 = CGFloat(row + 1) - inset
        guard let tl = point(col: c0, row: r0),
              let tr = point(col: c1, row: r0),
              let br = point(col: c1, row: r1),
              let bl = point(col: c0, row: r1) else { return nil }
        return [tl, tr, br, bl]
    }

    /// 一格在画面上大概多大（点）。微调按钮的步长按它算。
    ///
    /// 取板子正中间那一格：斜投时四角的格子一大一小，中间那格最有代表性。
    /// 横竖各量一次再平均 —— 只取对角差的最大分量的话，板子转过一定角度时
    /// 「一下走 ¼ 格」会明显不是 ¼ 格。
    var averageCellSize: CGFloat {
        let c = cols / 2, r = rows / 2
        guard let origin = point(col: c, row: r),
              let right = point(col: c + 1, row: r),
              let down = point(col: c, row: r + 1) else { return 0 }
        return (hypot(right.x - origin.x, right.y - origin.y)
                + hypot(down.x - origin.x, down.y - origin.y)) / 2
    }
}

// MARK: - 角标那个箭头

/// 一个角的角标：箭尖是豆板最角上那一格，沿着两条边各再走几格，凑成一个直角箭头。
///
/// ## 为什么角标要按「格」画，不能是一条线
///
/// 之前画的是一道折线，用户看着投影不知道该把它对到哪儿：线本身有粗细，对准的是
/// 线的中心还是外沿？角上那个孔是该被线压住，还是该在线的外面？站在桌边看，
/// 半格的差别肉眼分不出来，而半格就是每颗豆子都压在孔的边上。
///
/// 换成格子之后，这件事只剩一句话：**箭尖那个亮块盖住板子最角上那个孔**，
/// 两条边上各再亮几个孔。用户数得出来是几个孔，也就对得准 —— 拼豆的人本来就是
/// 按孔数东西的。
///
/// ## 为什么要有两条胳膊
///
/// 一个亮块只说得清「对到哪个孔」，说不清「这是哪个角」：板子是方的，四个角长得一样，
/// 人绕到另一边站，①②③④ 就全反了。两条胳膊沿着板子的两条边伸出去，箭头指着哪个角
/// 一眼就是一眼 —— 不管人站在哪一边。
struct ProjectorCornerArrow {
    let corner: ProjectorCorner
    let cols: Int
    let rows: Int

    /// 沿着两条边、朝板子里面走的方向
    var inward: (col: CGFloat, row: CGFloat) {
        switch corner {
        case .topLeft: return (1, 1)
        case .topRight: return (-1, 1)
        case .bottomRight: return (-1, -1)
        case .bottomLeft: return (1, -1)
        }
    }

    /// 一条胳膊几格。
    ///
    /// 4 格是在实物上量出来的：常见的 25cm 豆板一格 5mm，4 格 2cm，站在桌边一眼能数清。
    /// 小板子上要收着点 —— 14×14 的板上再伸 4 格，四个箭头就快在边上接起来了，
    /// 反而看不出哪儿是角。
    var armLength: Int { min(4, max(1, min(cols, rows) / 4)) }

    /// 角标上的一格。`distance` 是离箭尖几格：画的时候越远画得越小，
    /// 一排由大到小的亮块看着就是个指向箭尖的箭头。
    struct Cell {
        let col: Int
        let row: Int
        let distance: Int
    }

    var cells: [Cell] {
        let tipCol = inward.col > 0 ? 0 : max(cols - 1, 0)
        let tipRow = inward.row > 0 ? 0 : max(rows - 1, 0)
        let stepCol = Int(inward.col), stepRow = Int(inward.row)
        var result = [Cell(col: tipCol, row: tipRow, distance: 0)]
        for d in 1...armLength {
            let alongTop = tipCol + stepCol * d
            let alongSide = tipRow + stepRow * d
            if (0..<cols).contains(alongTop) {
                result.append(Cell(col: alongTop, row: tipRow, distance: d))
            }
            if (0..<rows).contains(alongSide) {
                result.append(Cell(col: tipCol, row: alongSide, distance: d))
            }
        }
        return result
    }

    /// 序号（①②③④）写在哪儿，格坐标。
    ///
    /// 落在两条胳膊夹出来那个直角的里面、再往里挪一点：写在箭尖上就把用户正要对准的
    /// 那个亮块给盖住了，而那个亮块是这一屏唯一要对准的东西。
    var labelAnchor: CGPoint {
        let tipCol: CGFloat = inward.col > 0 ? 0 : CGFloat(cols)
        let tipRow: CGFloat = inward.row > 0 ? 0 : CGFloat(rows)
        let reach = CGFloat(armLength) + 1.4
        return CGPoint(x: tipCol + inward.col * reach, y: tipRow + inward.row * reach)
    }
}

// MARK: - 四条边中间 + 板子正中的对齐点

/// 校准时额外点亮的几个十字：四条边的正中各一个，板子正中一个。
///
/// ## 光有四个角不够
///
/// 四个角对上之后，中间的格子在**数学上**是自动对齐的（平面透视的性质）。但桌上不是
/// 数学：投影仪镜头本身有枕形/桶形畸变，边的中间鼓出去或者凹进来是最常见的一处；
/// 桌面也可能不平，豆板还可能被压得翘起来一点。这些都是四个角看不出来的 ——
/// 角上对得严丝合缝，边中间照样能差半格。
///
/// 边的正中间正是畸变最大的地方，所以标在那儿。
///
/// ## 正中间那个十字还兼一件事
///
/// 板子格数选错时（比如实物是 52×52、这里存着 100×100），四个角照样能对上 ——
/// 角就是角，跟格数无关。但那时候每一格都不是一个孔，中间那个十字会明显骑在孔沿上。
/// 用户看不懂「格数」这个概念，但看得懂「这块光没照进孔里」。
///
/// 用白色：四个角标已经占了黄青绿品红，再添一种彩色，用户会以为它也是个「要拖的角」。
/// 白色一看就是「只是给你看的」。
struct ProjectorAlignmentMarks {
    let cols: Int
    let rows: Int

    /// 每个十字的中心。格数是偶数时取不到正中间那一格，会偏半格 —— 用户是拿它看
    /// 「有没有照进孔里」，不是拿它量距离，半格无所谓。
    var centers: [(col: Int, row: Int)] {
        let midCol = cols / 2, midRow = rows / 2
        return [
            (midCol, 0),            // 上边正中
            (midCol, rows - 1),     // 下边正中
            (0, midRow),            // 左边正中
            (cols - 1, midRow),     // 右边正中
            (midCol, midRow)        // 板子正中
        ]
    }

    /// 一个十字由哪几格组成：中心 + 上下左右各一格。
    ///
    /// 出界的那一格直接丢掉，所以边上那四个十字自动变成朝板子里面的「T」——
    /// 正好把边的位置指出来，不用为边和中心分别写两套形状。
    var cells: [(col: Int, row: Int)] {
        var result: [(col: Int, row: Int)] = []
        for center in centers {
            for (dc, dr) in [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)] {
                let c = center.col + dc, r = center.row + dr
                guard (0..<cols).contains(c), (0..<rows).contains(r) else { continue }
                result.append((c, r))
            }
        }
        return result
    }
}
