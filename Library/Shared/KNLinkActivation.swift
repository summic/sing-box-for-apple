import CryptoKit
import Foundation
import Security

//
//  KNLink 设备激活 + 凭据即时解密
//
//  设计原则：明文凭据「越晚解密越好」，暴露时间最短。
//   • 私钥：生成后存 Keychain（不可导出、kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly，
//     App 与 Network Extension 共用 access group）。
//   • 落盘的只有「密文 blob」（服务端用公钥混合加密的结果），落盘安全。
//   • 解密只在「要连接的那一刻」做（见 Extension 启动隧道处调用 decryptCredentials()），
//     得到的 ActivationPayload 仅存在于内存，用完即随作用域释放，绝不写盘、不缓存。
//
//  与服务端约定（worker/lib/crypto.js）：
//   公钥：RSA-OAEP(SHA-256)，SPKI DER 的 base64。
//   响应：{ alg, encryptedKey(=RSA(AESkey)), iv(12B), ciphertext(=AES-GCM(payload)，尾部含16B tag) }
//

public enum KNLink {
    /// 服务端地址：取自 SharedPreferences.knlinkServerBase（设置页可改）。
    private static func serverBase() async -> String { await SharedPreferences.knlinkServerBase.get() }

    /// Keychain 私钥标签
    private static let privateKeyTag = "com.knlink.device.private-key".data(using: .utf8)!

    /// Keychain 共享访问组（App 与扩展共用私钥）。需在双方 entitlements 声明。nil=仅当前进程。
    public static var keychainAccessGroup: String? = AppConfiguration.keychainAccessGroup

    public enum ActivationError: Error, LocalizedError {
        case missingPrivateKey
        case badResponse(Int, String)
        case decrypt(String)
        case notPersisted(String) // 本地持久化失败（deviceId / 私钥），不再静默吞掉

        public var errorDescription: String? {
            switch self {
            case .missingPrivateKey: return "缺少设备私钥，请重新激活"
            case let .badResponse(code, msg): return "激活请求失败（HTTP \(code)）：\(msg)"
            case let .decrypt(m): return "密钥/解密错误：\(m)"
            case let .notPersisted(m): return "本地保存失败：\(m)"
            }
        }
    }

    /// 加密配置块（服务端用本设备公钥混合加密：RSA-OAEP(AESkey) + AES-GCM(payload)）
    public struct EncryptedBlob: Codable {
        public let alg: String
        public let encryptedKey: String
        public let iv: String
        public let ciphertext: String
    }

    private struct ActivateResult: Codable {
        let deviceId: String?
        let clientId: String?
        let deviceToken: String?
        let configId: String?
        let region: String?
    }

    // MARK: 激活（首次登录后调用一次）

