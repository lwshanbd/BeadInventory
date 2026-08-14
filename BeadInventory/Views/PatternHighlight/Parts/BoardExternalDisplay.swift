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

import SwiftUI
import UIKit

// MARK: - 外屏上那块板

struct BoardExternalDisplayView: View {
    @ObservedObject private var session = BoardCastSession.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let content = session.content {
                VStack(spacing: 0) {
                    GeometryReader { geo in
                        Canvas { context, size in
                            BoardCanvasRenderer(
                                board: content.board,
                                footprints: content.footprints,
                                colorCache: content.colorCache,
                                highlightKeys: content.highlightKeys
                            )
                            // padding 交给外面那层 .padding(24) —— 这里再留一次的话
                            // 每边就是 48pt 死边，而这块屏幕存在的意义就是铺满。
                            .draw(in: context, canvas: size,
                                  layout: .fitting(content.board, in: geo.size, padding: 0))
                        }
                    }
                    caption(for: content)
                }
                .padding(24)
            } else {
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
            }
        }
    }

    /// 底下一行：我在哪儿、现在该找哪个颜色。
    /// 拼的人抬头看的就这两件事（左边那句由手机那边给：多零件是第几块板，单图纸是多少格）。
    private func caption(for content: BoardCastSession.Content) -> some View {
        HStack(spacing: 20) {
            Text(content.caption)
            ForEach(content.highlightKeys.sorted(), id: \.self) { key in
                HStack(spacing: 8) {
                    // fallback 跟板子上用的是同一个（BoardCanvas 的 fillColor）——
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
        .font(.title3.monospacedDigit())
        .foregroundStyle(.white.opacity(0.8))
        .padding(.top, 12)
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
        AppLogger.shared.info("ExternalDisplay", "connected", metadata: [
            "size": "\(windowScene.screen.bounds.size)"
        ])
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        BoardCastSession.shared.externalConnected = false
        AppLogger.shared.info("ExternalDisplay", "disconnected", metadata: [:])
    }
}
