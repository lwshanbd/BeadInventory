//
//  BoardExternalDisplay.swift
//  BeadInventory
//
//  接上电视 / 投影仪（AirPlay 镜像或者 USB-C 直连）之后，外屏上显示的东西
//
//  ## 为什么不是镜像
//
//  镜像会把一台竖着的手机原样搬到 16:9 的屏幕上：板子只占中间一小条，两边全黑。
//  这里注册一个**外屏专用场景**（Info.plist 里那个
//  `UIWindowSceneSessionRoleExternalDisplayNonInteractive` 角色，iOS 16+），
//  系统就不再镜像，改成显示 App 自己给的这个窗口 —— 横过来铺满整块屏幕。
//
//  外屏**不接受任何操作**（角色名字里就写着 NonInteractive），所以这里没有手势、
//  没有按钮，只有一块板。要动手仍然低头看手机。
//
//  ## 两种摆法
//
//  接**电视**时，人是抬头看图、低头在手机上动手 —— 板子居中铺满整块屏幕最好看清楚。
//
//  接**投影仪**、把画面投到桌上那块豆板上时，情况正相反：板子该有多大、落在哪儿，
//  是桌上那块实物说了算，投影仪自己不知道。这时候走校准出来的那块矩形
//  （`BoardCastCalibration`）：左上角钉在用户标定的点上，一格多大是用户拉出来的。
//  矩形以外只剩底色和一行图例，而图例是刻意躲开矩形的（见 `captionOutside`）——
//  照在豆板上的字，正好挡着用户要按豆子的格子。
//
//  没校准过就还是铺满 —— 接电视的人不该被要求先做一次校准。
//

import SwiftUI
import UIKit

// MARK: - 外屏上那块板

struct BoardExternalDisplayView: View {
    @ObservedObject private var session = BoardCastSession.shared
    @ObservedObject private var calibration = BoardCastCalibration.shared

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black

                if let content = session.content {
                    if let frame = calibration.frame(for: content.board, in: geo.size) {
                        calibrated(content, frame: frame, screen: geo.size)
                        // 校准时压在最上面。平时一道都不画：拼的人照着画面按豆子，
                        // 多几道亮线他会当成格线数进去。
                        //
                        // 角标画的就是上面那块 `frame` —— 用户对齐的那两个角，
                        // 必须是板子真正画出来的那两个角，不能是另算一个方框。
                        if calibration.isCalibrating {
                            CalibrationMarksCanvas(frame: frame)
                        }
                    } else {
                        filling(content)
                    }
                } else {
                    emptyHint
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }

    // MARK: - 铺满（接电视）