    /// 本地生成密钥对 → 上传公钥（用 Hydra access token 鉴权）→ 服务端建档并返回 deviceId（存本地，
    /// 之后配置请求带 ?device=<id> 指明用哪台设备的公钥加密）。私钥常驻 Keychain，永不离开设备。
    public static func activate(deviceName: String, deviceType: String = "singbox", deviceModel: String? = nil, machineCode: String? = nil) async throws {
        let publicKeySPKI = try ensurePublicKeySPKIBase64()
        let serverBase = await serverBase()
        let token = try await KNLinkAuth.accessToken() // 必要时自动刷新

        var req = URLRequest(url: URL(string: "\(serverBase)/api/client/activate")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["publicKey": publicKeySPKI, "deviceType": deviceType, "deviceName": deviceName]
        if let deviceModel { body["deviceModel"] = deviceModel }
        if let machineCode { body["machineCode"] = machineCode }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if code == 401 {
            await KNLinkAuth.expireSession(reason: "activate returned 401")
        }
        guard code == 200 else { throw ActivationError.badResponse(code, String(data: data, encoding: .utf8) ?? "") }
        let result = try JSONDecoder().decode(ActivateResult.self, from: data)
        guard let deviceId = result.deviceId ?? result.clientId else { throw ActivationError.badResponse(code, "no deviceId") }

        // 本地持久化 + 回读校验：任何一步没成功都立刻抛错（不要吞），方便定位是 deviceId 还是私钥没写上
        await SharedPreferences.knlinkDeviceID.set(deviceId)
        await SharedPreferences.knlinkDeviceIDBackup.set(deviceId)
        if let deviceToken = result.deviceToken, !deviceToken.isEmpty {
            await SharedPreferences.knlinkDeviceToken.set(deviceToken)
        }
        let persisted = await SharedPreferences.knlinkDeviceID.get()
        guard persisted == deviceId else {
            throw ActivationError.notPersisted("deviceId 未写入本地存储（SharedPreferences 写入未生效），回读为「\(persisted)」")
        }
        guard hasStoredPrivateKey() else {
            throw ActivationError.notPersisted("私钥未写入 Keychain，扩展将无法解密。检查 App 与扩展的 keychain-access-groups 是否一致")
        }
        await SharedPreferences.knlinkMode.set(true) // 激活后走 KNLink 模式：连接时即时拉取+解密配置（无需本地 profile）
        let modeReadback = await SharedPreferences.knlinkMode.get()
        configDebugLog("[app] activate done deviceId=\(deviceId) knlinkMode set->true readback=\(modeReadback)")
    }

    /// 返回服务端颁发的设备上报令牌。兼容旧版本：本机已激活但本地还没有 deviceToken 时，
    /// 静默调用统一 register 接口按公钥找回并持久化，供 /api/report 使用。
    public static func ensureDeviceToken(deviceName: String = "iOS Device", deviceType: String = "singbox", deviceModel: String? = nil, machineCode: String? = nil) async throws -> String {
        let cached = await SharedPreferences.knlinkDeviceToken.get()
        if !cached.isEmpty { return cached }

        let deviceID = await storedDeviceID()
        guard !deviceID.isEmpty, hasStoredPrivateKey() else {
            throw ActivationError.decrypt("device not activated")
        }

        let publicKeySPKI = try ensurePublicKeySPKIBase64()
        let serverBase = await serverBase()
        let token = try await KNLinkAuth.accessToken()

        var req = URLRequest(url: URL(string: "\(serverBase)/api/client/register")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "publicKey": publicKeySPKI,
            "deviceType": deviceType,
            "deviceName": deviceName,
        ]
        if let deviceModel { body["deviceModel"] = deviceModel }
        if let machineCode { body["machineCode"] = machineCode }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if code == 401 {
            await KNLinkAuth.expireSession(reason: "device-token register returned 401")
        }
        guard code == 200 else { throw ActivationError.badResponse(code, String(data: data, encoding: .utf8) ?? "") }
        let result = try JSONDecoder().decode(ActivateResult.self, from: data)
        if let returnedDeviceID = result.deviceId ?? result.clientId, !returnedDeviceID.isEmpty {
            await SharedPreferences.knlinkDeviceID.set(returnedDeviceID)
            await SharedPreferences.knlinkDeviceIDBackup.set(returnedDeviceID)
        }
        guard let deviceToken = result.deviceToken, !deviceToken.isEmpty else {
            throw ActivationError.badResponse(code, "no deviceToken")
        }
        await SharedPreferences.knlinkDeviceToken.set(deviceToken)
        return deviceToken
    }

    /// 同步判定（兼容旧用法）；视图请优先用 isActivatedAsync()。私钥须在 Keychain(扩展可读)。
    public static var isActivated: Bool {
        !storedDeviceIDBlocking().isEmpty && hasStoredPrivateKey()
    }

    /// 异步判定：deviceId 已存 且 私钥在 Keychain。私钥缺失 → 视为未激活，触发重新激活迁移。
    public static func isActivatedAsync() async -> Bool {
        let id = await storedDeviceID()
        guard !id.isEmpty else { return false }
        return hasStoredPrivateKey()
    }

    private static func storedDeviceIDBlocking() -> String {
        let current = SharedPreferences.knlinkDeviceID.getBlocking()
        if !current.isEmpty { return current }
        return SharedPreferences.knlinkDeviceIDBackup.getBlocking()
    }

    private static func storedDeviceID() async -> String {
        let current = await SharedPreferences.knlinkDeviceID.get()
        if !current.isEmpty {
            let backup = await SharedPreferences.knlinkDeviceIDBackup.get()
            if backup.isEmpty {
                await SharedPreferences.knlinkDeviceIDBackup.set(current)
            }
            return current
        }
        let backup = await SharedPreferences.knlinkDeviceIDBackup.get()
        if !backup.isEmpty {
            await SharedPreferences.knlinkDeviceID.set(backup)
        }
        return backup
    }

    private static func hasStoredPrivateKey() -> Bool {
        do {
            return try loadPrivateKey() != nil
        } catch {
            configDebugLog("[app] private key check failed error=\(error)")
            return false
        }
    }

    /// 通用混合解密：RSA-OAEP(SHA-256) 解出 AES 密钥 → AES-256-GCM 解出明文字节。
    /// 凭据 blob 与「加密配置」(enc=1) 共用此逻辑。
    private static func openBlob(_ blob: EncryptedBlob) throws -> Data {
        guard let priv = try loadPrivateKey() else { throw ActivationError.missingPrivateKey }
        guard
            let encKey = Data(base64Encoded: blob.encryptedKey),
            let iv = Data(base64Encoded: blob.iv),
            let ct = Data(base64Encoded: blob.ciphertext)
        else { throw ActivationError.decrypt("base64") }
        var err: Unmanaged<CFError>?
        guard let rawKey = SecKeyCreateDecryptedData(priv, .rsaEncryptionOAEPSHA256, encKey as CFData, &err) as Data? else {
            throw ActivationError.decrypt((err?.takeRetainedValue() as Error?).map { "\($0)" } ?? "rsa")
        }
        guard ct.count > 16 else { throw ActivationError.decrypt("ciphertext too short") } // 尾部 16B tag
        let sealed = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: iv),
            ciphertext: ct.prefix(ct.count - 16),
            tag: ct.suffix(16)
        )
        return try AES.GCM.open(sealed, using: SymmetricKey(data: rawKey))
    }

    // MARK: 连接时即时拉取配置（JIT）

    private struct ConfigsResponse: Codable {
        let region: String?
        let clientIp: String?
        let clientCountry: String?
        let matchedConfigId: String?
        let groups: Groups
        struct Groups: Codable { let global: [Item]; let rule: [Item] }
        struct Item: Codable {
            let id: String
            let name: String?
            let cc: String?
            let region: String?
            let serverName: String?
            let url: String?
            let nodes: [NodeDTO]?
        }
        struct NodeDTO: Codable { let id: String; let name: String?; let cc: String?; let host: String?; let port: UInt16? }
    }

    private struct EncConfig: Codable {
        let format: String
        let encrypted: EncryptedBlob
    }

    public struct ConfigNode: Identifiable, Hashable {
        public let id: String
        public let name: String
        public let cc: String
        public let host: String?
        public let port: UInt16?
    }

    // 给客户端分组列表 UI 用的公开模型
    public struct ConfigItem: Identifiable, Hashable {
        public let id: String
        public let name: String
        public let cc: String
        public let region: String?
        public let serverName: String?
        public let url: String?
        public let nodes: [ConfigNode] // 全局模式：该份配置内的全部节点（手机端展开选）；规则模式为空
    }
    public struct ConfigGroups {
        public let rule: [ConfigItem]
        public let global: [ConfigItem]
        public let region: String?
        public let clientIp: String?
        public let clientCountry: String?
        public let matchedConfigId: String?
    }

    /// 拉取分组配置列表（用于客户端按「规则模式 / 全局模式」分组展示让用户选）。
    public static func fetchConfigList() async throws -> ConfigGroups {
        let serverBase = await serverBase()
        let token = try await KNLinkAuth.accessToken()
        var req = URLRequest(url: URL(string: "\(serverBase)/api/client/configs")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        logConfigRequest("config-list", request: req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        logConfigResponse("config-list", response: resp, data: data)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 {
            await KNLinkAuth.expireSession(reason: "config-list returned 401")
        }
        guard status == 200 else {
            throw ActivationError.badResponse(status, "configs")
        }
        let r = try JSONDecoder().decode(ConfigsResponse.self, from: data)
        let map = { (i: ConfigsResponse.Item) in
            ConfigItem(id: i.id, name: i.name ?? i.id, cc: i.cc ?? "xx", region: i.region, serverName: i.serverName,
                       url: i.url,
                       nodes: (i.nodes ?? []).map { ConfigNode(id: $0.id, name: $0.name ?? $0.id, cc: $0.cc ?? "xx", host: $0.host, port: $0.port) })
        }
        return ConfigGroups(
            rule: r.groups.rule.map(map),
            global: r.groups.global.map(map),
            region: r.region,
            clientIp: r.clientIp,
            clientCountry: r.clientCountry,
            matchedConfigId: r.matchedConfigId
        )
    }

    /// 拉取远程配置：当场解密 → 用 OAuth access token 拉取本机命中的 sing-box 配置 → 返回 config 内容字符串。
    /// 远程成功后只缓存服务端返回的 encrypted blob；解密后的明文只存在于本次调用内存中。
    public static func fetchConfigContentJIT() async throws -> String {
        let serverBase = await serverBase()
        let token = try await KNLinkAuth.accessToken() // Hydra access token（必要时自动刷新）
        let deviceID = await storedDeviceID()
        guard !deviceID.isEmpty else { throw ActivationError.decrypt("device not activated") }
        func get(_ label: String, _ urlString: String) async throws -> (Data, URLResponse) {
            var req = URLRequest(url: URL(string: urlString)!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            logConfigRequest(label, request: req)
            let (data, response) = try await URLSession.shared.data(for: req)
            logConfigResponse(label, response: response, data: data)
            return (data, response)
        }

        // 1) 取分组配置（服务端按当前来源 IP 重新判定 region，给出 matchedConfigId）
        let (listData, listResp) = try await get("jit-config-list", "\(serverBase)/api/client/configs")
        let listStatus = (listResp as? HTTPURLResponse)?.statusCode ?? -1
        if listStatus == 401 {
            await KNLinkAuth.expireSession(reason: "jit config-list returned 401")
        }
        guard listStatus == 200 else {
            throw ActivationError.badResponse(listStatus, "configs")
        }
        let configs = try JSONDecoder().decode(ConfigsResponse.self, from: listData)

        // 2) 只使用用户明确选中的配置；客户端不再按地区或列表顺序自行回退。
        let selected = await SharedPreferences.knlinkSelectedConfigID.get()
        let all = configs.groups.rule + configs.groups.global
        guard !selected.isEmpty else { throw ActivationError.decrypt("no config selected") }
        guard let target = all.first(where: { $0.id == selected }), let urlString = target.url else {
            throw ActivationError.decrypt("selected config not found")
        }
        logConfigSelection(selected: selected, matched: configs.matchedConfigId, target: target, deviceID: deviceID)

        // 3) 拉取该份配置并当场解密 → 明文 config 仅存在于内存；加密响应写入本机缓存。
        let (encryptedResponse, encConfig) = try await fetchEncryptedConfig(urlString: urlString, label: "jit-singbox-config")
        let content = try decryptConfig(encConfig)

        // 4) 全局模式：用户必须选具体节点，只把服务端下发的 selector「proxy」default 设为该节点。
        let isGlobal = configs.groups.global.contains { $0.id == target.id }
        let nodeTag = await SharedPreferences.knlinkSelectedNodeTag.get()
        let resolvedContent: String
        if isGlobal {
            guard !nodeTag.isEmpty else { throw ActivationError.decrypt("global node not selected") }
            resolvedContent = try applySelectedNode(content, nodeTag: nodeTag)
        } else {
            resolvedContent = content
        }

        await storeCachedConfig(
            configID: target.id,
            configURL: urlString,
            isGlobal: isGlobal,
            encryptedResponse: encryptedResponse
        )
        return resolvedContent
    }

    /// 读取本机缓存的服务端加密配置。缓存只在 selectedConfigID 匹配时生效；全局模式仍按当前节点选择设置 selector default。
    public static func fetchCachedConfigContentJIT() async throws -> String? {
        let selected = await SharedPreferences.knlinkSelectedConfigID.get()
        guard !selected.isEmpty else { return nil }
        let cachedID = await SharedPreferences.knlinkCachedConfigID.get()
        guard cachedID == selected else { return nil }
        let encryptedResponse = await SharedPreferences.knlinkCachedEncryptedConfig.get()
        guard !encryptedResponse.isEmpty else { return nil }
        let encConfig = try JSONDecoder().decode(EncConfig.self, from: Data(encryptedResponse.utf8))
        let content = try decryptConfig(encConfig)
        let isGlobal = await SharedPreferences.knlinkCachedConfigIsGlobal.get()
        if isGlobal {
            let nodeTag = await SharedPreferences.knlinkSelectedNodeTag.get()
            guard !nodeTag.isEmpty else { throw ActivationError.decrypt("global node not selected") }
            return try applySelectedNode(content, nodeTag: nodeTag)
        }
        return content
    }

    /// 读取服务端实际下发的 sing-box 配置，从 selector「proxy」里解析可选真实节点。
    public static func fetchSelectableConfigNodes(configURL: String?, metadataNodes: [ConfigNode]) async throws -> [ConfigNode] {
        guard let configURL, !configURL.isEmpty else { return [] }
        let content = try await fetchConfigContent(urlString: configURL, label: "selectable-global-config")
        let tags = selectableProxyTags(from: content)
        guard !tags.isEmpty else { return [] }
        let metadataByName = Dictionary(uniqueKeysWithValues: metadataNodes.map { ($0.name, $0) })
        return tags.map { tag in
            if let node = metadataByName[tag] {
                return node
            }
            return ConfigNode(id: tag, name: tag, cc: "xx", host: nil, port: nil)
        }
    }

    private static func fetchConfigContent(urlString: String, label: String) async throws -> String {
        let (_, encConfig) = try await fetchEncryptedConfig(urlString: urlString, label: label)
        return try decryptConfig(encConfig)
    }

    private static func fetchEncryptedConfig(urlString: String, label: String) async throws -> (String, EncConfig) {
        let token = try await KNLinkAuth.accessToken()
        let deviceID = await storedDeviceID()
        guard !deviceID.isEmpty else { throw ActivationError.decrypt("device not activated") }
        let separator = urlString.contains("?") ? "&" : "?"
        var req = URLRequest(url: URL(string: "\(urlString)\(separator)format=singbox&device=\(deviceID)")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        logConfigRequest(label, request: req)
        let (cfgData, cfgResp) = try await URLSession.shared.data(for: req)
        logConfigResponse(label, response: cfgResp, data: cfgData)
        let cfgStatus = (cfgResp as? HTTPURLResponse)?.statusCode ?? -1
        if cfgStatus == 401 {
            await KNLinkAuth.expireSession(reason: "\(label) returned 401")
        }
        guard cfgStatus == 200 else {
            throw ActivationError.badResponse(cfgStatus, "config")
        }
        let responseBody = String(data: cfgData, encoding: .utf8) ?? ""
        let enc = try JSONDecoder().decode(EncConfig.self, from: cfgData)
        return (responseBody, enc)
    }

    private static func decryptConfig(_ enc: EncConfig) throws -> String {
        let plain = try openBlob(enc.encrypted)
        guard let content = String(data: plain, encoding: .utf8) else { throw ActivationError.decrypt("config utf8") }
        return content
    }

    private static func storeCachedConfig(configID: String, configURL: String, isGlobal: Bool, encryptedResponse: String) async {
        guard !configID.isEmpty, !encryptedResponse.isEmpty else { return }
        await SharedPreferences.knlinkCachedConfigID.set(configID)
        await SharedPreferences.knlinkCachedConfigURL.set(configURL)
        await SharedPreferences.knlinkCachedConfigIsGlobal.set(isGlobal)
        await SharedPreferences.knlinkCachedEncryptedConfig.set(encryptedResponse)
        await SharedPreferences.knlinkCachedConfigUpdatedAt.set(Date().timeIntervalSince1970)
        configDebugLog("[cache] stored encrypted config configID=\(configID) isGlobal=\(isGlobal) bytes=\(encryptedResponse.utf8.count)")
    }

    private static func selectableProxyTags(from content: String) -> [String] {
        guard
            let obj = (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any],
            let outbounds = obj["outbounds"] as? [[String: Any]]
        else { return [] }
        var typeByTag: [String: String] = [:]
        for outbound in outbounds {
            guard let tag = outbound["tag"] as? String, let type = outbound["type"] as? String else { continue }
            typeByTag[tag] = type
        }
        guard
            let selector = outbounds.first(where: { ($0["type"] as? String) == "selector" && ($0["tag"] as? String) == "proxy" }),
            let members = selector["outbounds"] as? [String]
        else { return [] }
        return members.filter { tag in
            guard let type = typeByTag[tag] else { return false }
            return !["selector", "urltest", "direct", "block"].contains(type)
        }
    }

    /// 把 sing-box 配置里 selector「proxy」的 default 改成指定节点 tag（节点须在该 selector 成员内）。
    private static func applySelectedNode(_ content: String, nodeTag: String) throws -> String {
        guard
            var obj = (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any],
            var outbounds = obj["outbounds"] as? [[String: Any]]
        else { throw ActivationError.decrypt("config json") }
        var changed = false
        var selectorFound = false
        for i in outbounds.indices where (outbounds[i]["type"] as? String) == "selector" && (outbounds[i]["tag"] as? String) == "proxy" {
            selectorFound = true
            let members = outbounds[i]["outbounds"] as? [String] ?? []
            if members.contains(nodeTag) { outbounds[i]["default"] = nodeTag; changed = true }
        }
        guard selectorFound else { throw ActivationError.decrypt("proxy selector not found") }
        guard changed else { throw ActivationError.decrypt("selected node not found: \(nodeTag)") }
        obj["outbounds"] = outbounds
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else {
            throw ActivationError.decrypt("config json encode")
        }
        return s
    }

    private static func logConfigRequest(_ label: String, request: URLRequest) {
        #if DEBUG
            let headers = sanitizedHeaders(request.allHTTPHeaderFields ?? [:])
            configDebugLog("[request][\(label)] url=\(request.url?.absoluteString ?? "<nil>") headers=\(headers)")
        #endif
    }

    private static func logConfigResponse(_ label: String, response: URLResponse, data: Data) {
        #if DEBUG
            let http = response as? HTTPURLResponse
            let body = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes non-utf8>"
            configDebugLog("[response][\(label)] status=\(http?.statusCode ?? -1) url=\(response.url?.absoluteString ?? "<nil>") headers=\(http?.allHeaderFields ?? [:]) body=\(limitedLogBody(body))")
        #endif
    }

    private static func logConfigSelection(selected: String, matched: String?, target: ConfigsResponse.Item, deviceID: String) {
        #if DEBUG
            configDebugLog("[selection] selected=\(selected.isEmpty ? "<empty>" : selected) matched=\(matched ?? "<nil>") targetID=\(target.id) targetName=\(target.name ?? "<nil>") targetURL=\(target.url ?? "<nil>") device=\(deviceID)")
        #endif
    }

    public static func configDebugLog(_ message: String) {
        #if DEBUG
            let line = "[KNLink][config] \(ISO8601DateFormatter().string(from: Date())) process=\(ProcessInfo.processInfo.processName) \(message)"
            NSLog("%@", line)
            guard let sharedDirectory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupID) else {
                return
            }
            do {
                try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
                let logURL = sharedDirectory.appendingPathComponent("knlink-config-debug.log")
                let data = Data((line + "\n").utf8)
                if FileManager.default.fileExists(atPath: logURL.path) {
                    let handle = try FileHandle(forWritingTo: logURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: logURL, options: .atomic)
                }
            } catch {
                NSLog("[KNLink][config] failed to write debug log: %@", "\(error)")
            }
        #endif
    }

    private static func sanitizedHeaders(_ headers: [String: String]) -> [String: String] {
        var result = headers
        for key in result.keys {
            if key.caseInsensitiveCompare("Authorization") == .orderedSame, let value = result[key] {
                result[key] = redactAuthorization(value)
            }
        }
        return result
    }

    private static func redactAuthorization(_ value: String) -> String {
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "<redacted>" }
        let token = parts[1]
        let suffix = token.suffix(8)
        return "\(parts[0]) <redacted>...\(suffix)"
    }

    private static func limitedLogBody(_ body: String) -> String {
        let limit = 20_000
        guard body.count > limit else { return body }
        return "\(body.prefix(limit))...<truncated \(body.count - limit) chars>"
    }

    /// 仅用于调试/重新创建设备身份：删除设备私钥。普通退出登录不能调用。
    public static func reset() {
        for group in keyGroups {
            var query: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: privateKeyTag,
            ]
            if let group { query[kSecAttrAccessGroup as String] = group }
            SecItemDelete(query as CFDictionary)
        }
    }

    // MARK: Keychain 私钥（RSA-2048，不可导出）

    // 有共享组权限就用共享组（扩展可读私钥）；缺权限则退回默认组。两种都试。
    private static var keyGroups: [String?] { keychainAccessGroup == nil ? [nil] : [keychainAccessGroup, nil] }

    private static func loadPrivateKey() throws -> SecKey? {
        for group in keyGroups {
            if let key = loadPrivateKey(group: group) { return key }
        }
        return nil
    }

    // 从「指定组」读私钥（nil=默认组）。用于确认 key 是否真的在共享组里（扩展可读的前提）。
    private static func loadPrivateKey(group: String?) -> SecKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: privateKeyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecReturnRef as String: true,
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess ? (item as! SecKey) : nil
    }

    /// 返回已有公钥；私钥须落在 entitlement 的（共享）keychain 组里，扩展才能读。导出公钥为 SPKI base64。
    private static func ensurePublicKeySPKIBase64() throws -> String {
        var priv: SecKey
        if let existing = loadPrivateKey(group: nil) { // 省略组 → 在 entitlement 内所有组里找（含共享组）
            priv = existing
        } else {
            reset() // 清掉可能落在错误组的旧 key
            // 不指定 accessGroup → 系统把 key 放进 entitlement 的第一个 keychain-access-group（即共享组），
            // App 与扩展的该组一致，故扩展能读。避免"代码组字符串 vs entitlement 值"对不上的坑。
            let privAttrs: [String: Any] = [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: privateKeyTag,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let attrs: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits as String: 2048,
                kSecPrivateKeyAttrs as String: privAttrs,
            ]
            var error: Unmanaged<CFError>?
            guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
                let reason = (error?.takeRetainedValue() as Error?).map { "\($0)" } ?? "unknown"
                throw ActivationError.notPersisted("私钥写入 Keychain 失败：\(reason)。请确认 App 与扩展都加了同一个 keychain-access-groups")
            }
            priv = key
        }
        guard let pub = SecKeyCopyPublicKey(priv) else { throw ActivationError.decrypt("public key") }
        var error: Unmanaged<CFError>?
        // SecKey 导出的 RSA 公钥是 PKCS#1（RSAPublicKey），需再包成 SPKI 供 WebCrypto importKey('spki') 使用
        guard let pkcs1 = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
            throw error!.takeRetainedValue() as Error
        }
        return spkiFromPKCS1(pkcs1).base64EncodedString()
    }

    // MARK: DER —— PKCS#1 公钥包装成 SPKI（SubjectPublicKeyInfo）

    private static func derLength(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var v = n, bytes = [UInt8]()
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    private static func derTLV(_ tag: UInt8, _ value: [UInt8]) -> [UInt8] {
        [tag] + derLength(value.count) + value
    }

    private static func spkiFromPKCS1(_ pkcs1: Data) -> Data {
        // AlgorithmIdentifier { OID rsaEncryption(1.2.840.113549.1.1.1), NULL }
        let oid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
        let algId = derTLV(0x30, derTLV(0x06, oid) + derTLV(0x05, []))
        let bitString = derTLV(0x03, [0x00] + [UInt8](pkcs1)) // BIT STRING，前导 0 unused bits
        return Data(derTLV(0x30, algId + bitString))
    }
}
