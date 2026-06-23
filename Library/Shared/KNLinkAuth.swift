import AuthenticationServices
import CryptoKit
import Foundation
import Security
#if canImport(UIKit)
    import UIKit
#endif

public extension Notification.Name {
    /// KNLink 登录态变化：登录成功、主动退出、refresh token 失效。
    static let knlinkAuthChanged = Notification.Name("KNLinkAuthChanged")
}

//
//  KN Account 登录（标准 OIDC · 移动端公有客户端 + PKCE）
//
//  App 自己持有并自动刷新 Hydra 令牌：
//   1. PKCE 授权（scope: openid offline_access）→ 拿 code；
//   2. App 直连 Hydra /oauth2/token 换 access_token + refresh_token（公有客户端，无 secret）；
//   3. access/refresh 存 Keychain；access 过期用 refresh 自动刷新（Hydra 会轮换 refresh）；
//   4. 调我方 API 用 access_token 作 Bearer；服务端用 /userinfo 校验。
//
//  需在 Info.plist 注册 scheme "knlink"，且 Hydra 移动端客户端登记 redirect_uri knlink://auth/callback、
//  允许 offline_access 与 PKCE。
//

public enum KNLinkAuth {
    public static var callbackScheme = "knlink"
    public static var redirectURI: String { "\(callbackScheme)://auth/callback" }
    private static let currentMobileClientID = "kn-b4af6eff94ca"
    private static let legacyMobileClientIDs = Set(["kn-6c7a31265d89", "kn-495268bae840"])

    public enum AuthError: Error, LocalizedError {
        case cancelled, noToken, badCallback, stateMismatch
        case tokenEndpoint(String)
        case notLoggedIn
        case refreshFailed(String)

        public var errorDescription: String? {
            switch self {
            case .cancelled: return "登录已取消"
            case .noToken: return "未拿到授权码"
            case .badCallback: return "回调地址异常"
            case .stateMismatch: return "状态校验失败（state 不一致）"
            case let .tokenEndpoint(m): return "令牌/授权端点错误：\(m)"
            case .notLoggedIn: return "尚未登录"
            case let .refreshFailed(m): return "刷新登录态失败：\(m)"
            }
        }
    }

    public static var isLoggedIn: Bool {
        // 长登录必须依赖 refresh token；只有 access token 的会话会在短时间内必然过期。
        Keychain.get(.refresh) != nil
    }

    public static func logout() async {
        clearStoredTokens()
        await clearUserInfoCache()
        postAuthChanged()
    }

    /// 会话失效只清登录令牌，不清设备激活状态和私钥；重新登录后可继续使用原设备身份。
    public static func expireSession(reason: String) async {
        NSLog("[KNLink][auth] session expired: %@", reason)
        KNLink.configDebugLog("[auth] session expired: \(reason)")
        clearStoredTokens()
        await clearUserInfoCache()
        postAuthChanged()
    }

    public static func validateStoredSession() async {
        guard isLoggedIn else { return }
        _ = try? await accessToken()
    }

    // MARK: 登录（PKCE）

    @MainActor
    public static func login(presentationAnchor: ASPresentationAnchor? = nil) async throws {
        #if os(tvOS)
        throw AuthError.cancelled
        #else
        let ssoBase = await SharedPreferences.knlinkSsoBase.get()
        let clientID = await mobileClientID()

        let verifier = randomURLSafe(64)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomURLSafe(16)

        guard var comps = URLComponents(string: "\(ssoBase)/oauth2/auth") else { throw AuthError.badCallback }
        comps.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: "openid profile email offline_access"), // profile/email→用户信息，offline_access→refresh token
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        guard let authURL = comps.url else { throw AuthError.badCallback }

