import Library
import SwiftUI
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

//
//  KN 账号：设置页顶部头部（头像/名字/邮箱）+ 详情（退出登录）
//

// 共享的用户信息加载器
@MainActor
final class KNLinkAccountModel: ObservableObject {
    @Published var info: KNLinkAuth.UserInfo?
    @Published var avatarData: Data?
    @Published var loading = true

    func load() async {
        loading = true
        let loadedInfo = try? await KNLinkAuth.userInfo()
        info = loadedInfo
        let avatarURLs = await Self.avatarURLs(for: loadedInfo)
        if let cached = await Self.cachedAvatarDataOnly(for: avatarURLs) {
            avatarData = cached
        }
        avatarData = await Self.cachedAvatarData(for: avatarURLs)
        loading = false
    }

    private static func avatarURLs(for info: KNLinkAuth.UserInfo?) async -> [URL] {
        guard let info else { return [] }
        var urls: [URL] = []
        let ssoBase = await SharedPreferences.knlinkSsoBase.get()
        let baseURL = URL(string: ssoBase.hasSuffix("/") ? ssoBase : "\(ssoBase)/")
        if let picture = info.picture?.trimmingCharacters(in: .whitespacesAndNewlines), !picture.isEmpty {
            if let url = URL(string: picture), url.scheme != nil {
                urls.append(url)
            } else if let baseURL, let url = URL(string: picture, relativeTo: baseURL)?.absoluteURL {
                urls.append(url)
            }
        }
        if Self.looksLikeUUID(info.sub), let baseURL {
            if let url = URL(string: "api/account/avatar/\(info.sub)", relativeTo: baseURL)?.absoluteURL {
                urls.append(url)
            }
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }

    private static func cachedAvatarData(for urls: [URL]) async -> Data? {
        guard !urls.isEmpty else { return nil }
        let expiry = await SharedPreferences.knlinkCachedUserInfoExpiry.get()
        let cachedURL = await SharedPreferences.knlinkCachedUserAvatarURL.get()
        let cachedData = await SharedPreferences.knlinkCachedUserAvatarData.get()
        let candidates = Set(urls.map(\.absoluteString))
        let staleData = candidates.contains(cachedURL) && !cachedData.isEmpty && isDisplayableImageData(cachedData) ? cachedData : nil
        if expiry - 60 > Date().timeIntervalSince1970, let staleData {
            return staleData
        }
        // 头像图片允许 stale-while-revalidate：网络刷新失败时继续显示本地图片，避免冷启动丢头像。
        guard expiry - 60 <= Date().timeIntervalSince1970 || staleData == nil else {
            return staleData
        }
        for url in urls {
            var request = URLRequest(url: url)
            request.setValue("image/avif,image/webp,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request) else {
                KNLink.configDebugLog("[avatar] fetch failed url=\(url.absoluteString)")
                continue
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<300).contains(status), !data.isEmpty, isDisplayableImageData(data) else {
                KNLink.configDebugLog("[avatar] unusable response status=\(status) bytes=\(data.count) url=\(url.absoluteString)")
                continue
            }
            await SharedPreferences.knlinkCachedUserAvatarURL.set(url.absoluteString)
            await SharedPreferences.knlinkCachedUserAvatarData.set(data)
            return data
        }
        return staleData
    }

    static func cachedAvatarDataOnly(for urls: [URL]) async -> Data? {
        guard !urls.isEmpty else { return nil }
        let cachedURL = await SharedPreferences.knlinkCachedUserAvatarURL.get()
        let cachedData = await SharedPreferences.knlinkCachedUserAvatarData.get()
        let candidates = Set(urls.map(\.absoluteString))
        if candidates.contains(cachedURL), !cachedData.isEmpty, isDisplayableImageData(cachedData) {
            return cachedData
        }
        return nil
    }

    private static func looksLikeUUID(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil
    }

    private static func isDisplayableImageData(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        #if canImport(UIKit)
            return UIImage(data: data) != nil
        #elseif canImport(AppKit)
            return NSImage(data: data) != nil
        #else
            return true
        #endif
    }
}

private struct InitialsAvatar: View {
    let name: String
    let imageData: Data?
    var size: CGFloat = 44
    var body: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.15))
            if let image = cachedImage {
                image
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
    }
    private var cachedImage: Image? {
        guard let imageData else { return nil }
        #if canImport(UIKit)
            guard let image = UIImage(data: imageData) else { return nil }
            return Image(uiImage: image)
        #elseif canImport(AppKit)
            guard let image = NSImage(data: imageData) else { return nil }
            return Image(nsImage: image)
        #else
            return nil
        #endif
    }
    private var initials: some View {
        Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.tint)
    }
}