    private func filling(_ content: BoardCastSession.Content) -> some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                Canvas { context, size in
                    renderer(for: content)
                        // padding 交给外面那层 .padding(24) —— 这里再留一次的话
                        // 每边就是 48pt 死边，而这块屏幕存在的意义就是铺满。
                        .draw(in: context, canvas: size,
                              layout: .fitting(content.board, in: geo.size, padding: 0))
                }
            }
            captionRow(for: content)
                .padding(.top, 12)
        }
        .padding(24)
    }

    // MARK: - 校准过（接投影仪）

    /// 板子画在标定出来的那块矩形里，别的地方全黑。
    ///
    /// 图例挪到矩形**外面**：投影仪把它照在豆板上的话，那几行字就落在用户
    /// 正要按豆子的格子上了。四周都挤不下才不显示 —— 对齐比图例重要。
    private func calibrated(
        _ content: BoardCastSession.Content, frame: CGRect, screen: CGSize
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                renderer(for: content)
                    .draw(in: context, canvas: size,
                          layout: .anchored(content.board, in: frame))
            }
            captionOutside(content, frame: frame, screen: screen)
        }
    }

    /// 四个方向都找一遍。**上方和左方不能不看**：豆板摆在投影区的哪个位置是桌上
    /// 决定的，校准之后那块矩形常常被推到画面右下角，这时候空地全在上边和左边。
    /// 只看下、右两个方向的话，用户抬头看到一片高亮却没有图例，只会以为投屏坏了。
    ///
    /// padding 必须加在 `.frame` **里面**：先撑成整屏再加 padding，那 16pt 是溢出到
    /// 屏幕外面的，字照样贴着画面最下沿 —— 而投影仪画面边缘常有衰减和梯形失真，
    /// 正好切在这行字上。
    @ViewBuilder
    private func captionOutside(
        _ content: BoardCastSession.Content, frame: CGRect, screen: CGSize
    ) -> some View {
        if screen.height - frame.maxY >= 64 {
            captionRow(for: content)
                .padding(.bottom, 16)
                .frame(width: screen.width, height: screen.height, alignment: .bottom)
        } else if frame.minY >= 64 {
            captionRow(for: content)
                .padding(.top, 16)
                .frame(width: screen.width, height: screen.height, alignment: .top)
        } else if screen.width - frame.maxX >= 260 {
            captionColumn(for: content)
                .frame(width: screen.width - frame.maxX - 48, alignment: .leading)
                .padding(.leading, frame.maxX + 24)
                .padding(.top, max(frame.minY, 24))
                .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        } else if frame.minX >= 260 {
            captionColumn(for: content)
                .frame(width: frame.minX - 48, alignment: .leading)
                .padding(.leading, 24)
                .padding(.top, max(frame.minY, 24))
                .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        }
    }

    // MARK: - 零件

    private func renderer(for content: BoardCastSession.Content) -> BoardCanvasRenderer {
        BoardCanvasRenderer(
            board: content.board,
            footprints: content.footprints,
            colorCache: content.colorCache,
            highlightKeys: content.highlightKeys,
            labels: content.labels,
            invalid: content.invalid
        )
    }

    private var emptyHint: some View {
        // 接上了，但手机那边现在没有板子可显示 —— 可能是没打开拼豆板那一屏，
        // 也可能是打开了但一块板都还没有。这句话在两种情况下都成立，
        // 而且都指向同一个下一步。别让人对着一块黑屏猜。
        VStack(spacing: 12) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 64))
                .foregroundStyle(.white.opacity(0.35))
            // 两种模式都会走到这儿（多零件的拼豆板、单图纸的高亮页），
            // 所以这句话不能只提其中一个 —— 用户按着提示去开另一个，
            // 只会得出「投屏坏了」的结论。
            Text("在手机上打开拼图模式，这里就会跟着显示")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 底下一行：我在哪儿、现在该找哪个颜色。
    /// 拼的人抬头看的就这两件事（左边那句由手机那边给：多零件是第几块板，单图纸是多少格）。
    private func captionRow(for content: BoardCastSession.Content) -> some View {
        HStack(spacing: 20) {
            Text(content.caption)
            ForEach(content.highlightKeys.sorted(), id: \.self) { key in
                legend(key: key, content: content)
            }
        }
        .font(.title3.monospacedDigit())
        .foregroundStyle(.white.opacity(0.8))
    }

    /// 方框右边那一竖条（校准之后板子占满高度，底下常常没地方了）
    private func captionColumn(for content: BoardCastSession.Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(content.caption)
            ForEach(content.highlightKeys.sorted(), id: \.self) { key in
                legend(key: key, content: content)
            }
        }
        .font(.title3.monospacedDigit())
        .foregroundStyle(.white.opacity(0.8))
    }

    private func legend(key: String, content: BoardCastSession.Content) -> some View {
        HStack(spacing: 8) {
            // fallback 跟板子上用的是同一个（BoardCanvas 的 beadColor）——
            // 两边不一样的话，同一个色号在图例上和板子上会是两个颜色，
            // 而图例正是用户抬头要查的那个东西。
            Circle()
                .fill(content.colorCache[key] ?? Theme.ColorToken.Surface.strong)
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1))
            Text(key)
        }
    }
}

// MARK: - 校准时画在外屏上的角标

/// 用户要对齐的两个角，各画一个粗角标；板子那块矩形描一圈细线。
///
/// 两个角**故意不同色**（颜色定义在 `CalibrationMarkColor`，手机上用的是同一份）：
/// 校准分两步（先对左上角、再拉格子对右下角），人站在投影仪那头、手机在手上，
/// 两个角长得一样的话他会把正在调的那个搞错。
private struct CalibrationMarksCanvas: View {
    let frame: CGRect

    private static let topLeftColor = CalibrationMarkColor.topLeft
    private static let bottomRightColor = CalibrationMarkColor.bottomRight