        // 1) 浏览器授权 → code
        let provider = AnchorProvider(anchor: presentationAnchor)
        let code: String = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { callbackURL, error in
                liveSession = nil; liveProvider = nil
                if let error {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    cont.resume(throwing: cancelled ? AuthError.cancelled : error); return
                }
                guard let callbackURL, let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems else {
                    cont.resume(throwing: AuthError.badCallback); return
                }
                if items.first(where: { $0.name == "state" })?.value != state { cont.resume(throwing: AuthError.stateMismatch); return }
                guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { cont.resume(throwing: AuthError.noToken); return }
                cont.resume(returning: code)
            }
            session.presentationContextProvider = provider // 此属性为 weak，必须强引用
            session.prefersEphemeralWebBrowserSession = false
            liveSession = session; liveProvider = provider
            if !session.start() { liveSession = nil; liveProvider = nil; cont.resume(throwing: AuthError.cancelled) }
        }

        // 2) 直连 Hydra 换 access + refresh
        let form = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ]
        let tok = try await postToken(ssoBase: ssoBase, form: form)
        try store(tok, requireRefresh: true)
        #endif
    }

    // MARK: 设备码登录（RFC 8628 · 用于 Apple TV，免在电视上输账号）

    public struct DeviceCode {
        public let userCode: String              // 给用户看的配对码
        public let verificationURI: String       // 用户在手机/电脑打开的网址
        public let verificationURIComplete: String? // 含配对码的快捷网址（可生成二维码）
        let deviceCode: String                   // 轮询用（内部）
        let interval: Int
        public let expiresIn: Int
    }

    private struct DeviceAuthResponse: Codable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let verification_uri_complete: String?
        let expires_in: Int?
        let interval: Int?
    }

    /// 第一步：向 Hydra 申请设备码，拿到给用户看的配对码 + 验证网址。
    public static func startDeviceCode() async throws -> DeviceCode {
        let ssoBase = await SharedPreferences.knlinkSsoBase.get()
        let clientID = await SharedPreferences.knlinkSsoDeviceClientID.get() // 设备码专用客户端
        var req = URLRequest(url: URL(string: "\(ssoBase)/oauth2/device/auth")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = ["client_id": clientID, "scope": "openid profile email offline_access"]
        req.httpBody = form.map { "\($0.key)=\(urlEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.tokenEndpoint(String(data: data, encoding: .utf8) ?? "device/auth")
        }
        let r = try JSONDecoder().decode(DeviceAuthResponse.self, from: data)
        // 显示给用户的验证网址固定用 KN 自有页面 <ssoBase>/device（而非 Hydra 默认返回值）
        return DeviceCode(userCode: r.user_code, verificationURI: "\(ssoBase)/device",
                          verificationURIComplete: r.verification_uri_complete,
                          deviceCode: r.device_code, interval: r.interval ?? 5, expiresIn: r.expires_in ?? 600)
    }

    /// 第二步：轮询 token 端点，直到用户在别的设备完成授权（或超时/拒绝）。成功即存令牌。
    public static func pollDeviceToken(_ dc: DeviceCode) async throws {
        let ssoBase = await SharedPreferences.knlinkSsoBase.get()
        let clientID = await SharedPreferences.knlinkSsoDeviceClientID.get() // 设备码专用客户端（与取码一致）
        var interval = max(dc.interval, 1)
        let deadline = Date().timeIntervalSince1970 + Double(dc.expiresIn)
        while Date().timeIntervalSince1970 < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            var req = URLRequest(url: URL(string: "\(ssoBase)/oauth2/token")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let form = [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": dc.deviceCode,
                "client_id": clientID,
            ]
            req.httpBody = form.map { "\($0.key)=\(urlEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code == 200 {
                try store(try JSONDecoder().decode(TokenResponse.self, from: data), requireRefresh: true)
                return
            }
            let obj = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
            switch (obj["error"] as? String) ?? "" {
            case "authorization_pending": continue          // 用户还没授权，继续等
            case "slow_down": interval += 5                  // 轮太快，放慢
            case "access_denied": throw AuthError.cancelled  // 用户拒绝
            case "expired_token": throw AuthError.tokenEndpoint("配对码已过期，请重试")
            default: throw AuthError.tokenEndpoint(String(data: data, encoding: .utf8) ?? "device token")
            }
        }
        throw AuthError.tokenEndpoint("配对码已过期，请重试")
    }

    // MARK: 取（必要时刷新）access token —— 所有 API 调用前用它

    public static func accessToken() async throws -> String {
        let now = Date().timeIntervalSince1970
        if let access = Keychain.get(.access), let expStr = Keychain.get(.accessExpiry), let exp = Double(expStr), exp - 60 > now {
            return access // 未过期（留 60s 余量）
        }
        // 过期 → 用 refresh 刷新（client_id 必须与登录时一致：tvOS 设备码用设备客户端）
        guard let refresh = Keychain.get(.refresh) else {
            await expireSession(reason: "missing refresh token")
            throw AuthError.notLoggedIn
        }
        let ssoBase = await SharedPreferences.knlinkSsoBase.get()
        #if os(tvOS)
            let clientID = await SharedPreferences.knlinkSsoDeviceClientID.get()
        #else
            let clientID = await mobileClientID()
        #endif
        do {
            let tok = try await postToken(ssoBase: ssoBase, form: [
                "grant_type": "refresh_token",
                "refresh_token": refresh,
                "client_id": clientID,
            ])
            try store(tok, requireRefresh: false)
            guard let access = Keychain.get(.access) else { throw AuthError.refreshFailed("no access") }
            return access
        } catch {
            if isTerminalRefreshError(error) {
                await expireSession(reason: "\(error)")
            }
            throw AuthError.refreshFailed("\(error)")
        }
    }

    // MARK: 当前用户信息（直接来自 KN Account / Hydra 的 OIDC userinfo）

    /// userinfo 的字段名由 KN Account 决定（元数据只声明了 sub），故整包读入、按常见声明名兜底取值。
    public struct UserInfo {
        public let fields: [String: String] // userinfo 原始声明（已字符串化）
        public var sub: String { fields["sub"] ?? "" }
        public var email: String? { nonEmpty("email") }
        public var picture: String? {
            for k in ["picture", "avatar", "avatar_url", "photo", "photo_url", "image", "image_url"] {
                if let v = nonEmpty(k) { return v }
            }
            return nil
        }
        /// 中文名/展示名：依次尝试常见声明
        public var display: String {
            for k in ["name", "nickname", "display_name", "displayName", "preferred_username", "username", "given_name"] {
                if let v = nonEmpty(k) { return v }
            }
            if let f = nonEmpty("family_name"), let g = nonEmpty("given_name") { return f + g }
            return email ?? sub
        }
        private func nonEmpty(_ k: String) -> String? { let v = fields[k]; return (v?.isEmpty == false) ? v : nil }
    }

    /// 取当前登录用户——直接请求 KN Account 的 OIDC `/userinfo`（带 access token，必要时自动刷新）。
    public static func userInfo() async throws -> UserInfo {
        if let cached = await cachedUserInfo() {
            return cached
        }
        let ssoBase = await SharedPreferences.knlinkSsoBase.get()
        let token = try await accessToken()
        var req = URLRequest(url: URL(string: "\(ssoBase)/userinfo")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            if status == 401 {
                await expireSession(reason: "userinfo returned 401")
            }
            throw AuthError.tokenEndpoint("userinfo HTTP \(status)")
        }
        #if DEBUG
            print("[KNLink] userinfo raw: \(String(data: data, encoding: .utf8) ?? "")") // 看真实字段名
        #endif
        let obj = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        var fields: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String { fields[k] = s }
            else if let n = v as? NSNumber { fields[k] = n.stringValue }
            else if !(v is NSNull) { fields[k] = "\(v)" }
        }
        await cacheUserInfo(fields)
        return UserInfo(fields: fields)
    }

    private static func cachedUserInfo() async -> UserInfo? {
        let expiry = await SharedPreferences.knlinkCachedUserInfoExpiry.get()
        guard expiry - 60 > Date().timeIntervalSince1970 else { return nil }
        let fields = await SharedPreferences.knlinkCachedUserInfo.get()
        guard !fields.isEmpty else { return nil }
        return UserInfo(fields: fields)
    }

    private static func cacheUserInfo(_ fields: [String: String]) async {
        guard !fields.isEmpty else { return }
        let expiry = accessTokenExpiry() ?? (Date().timeIntervalSince1970 + 3600)
        await SharedPreferences.knlinkCachedUserInfo.set(fields)
        await SharedPreferences.knlinkCachedUserInfoExpiry.set(expiry)
    }

    public static func clearUserInfoCache() async {
        await SharedPreferences.knlinkCachedUserInfo.set(nil)
        await SharedPreferences.knlinkCachedUserInfoExpiry.set(nil)
        await SharedPreferences.knlinkCachedUserAvatarURL.set(nil)
        await SharedPreferences.knlinkCachedUserAvatarData.set(nil)
    }

    // MARK: Hydra token 端点

    private struct TokenResponse: Codable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
        let scope: String?
    }

    private static func postToken(ssoBase: String, form: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "\(ssoBase)/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\(urlEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.tokenEndpoint(String(data: data, encoding: .utf8) ?? "token")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func store(_ tok: TokenResponse, requireRefresh: Bool) throws {
        // fail-fast：明确记录服务端到底给没给 refresh_token / 授予了哪些 scope
        let msg = "[auth] token 响应：access=有 refresh=\(tok.refresh_token != nil ? "有" : "无") scope=\(tok.scope ?? "<空>") expires_in=\(tok.expires_in.map { String(Int($0)) } ?? "?")"
        NSLog("%@", msg); KNLink.configDebugLog(msg)
        if tok.refresh_token == nil {
            let warn = "[auth] ⚠️ 没有 refresh_token —— access 过期后无法刷新，会反复掉登录。检查 Hydra 客户端是否启用 offline_access scope + refresh_token grant，且 scope 请求含 offline_access"
            NSLog("%@", warn); KNLink.configDebugLog(warn)
            if requireRefresh {
                clearStoredTokens()
                throw AuthError.tokenEndpoint("没有 refresh_token，无法保持长期登录。请检查 OAuth 客户端是否允许 offline_access 和 refresh_token grant。")
            }
        }
        let exp = Date().timeIntervalSince1970 + (tok.expires_in ?? 3600)
        guard Keychain.set(.access, tok.access_token) else {
            clearStoredTokens()
            throw AuthError.tokenEndpoint("access token 未能写入 Keychain，登录态无法持久化")
        }
        if let r = tok.refresh_token {
            guard Keychain.set(.refresh, r) else {
                clearStoredTokens()
                throw AuthError.tokenEndpoint("refresh token 未能写入 Keychain，登录态无法持久化")
            }
        }
        guard Keychain.set(.accessExpiry, String(exp)) else {
            clearStoredTokens()
            throw AuthError.tokenEndpoint("token 过期时间未能写入 Keychain，登录态无法持久化")
        }
        if requireRefresh {
            Task { await clearUserInfoCache() }
        } else {
            Task { await refreshUserInfoCacheExpiry(expiry: exp) }
        }
    }

    private static func refreshUserInfoCacheExpiry(expiry: Double) async {
        let fields = await SharedPreferences.knlinkCachedUserInfo.get()
        guard !fields.isEmpty else { return }
        await SharedPreferences.knlinkCachedUserInfoExpiry.set(expiry)
    }

    private static func accessTokenExpiry() -> Double? {
        guard let expStr = Keychain.get(.accessExpiry) else { return nil }
        return Double(expStr)
    }

    private static func mobileClientID() async -> String {
        let stored = await SharedPreferences.knlinkSsoMobileClientID.get()
        if legacyMobileClientIDs.contains(stored) || stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await SharedPreferences.knlinkSsoMobileClientID.set(currentMobileClientID)
            return currentMobileClientID
        }
        return stored
    }

    private static func isTerminalRefreshError(_ error: Error) -> Bool {
        let message = "\(error)".lowercased()
        return message.contains("invalid_grant") ||
            message.contains("invalid_request") ||
            message.contains("unauthorized_client") ||
            message.contains("401")
    }

    private static func clearStoredTokens() {
        Keychain.delete(.access)
        Keychain.delete(.refresh)
        Keychain.delete(.accessExpiry)
    }

    private static func postAuthChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .knlinkAuthChanged, object: nil)
        }
    }

    // MARK: 工具

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var buf = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
        return base64URL(Data(buf))
    }

    private static func urlEncode(_ s: String) -> String {
        var cs = CharacterSet.urlQueryAllowed
        cs.remove(charactersIn: "+&=")
        return s.addingPercentEncoding(withAllowedCharacters: cs) ?? s
    }

    #if !os(tvOS)
    // ASWebAuthenticationSession 强引用持有（session 不自留、provider 为 weak）。
    private static var liveSession: ASWebAuthenticationSession?
    private static var liveProvider: AnchorProvider?

    private final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        let anchor: ASPresentationAnchor?
        init(anchor: ASPresentationAnchor?) { self.anchor = anchor }
        func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
            anchor ?? ASPresentationAnchor()
        }
    }
    #endif

    // MARK: 令牌 Keychain（access/refresh 敏感，存 Keychain 而非明文偏好）

    private enum Keychain {
        enum K: String { case access = "knlink.access", refresh = "knlink.refresh", accessExpiry = "knlink.access_exp" }
        // 有共享组权限就用共享组（扩展可读）；缺权限则退回默认组（仍能持久化）。两种都试。
        static var groups: [String?] {
            let g = KNLink.keychainAccessGroup
            return g == nil ? [nil] : [g, nil]
        }

        // 跨平台一致：强制用 data-protection keychain（iOS 默认即此；macOS 默认是文件钥匙串，
        // access group 共享/持久化不可靠）。否则 macOS 上扩展读不到令牌、刷新时还可能丢失。
        private static func baseQuery(_ k: K, group: String?) -> [String: Any] {
            var q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: k.rawValue,
                kSecUseDataProtectionKeychain as String: true,
            ]
            if let group { q[kSecAttrAccessGroup as String] = group }
            return q
        }

        // fail-fast：每步都打 OSStatus + 组，失败立刻大声报，绝不静默吞掉。
        private static func log(_ msg: String) {
            NSLog("[KNLink][keychain] %@", msg)
            KNLink.configDebugLog("[keychain] \(msg)")
        }

        // 非破坏式写：先 update，不存在再 add。绝不先删——避免 add 失败把令牌弄丢导致频繁掉登录。
        @discardableResult
        static func set(_ k: K, _ value: String) -> Bool {
            let data = Data(value.utf8)
            for group in groups {
                let g = group ?? "<default>"
                let query = baseQuery(k, group: group)
                let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
                if updated == errSecSuccess { log("set \(k.rawValue): updated in \(g)"); return true }
                if updated == errSecItemNotFound {
                    var add = query
                    add[kSecValueData as String] = data
                    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                    let added = SecItemAdd(add as CFDictionary, nil)
                    if added == errSecSuccess { log("set \(k.rawValue): added in \(g)"); return true }
                    log("set \(k.rawValue): ADD FAILED in \(g) OSStatus=\(added)")
                } else {
                    log("set \(k.rawValue): UPDATE FAILED in \(g) OSStatus=\(updated)")
                }
            }
            log("⚠️ set \(k.rawValue): FAILED in ALL groups — 令牌未持久化")
            return false
        }

        static func get(_ k: K) -> String? {
            for group in groups {
                let g = group ?? "<default>"
                var q = baseQuery(k, group: group)
                q[kSecReturnData as String] = true
                var item: CFTypeRef?
                let status = SecItemCopyMatching(q as CFDictionary, &item)
                if status == errSecSuccess, let d = item as? Data {
                    log("get \(k.rawValue): hit in \(g)")
                    return String(data: d, encoding: .utf8)
                }
                if status != errSecItemNotFound { log("get \(k.rawValue): ERROR in \(g) OSStatus=\(status)") }
            }
            log("get \(k.rawValue): not found in any group")
            return nil
        }

        static func delete(_ k: K) {
            for group in groups {
                SecItemDelete(baseQuery(k, group: group) as CFDictionary)
            }
        }
    }
}