// MARK: 设置页顶部入口（点进 → 详情可退出登录）

public struct KNLinkAccountRow: View {
    @StateObject private var model = KNLinkAccountModel()
    public init() {}
    public var body: some View {
        NavigationLink {
            KNLinkAccountView(model: model)
        } label: {
            HStack(spacing: 12) {
                InitialsAvatar(name: model.info?.display ?? "?", imageData: model.avatarData)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.info?.display ?? (model.loading ? "加载中…" : "未登录"))
                        .font(.headline).foregroundStyle(.primary)
                    if let email = model.info?.email, !email.isEmpty {
                        Text(email).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .task { if model.info == nil { await model.load() } }
    }
}

// MARK: 账号详情（退出登录）

public struct KNLinkAccountView: View {
    @ObservedObject var model: KNLinkAccountModel
    @State private var loggingOut = false

    init(model: KNLinkAccountModel) { self.model = model }

    @State private var copiedField: String?
    @State private var deviceID = ""

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // 头部：头像 + 名字 + 邮箱（居中）
                VStack(spacing: 12) {
                    InitialsAvatar(name: model.info?.display ?? "?", imageData: model.avatarData, size: 76)
                    VStack(spacing: 4) {
                        Text(model.info?.display ?? (model.loading ? "加载中…" : "未登录"))
                            .font(.title2).bold()
                        if let email = model.info?.email, !email.isEmpty {
                            Text(email).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

                // 账号 ID / 设备 ID 卡片（长 ID 中间省略，可一键复制）
                VStack(spacing: 0) {
                    if let sub = model.info?.sub, !sub.isEmpty {
                        idRow(label: "账号 ID", value: sub, key: "sub")
                    }
                    if !deviceID.isEmpty {
                        if !(model.info?.sub ?? "").isEmpty {
                            Divider().padding(.leading, 14)
                        }
                        idRow(label: "设备 ID", value: deviceID, key: "device")
                    }
                }
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                // 退出登录
                Button(role: .destructive) { logout() } label: {
                    HStack(spacing: 8) {
                        if loggingOut { ProgressView().controlSize(.small) }
                        Text("退出登录")
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(loggingOut)

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("账号")
        .task {
            if model.info == nil { await model.load() }
            let currentDeviceID = await SharedPreferences.knlinkDeviceID.get()
            if currentDeviceID.isEmpty {
                deviceID = await SharedPreferences.knlinkDeviceIDBackup.get()
            } else {
                deviceID = currentDeviceID
            }
        }
    }

    // 一行 ID（标签 + 等宽值 + 复制按钮）
    private func idRow(label: String, value: String, key: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout.monospaced())
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button { copy(value, key: key) } label: {
                Image(systemName: copiedField == key ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copiedField == key ? Color.green : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .help("复制")
        }
        .padding(14)
    }

    private func copy(_ text: String, key: String) {
        #if canImport(UIKit)
            UIPasteboard.general.string = text
        #elseif canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #endif
        copiedField = key
        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copiedField = nil }
    }

    private func logout() {
        loggingOut = true
        Task {
            await KNLinkAuth.logout() // 只清登录令牌；保留设备 ID 和私钥
            NotificationCenter.default.post(name: .knlinkAuthChanged, object: nil) // 总闸回到登录页
        }
    }
}
