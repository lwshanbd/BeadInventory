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
//  `UIWindowSceneSessionRoleExternalDisplayNonInteractive`，iOS 16+），系统就不再镜像，
//  改成显示 App 自己给的这个窗口 —— 横过来铺满整块屏幕。
//
//  这也是「用户可以把 App 收起来」的前提：这个窗口不是手机屏幕的镜像，它是 App 给
//  外屏的另一份画面，手机上切到别的地方（甚至锁屏之前放一边）时，外屏上停着的仍然是
//  最后送过去的那一版 —— 拼豆是低头按十分钟才抬一次头的活儿，不该要求手机一直亮着
//  停在这一屏。
//
//  ## 两种摆法
//
//  接**电视**时，人是抬头看图、低头在手机上动手 —— 板子居中铺满整块屏幕最好看清楚，
//  整块板都画出来，没选中的色号压成灰。
//
//  接**投影仪**、把画面投到桌上那块豆板上时完全是另一回事：画面正好盖在板子上，
//  这时候只亮**当前色号的那些格子**，其余全黑（`BoardProjectorCanvas`），亮的地方
//  就是接下来要按豆子的孔。位置和形状走用户标定的那四个角（`BoardProjector`）——
//  投影仪多半斜着照，画面落在桌上是个梯形，四个角把它掰回正方形。
//
//  没开投影仪模式就还是铺满 —— 接电视的人不该被要求先做一次校准。
//

import SwiftUI
import UIKit

// MARK: - 外屏上那块板

struct BoardExternalDisplayView: View {
    @ObservedObject private var session = BoardCastSession.shared
    @ObservedObject private var projector = BoardProjector.shared

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black

                if let mapping = projector.mapping(in: geo.size) {
                    projected(mapping: mapping, screen: geo.size)
                } else if let content = session.content {
                    filling(content)
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

    // MARK: - 投到豆板上（接投影仪）

    /// 只亮当前色号的那些格子，其余全黑；四个角是用户对着实物豆板标出来的。
    ///
    /// 说明和图例挪到板子**外面**：投影仪把它照在豆板上的话，那几行字就落在用户
    /// 正要按豆子的格子上了。
    @ViewBuilder
    private func projected(mapping: ProjectorMapping, screen: CGSize) -> some View {
        let box = projector.quad.boundingBox(in: screen)
        ZStack(alignment: .topLeading) {
            if let content = session.content {
                Canvas { context, _ in
                    ProjectorCanvasRenderer(
                        board: content.board,
                        footprints: content.footprints,
                        colorCache: content.colorCache,
                        highlightKeys: content.highlightKeys,
                        mapping: mapping
                    ).draw(in: context)
                }
                textOutside(box: box, screen: screen) { axis in
                    if content.highlightKeys.isEmpty {
                        // 板子对上了、格子却一个都不亮，用户第一反应是「投屏坏了」。
                        // 这一句把下一步说清楚：亮哪些格子是手机上点出来的。
                        hintRow(String(localized: "在手机上点一个色号，这里就只亮那个色号的格子"))
                    } else {
                        caption(for: content, axis: axis)
                    }
                }
            } else {
                textOutside(box: box, screen: screen) { _ in
                    hintRow(String(localized: "在手机上打开拼图模式，这里就会跟着显示"))
                }
            }

            // 校准时才画四个角标和辅助线。平时一道都不画：拼的人照着画面按豆子，
            // 多几条亮线他会当成格线数进去。
            if projector.isCalibrating {
                ProjectorCalibrationMarks(mapping: mapping, activeCorner: projector.activeCorner)
            }
        }
    }

    /// 把一段文字放在豆板**外面**的空地上。
    ///
    /// 四个方向都找一遍，**上方和左方不能不看**：豆板摆在投影区的哪个位置是桌上决定的，
    /// 对完之后那块地方常常被推到画面右下角，这时候空地全在上边和左边。只看下、右
    /// 两个方向的话，用户抬头看到一片高亮却没有图例，只会以为投屏坏了。
    ///
    /// padding 必须加在 `.frame` **里面**：先撑成整屏再加 padding，那 16pt 是溢出到
    /// 屏幕外面的，字照样贴着画面最下沿 —— 而投影仪画面边缘常有衰减和梯形失真，
    /// 正好切在这行字上。
    /// `content` 拿到的那个轴是「这块空地是横条还是竖条」：板子上下方是整屏宽的横条，
    /// 左右两侧只剩一竖条 —— 图例横着排会被挤成一团，得竖着码。
    @ViewBuilder
    private func textOutside<Content: View>(
        box: CGRect, screen: CGSize, @ViewBuilder content: (Axis) -> Content
    ) -> some View {
        if screen.height - box.maxY >= 64 {
            content(.horizontal)
                .padding(.bottom, 16)
                .frame(width: screen.width, height: screen.height, alignment: .bottom)
        } else if box.minY >= 64 {
            content(.horizontal)
                .padding(.top, 16)
                .frame(width: screen.width, height: screen.height, alignment: .top)
        } else if screen.width - box.maxX >= 260 {
            content(.vertical)
                .frame(width: screen.width - box.maxX - 48, alignment: .leading)
                .padding(.leading, box.maxX + 24)
                .padding(.top, max(box.minY, 24))
                .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        } else if box.minX >= 260 {
            content(.vertical)
                .frame(width: box.minX - 48, alignment: .leading)
                .padding(.leading, 24)
                .padding(.top, max(box.minY, 24))
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

    private func hintRow(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .foregroundStyle(.white.opacity(0.6))
    }

    /// 底下一行：我在哪儿、现在该找哪个颜色。
    /// 拼的人抬头看的就这两件事（左边那句由手机那边给：多零件是第几块板，单图纸是多少格）。
    private func captionRow(for content: BoardCastSession.Content) -> some View {
        caption(for: content, axis: .horizontal)
    }

    /// 竖排是给板子左右两侧那条窄空地用的（见 `textOutside`）。
    @ViewBuilder
    private func caption(for content: BoardCastSession.Content, axis: Axis) -> some View {
        let items = Group {
            Text(content.caption)
            ForEach(content.highlightKeys.sorted(), id: \.self) { key in
                legend(key: key, content: content)
            }
        }
        .font(.title3.monospacedDigit())
        .foregroundStyle(.white.opacity(0.8))

        if axis == .horizontal {
            HStack(spacing: 20) { items }
        } else {
            VStack(alignment: .leading, spacing: 14) { items }
        }
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
        // 投影仪模式那一屏要按这个尺寸画预览、换算手指拖的距离（见 BoardProjectorSheet）
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
        BoardProjector.shared.cancelCalibrating()
        AppLogger.shared.info("ExternalDisplay", "disconnected", metadata: [:])
    }
}
