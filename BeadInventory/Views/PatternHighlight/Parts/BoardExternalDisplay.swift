//
//  BoardExternalDisplay.swift
//  BeadInventory
//
//  接上电视 / 投影仪（AirPlay 镜像或者 USB-C 直连）之后，外屏上显示的东西
//
//  ## 为什么不是镜像
//
//  镜像会把一台竖着的手机原样搬到 16:9 的屏幕上：板子只占中间一小条，两边全黑。
//  这里注册一个**外屏专用场景**（iOS 16+ 的 `.externalDisplayNonInteractive`），
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
                                highlightKey: content.highlightKey
                            )
                            .draw(in: context, canvas: size,
                                  layout: .fitting(content.board, in: geo.size, padding: 24))
                        }
                    }
                    caption(for: content)
                }
                .padding(24)
            } else {
                // 接上了但手机上没开拼豆板。说清楚下一步，别让人对着一块黑屏猜。
                VStack(spacing: 12) {
                    Image(systemName: "square.grid.3x3")
                        .font(.system(size: 64))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("在手机上打开「拼豆板」，这里就会显示当前这块板")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }

    /// 底下一行：第几块板、正在只看哪个色号。
    /// 拼的人抬头看的就这两件事 —— 我拼的是哪一块，现在该找哪个颜色。
    private func caption(for content: BoardCastSession.Content) -> some View {
        HStack(spacing: 20) {
            Text("第 \(content.boardIndex + 1) / \(content.boardCount) 块")
            if let key = content.highlightKey {
                HStack(spacing: 8) {
                    Circle()
                        .fill(content.colorCache[key] ?? .gray)
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
/// 注册走 `AppDelegate.application(_:configurationForConnecting:options:)`，不写进
/// Info.plist —— 这个 App 是 SwiftUI 生命周期，Info.plist 里一旦出现 scene manifest，
/// 主场景也得跟着一起声明，等于把 SwiftUI 自己管的那套接管过来。代码里只认这一个角色，
/// 别的角色原样放行，主界面完全不受影响。
final class BoardExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: BoardExternalDisplayView())
        window.isHidden = false
        self.window = window
        AppLogger.shared.info("ExternalDisplay", "connected", metadata: [
            "size": "\(windowScene.screen.bounds.size)"
        ])
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        AppLogger.shared.info("ExternalDisplay", "disconnected", metadata: [:])
    }
}
