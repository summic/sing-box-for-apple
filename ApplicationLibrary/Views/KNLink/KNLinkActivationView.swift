import Library
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

//
//  KNLink 设备激活界面与登录后流程
//
//  用法（OAuth 登录完成后）：用 KNLinkActivationGate 包住主界面即可——
//      KNLinkActivationGate {
//          MainTabView()   // 你的主界面
//      }
//  未激活 → 显示激活页（按钮提示「激活设备」）；点击激活成功 → 弹「设备已激活」小提示 →
//  拉取订阅 → 进入主界面。已激活 → 直接进主界面。
//

// MARK: 登录后总闸：未激活则拦在激活页，激活后放行进主界面

public struct KNLinkActivationGate<Content: View>: View {
    @State private var activated: Bool? = nil // nil=判定中（异步读，避免 init 时阻塞主线程误判）
    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        Group {
            switch activated {
            case .some(true): content()
            case .some(false): KNLinkActivationView(onActivated: { activated = true })
            case .none: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let ok = await KNLink.isActivatedAsync()
            // 已激活（含老用户：当年 activate 时还没有 knlinkMode 逻辑）→ 确保进入 KNLink 模式，
            // 否则启动会走「需要本地 profile」分支报 Missing selected profile。
            if ok { await SharedPreferences.knlinkMode.set(true) }
            activated = ok
        }
    }
}

// MARK: 激活页

public struct KNLinkActivationView: View {
    private enum Phase: Equatable {
        case idle, activating, pullingSubscription, done
    }

    private let onActivated: () -> Void
    @State private var phase: Phase = .idle
    @State private var alert: AlertState?
    @State private var isLoading = false
    @State private var showToast = false

    public init(onActivated: @escaping () -> Void) {
        self.onActivated = onActivated
    }

    private var busy: Bool { phase == .activating || phase == .pullingSubscription }

    public var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "hand.wave")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("欢迎使用")
                .font(.title2).bold()
            Text("请先激活设备，激活后将自动拉取你的订阅配置。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button(action: activate) {
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Text(buttonTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(busy)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .alert($alert, isLoading: $isLoading)
        .overlay(alignment: .top) {
            if showToast {
                Label("设备已激活", systemImage: "checkmark.circle.fill")
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(radius: 8)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var buttonTitle: String {
        switch phase {
        case .idle: return "激活设备"
        case .activating: return "正在激活…"
        case .pullingSubscription: return "拉取订阅…"
        case .done: return "完成"
        }
    }

    private func activate() {
        phase = .activating
        Task {
            do {
                // 1) 激活：上传公钥、收到加密凭据并落盘（明文不落盘）
                try await KNLink.activate(
                    deviceName: Self.deviceName,
                    deviceType: "singbox",
                    deviceModel: Self.deviceModel,
                    machineCode: Self.machineCode
                )
                // 2) 成功小提示
                await MainActor.run {
                    withAnimation { showToast = true }
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run { withAnimation { showToast = false } }

                // 3) 拉取订阅（即时解密 → 取配置，验证链路通畅；明文仅在内存）
                await MainActor.run { phase = .pullingSubscription }
                _ = try await KNLink.fetchConfigContentJIT()

                // 4) 进入主界面
                await MainActor.run {
                    phase = .done
                    onActivated()
                }
            } catch {
                await MainActor.run {
                    phase = .idle
                    alert = AlertState(action: "激活设备", error: error)
                }
            }
        }
    }

    // MARK: 设备信息（跨平台）

    static var deviceName: String {
        #if canImport(UIKit)
            return UIDevice.current.name
        #elseif os(macOS)
            return Host.current().localizedName ?? "Mac"
        #else
            return "Device"
        #endif
    }

    static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let id = mirror.children.reduce(into: "") { acc, e in
            if let v = e.value as? Int8, v != 0 { acc.append(Character(UnicodeScalar(UInt8(v)))) }
        }
        return id.isEmpty ? "unknown" : id
    }

    static var machineCode: String? {
        #if canImport(UIKit)
            return UIDevice.current.identifierForVendor?.uuidString
        #else
            return nil
        #endif
    }
}
