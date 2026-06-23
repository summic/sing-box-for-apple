import AuthenticationServices
import Library
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

//
//  KN Account 登录页 + 总闸
//
//  用法：用 KNLinkSessionGate 包住主界面：
//      KNLinkSessionGate { MainTabView() }
//  未登录 → 登录页；登录后未激活 → 激活页；都就绪 → 主界面。
//

// MARK: 总闸：登录 → 激活 → 主界面

public struct KNLinkSessionGate<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var loggedIn = KNLinkAuth.isLoggedIn
    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        Group {
            if loggedIn {
                KNLinkActivationGate { content() }
            } else {
                KNLinkLoginView(onLoggedIn: { loggedIn = true })
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .knlinkAuthChanged)) { _ in
            loggedIn = KNLinkAuth.isLoggedIn // 退出登录后回到登录页
        }
        .task {
            await KNLinkAuth.validateStoredSession()
        }
        .onChangeCompat(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task {
                await KNLinkAuth.validateStoredSession()
            }
        }
    }
}

// MARK: 登录页

public struct KNLinkLoginView: View {
    private let onLoggedIn: () -> Void
    @State private var busy = false
    @State private var alert: AlertState?
    @State private var isLoading = false
    #if os(tvOS)
        @State private var deviceCode: KNLinkAuth.DeviceCode? // 设备码（显示给用户）
    #endif

    public init(onLoggedIn: @escaping () -> Void) {
        self.onLoggedIn = onLoggedIn
    }

    public var body: some View {
        #if os(tvOS)
            tvBody // Apple TV：OAuth 设备码（免在电视上输账号）
        #else
            webBody // iOS / macOS：网页授权（ASWebAuthenticationSession）
        #endif
    }

    // MARK: tvOS —— 设备码登录

    #if os(tvOS)
        private var tvBody: some View {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "person.badge.key").font(.system(size: 72)).foregroundStyle(.tint)
                Text("使用 KN Account 登录").font(.title).bold()
                if let dc = deviceCode {
                    Text("用手机或电脑浏览器打开").font(.title3).foregroundStyle(.secondary)
                    Text(dc.verificationURI).font(.title2).bold().foregroundStyle(.tint)
                    Text("输入配对码").font(.title3).foregroundStyle(.secondary).padding(.top, 8)
                    Text(dc.userCode).font(.system(size: 64, weight: .bold, design: .monospaced))
                    HStack(spacing: 10) { ProgressView(); Text("等待授权完成…") }
                        .foregroundStyle(.secondary).padding(.top, 12)
                } else {
                    Text("授权后将自动拉取你的订阅配置。").font(.title3)
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(action: startDeviceFlow) {
                        HStack { if busy { ProgressView() }; Text(busy ? "获取配对码…" : "用 KN 账号登录") }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(busy)
                }
                Spacer()
            }
            .alert($alert, isLoading: $isLoading)
        }

        private func startDeviceFlow() {
            busy = true
            Task {
                do {
                    let dc = try await KNLinkAuth.startDeviceCode()
                    await MainActor.run { deviceCode = dc; busy = false }
                    try await KNLinkAuth.pollDeviceToken(dc) // 轮询直到授权完成
                    await MainActor.run {
                        NotificationCenter.default.post(name: .knlinkAuthChanged, object: nil)
                        onLoggedIn()
                    }
                } catch KNLinkAuth.AuthError.cancelled {
                    await MainActor.run { deviceCode = nil; busy = false } // 取消/拒绝，回到初始
                } catch {
                    await MainActor.run { deviceCode = nil; busy = false; alert = AlertState(action: "登录", error: error) }
                }
            }
        }
    #endif

    // MARK: iOS / macOS —— 网页授权

    #if !os(tvOS)
        private var webBody: some View {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "person.badge.key")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("使用 KN Account 登录")
                    .font(.title2).bold()
                Text("通过 KN Account 授权登录，本 App 不单独存储账号密码。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
                Button(action: login) {
                    HStack {
                        if busy { ProgressView().controlSize(.small) }
                        Text(busy ? "登录中…" : "用 KN 账号登录")
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
        }

        // 展示锚点由 App 层提供（Library 受 app-extension API 限制无法取窗口）
        private func currentAnchor() -> ASPresentationAnchor? {
            #if canImport(UIKit)
                let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
                return scene?.keyWindow ?? scene?.windows.first
            #elseif canImport(AppKit)
                return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
            #else
                return nil
            #endif
        }

        private func login() {
            busy = true
            let anchor = currentAnchor()
            Task {
                do {
                    _ = try await KNLinkAuth.login(presentationAnchor: anchor)
                    await MainActor.run {
                        busy = false
                        NotificationCenter.default.post(name: .knlinkAuthChanged, object: nil)
                        onLoggedIn()
                    }
                } catch KNLinkAuth.AuthError.cancelled {
                    await MainActor.run { busy = false } // 用户取消，不报错
                } catch {
                    await MainActor.run {
                        busy = false
                        alert = AlertState(action: "登录", error: error)
                    }
                }
            }
        }
    #endif
}
