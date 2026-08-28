//
//  ProjectorConnectSheet.swift
//  BeadInventory
//
//  连上投影仪里那个安卓 App 的那一屏
//
//  ## 两条路
//
//  正常路径是扫码：投影仪打开 App 就把二维码投在墙上，这边扫一下，地址和密钥一起
//  拿到，用户不用理解什么是 IP。
//
//  手输是兜底，但**不是可有可无的兜底**：投影仪没对好焦、画面被梯形校正拉歪时二维码
//  扫不动，而那两种情况恰恰在第一次架机器时最常见。投影仪屏幕上同时显示着地址和
//  6 位码，两样都只用眼睛读，不用动遥控器。
//

import SwiftUI

/// 以 sheet 呈现（拼豆板那一屏的入口用它）。设置里那个入口用 `ProjectorConnectView`
/// 直接推进导航栈，不要再套一层 NavigationStack。
struct ProjectorConnectSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ProjectorConnectView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
    }
}

struct ProjectorConnectView: View {
    @ObservedObject private var link = ProjectorLink.shared

    @State private var host = ""
    @State private var port = "47820"
    @State private var code = ""
    @State private var showingScanner = false
    @FocusState private var focusedField: Field?

    private enum Field { case host, port, code }

    var body: some View {
        Form {
            switch link.state {
            case .connected(let size, let device):
                connectedSection(size: size, device: device)
            default:
                inputSection
            }
        }
        .navigationTitle("连接投影仪")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingScanner) {
            ProjectorScannerView { uri in
                showingScanner = false
                guard let pairing = ProjectorPairing(uri: uri) else { return }
                link.connect(to: pairing)
            }
        }
        .onAppear(perform: fillFromSavedPairing)
    }

    // MARK: - 还没连上

    private var inputSection: some View {
        Group {
            Section {
                Button {
                    showingScanner = true
                } label: {
                    Label("扫描投影仪上的二维码", systemImage: "qrcode.viewfinder")
                }
            }

            Section("手动输入") {
                LabeledContent("地址") {
                    TextField("192.168.1.10", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .host)
                }
                LabeledContent("端口") {
                    TextField("47820", text: $port)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .port)
                }
                LabeledContent("配对码") {
                    TextField("6 位数字", text: $code)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .code)
                }
                Button("连接", action: connectManually)
                    .disabled(!canConnect)
            }

            if case .waiting(let reason) = link.state {
                Section {
                    Text(reason)
                        .font(.footnote)
                        .foregroundColor(Theme.ColorToken.Text.secondary)
                }
            }
            if case .connecting = link.state {
                Section {
                    HStack(spacing: Theme.Spacing.sm) {
                        ProgressView()
                        Text("正在连接")
                    }
                }
            }
        }
    }

    // MARK: - 已经连上

    private func connectedSection(size: CGSize, device: String) -> some View {
        Group {
            Section {
                LabeledContent("投影仪", value: device.isEmpty ? "已连接" : device)
                LabeledContent("画面尺寸", value: "\(Int(size.width)) × \(Int(size.height))")
            }
            Section {
                Button("断开连接") { link.disconnect() }
                Button("忘记这台投影仪", role: .destructive) {
                    link.forgetDevice()
                    host = ""; code = ""
                }
            }
        }
    }

    // MARK: -

    private var canConnect: Bool {
        !Self.normalizedHost(host).isEmpty && Int(port) != nil
            && code.count == 6 && Int(code) != nil
    }

    private func connectManually() {
        guard let portNumber = Int(port) else { return }
        focusedField = nil
        link.connect(to: ProjectorPairing(host: Self.normalizedHost(host),
                                          port: portNumber, shortCode: code))
    }

    /// 中文输入法下敲小数点出来的是全角句号，而用户是照着投影仪屏幕上那串地址抄的，
    /// 不会注意到这个区别 —— 抄完点「连接」，只会看到连不上。
    private static func normalizedHost(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "。", with: ".")
            .replacingOccurrences(of: "．", with: ".")
    }

    /// 上次连过哪台就把地址填回去。短码每次开 App 都会换，所以不填 ——
    /// 填一个过期的码，用户会以为点「连接」就能连上。
    private func fillFromSavedPairing() {
        guard let pairing = link.pairing else { return }
        if host.isEmpty { host = pairing.host }
        port = String(pairing.port)
    }
}

/// 还没连上投影仪时，板子摘要下面那一行入口。
///
/// 跟 `ProjectorStatusChip` 摆在同一个位置、同一套样式：连上之前和之后，用户看的是
/// 同一行，只是那行字变了。
struct ProjectorConnectChip: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Label("连接投影仪", systemImage: "videoprojector")
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
            }
            .font(.caption2.weight(.medium))
            .foregroundColor(Theme.ColorToken.Morandi.mauve)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Theme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