    var body: some View {
        Canvas { context, _ in
            context.stroke(Path(frame), with: .color(.white.opacity(0.55)), lineWidth: 1)

            let arm = min(90, max(24, min(frame.width, frame.height) * 0.22))

            var topLeft = Path()
            topLeft.move(to: CGPoint(x: frame.minX, y: frame.minY + arm))
            topLeft.addLine(to: CGPoint(x: frame.minX, y: frame.minY))
            topLeft.addLine(to: CGPoint(x: frame.minX + arm, y: frame.minY))
            context.stroke(topLeft, with: .color(Self.topLeftColor), lineWidth: 6)

            var bottomRight = Path()
            bottomRight.move(to: CGPoint(x: frame.maxX - arm, y: frame.maxY))
            bottomRight.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY))
            bottomRight.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY - arm))
            context.stroke(bottomRight, with: .color(Self.bottomRightColor), lineWidth: 6)

            draw(String(localized: "① 豆板左上角对这里"),
                 color: Self.topLeftColor,
                 at: CGPoint(x: frame.minX + 14, y: frame.minY + arm + 14),
                 anchor: .topLeading, in: context)
            draw(String(localized: "② 最后一格拉到这里"),
                 color: Self.bottomRightColor,
                 at: CGPoint(x: frame.maxX - 14, y: frame.maxY - arm - 14),
                 anchor: .bottomTrailing, in: context)
        }
    }

    private func draw(
        _ text: String, color: Color, at point: CGPoint,
        anchor: UnitPoint, in context: GraphicsContext
    ) {
        context.draw(
            context.resolve(
                Text(text).font(.system(size: 28, weight: .semibold)).foregroundStyle(color)
            ),
            at: point, anchor: anchor
        )
    }
}

// MARK: - 外屏那个场景

/// 外屏连上 / 断开时，系统拿这个类来建那个窗口。
///
/// 注册写在 **Info.plist** 的 `UISceneConfigurations` 里。
///
/// 第一版是在 `UIApplicationDelegateAdaptor` 里实现 `configurationForConnecting` 返回配置的，
/// 不生效 —— 这个 App 是 SwiftUI 生命周期，那个回调会被 SwiftUI 自己的 app delegate 接管，
/// 轮不到我们写的那份（实测现象：接上电视仍然是纯镜像）。那条路已经删掉，仓库里搜不到。
/// 写进 plist 之后，接管它的那个 delegate 会照着这张表建场景，我们不需要参与。
///
/// plist 里**只声明外屏这一个角色**：主场景仍然由 SwiftUI 自己管，不去碰它。
///
/// ⚠️ 这份 plist 能生效还靠一个 build setting：`INFOPLIST_KEY_UIApplicationSceneManifest_Generation`
/// 必须是 `NO`。开着的话 Xcode 会生成一份**空的** `UISceneConfigurations` 覆盖掉这里手写的，
/// 投屏静默退回纯镜像 —— 不报错、不崩、日志里也没有一行。改工程设置时留意。
final class BoardExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else {
            // 走到这儿说明电视接上了但窗口没建起来。不记的话，这个状态和「压根没接外屏」
            // 在用户眼里、在日志里都长得一模一样，事后完全无从查起。
            AppLogger.shared.error("ExternalDisplay", "scene_not_window_scene", metadata: [
                "scene": "\(type(of: scene))"
            ])
            return
        }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: BoardExternalDisplayView())
        // 外屏窗口用 isHidden，**不要**改成 makeKeyAndVisible() ——
        // 那会把 key window 从手机主窗口抢过来，键盘和输入焦点就跑到电视上去了。
        window.isHidden = false
        self.window = window
        BoardCastSession.shared.externalConnected = true
        // 校准页要按这个尺寸画预览、换算手指拖的距离（见 BoardCastCalibrationSheet）
        BoardCastSession.shared.externalScreenSize = windowScene.screen.bounds.size
        AppLogger.shared.info("ExternalDisplay", "connected", metadata: [
            "size": "\(windowScene.screen.bounds.size)"
        ])
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        BoardCastSession.shared.externalConnected = false
        BoardCastSession.shared.externalScreenSize = nil
        // 拔线时如果正开着校准页，这次校准就此作废、退回进去之前的值：
        // 后面那半程本来就没法在一块不存在的屏幕上完成。已经「完成」过的
        // 校准值不受影响 —— 那是用户对着实物量出来的，投影仪没挪就还作数。
        BoardCastCalibration.shared.cancelCalibrating()
        AppLogger.shared.info("ExternalDisplay", "disconnected", metadata: [:])
    }
}
