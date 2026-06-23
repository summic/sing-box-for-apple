import Foundation
import Libbox
import NetworkExtension
import os.log
#if os(iOS)
    import WidgetKit
#endif
#if os(macOS)
    import CoreLocation
#endif

open class ExtensionProvider: NEPacketTunnelProvider {
    private static let logger = Logger(category: "ExtensionProvider")

    public private(set) var commandServer: LibboxCommandServer?
    private lazy var platformInterface = ExtensionPlatformInterface(self)
    public var tunnelOptions: [String: NSObject]?
    private var startOptionsURL: URL?

    public struct OverridePreferences {
        public var includeAllNetworks: Bool = false
        public var systemProxyEnabled: Bool = true
        public var excludeDefaultRoute: Bool = false
        public var autoRouteUseSubRangesByDefault: Bool = false
        public var excludeAPNsRoute: Bool = false
    }

    public var overridePreferences: OverridePreferences?

    private func applyStartOptions(_ options: [String: NSObject]) {
        tunnelOptions = options
        overridePreferences = OverridePreferences(
            includeAllNetworks: (options["includeAllNetworks"] as? NSNumber)?.boolValue ?? false,
            systemProxyEnabled: (options["systemProxyEnabled"] as? NSNumber)?.boolValue ?? true,
            excludeDefaultRoute: (options["excludeDefaultRoute"] as? NSNumber)?.boolValue ?? false,
            autoRouteUseSubRangesByDefault: (options["autoRouteUseSubRangesByDefault"] as? NSNumber)?.boolValue ?? false,
            excludeAPNsRoute: (options["excludeAPNsRoute"] as? NSNumber)?.boolValue ?? false
        )
    }

    private func persistStartOptions(_ options: [String: NSObject]) throws {
        guard let startOptionsURL else {
            return
        }
        let data = try ExtensionStartOptions.encode(options)
        try data.write(to: startOptionsURL, options: .atomic)
    }

    private func loadPersistedStartOptions() throws -> [String: NSObject]? {
        guard let startOptionsURL, FileManager.default.fileExists(atPath: startOptionsURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: startOptionsURL)
        return try ExtensionStartOptions.decode(data)
    }

    private func resolveStartOptions(_ startOptions: [String: NSObject]?) throws -> [String: NSObject] {
        if let startOptions, startOptions["configContent"] as? String != nil {
            return startOptions
        }
        let persistedOptions: [String: NSObject]?
        do {
            persistedOptions = try loadPersistedStartOptions()
        } catch {
            throw ExtensionStartupError("(packet-tunnel) error: load start options: \(error.localizedDescription)")
        }
        if let persistedOptions {
            if let startOptions {
                return persistedOptions.merging(startOptions) { _, new in new }
            }
            return persistedOptions
        }
        throw ExtensionStartupError("(packet-tunnel) error: missing start options")
    }

    #if os(macOS)
        private var xpcListener: NSXPCListener!
        private var xpcService: CommandXPCService!
        private var locationManager: CLLocationManager?
        private var locationDelegate: stubLocationDelegate?
    #endif

    override public init() {
        LibboxPrepareCrashSignalHandlers()
        #if os(macOS)
            if Variant.useSystemExtension {
                NativeCrashReporter.installForCurrentProcess(
                    basePath: FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("NativeCrash")
                )
            } else {
                NativeCrashReporter.installForCurrentProcess()
            }
        #else
            NativeCrashReporter.installForCurrentProcess()
        #endif
        LibboxReinstallCrashSignalHandlers()
        super.init()
    }

    override open func startTunnel(options startOptions: [String: NSObject]?) async throws {
        KNLink.configDebugLog("[extension] startTunnel entered hasStartOptions=\(startOptions != nil)")
        let basePath: String
        let workingPath: String
        let tempPath: String

        #if os(macOS)
            if Variant.useSystemExtension {
                let containerURL = FileManager.default.homeDirectoryForCurrentUser
                basePath = containerURL.path
                workingPath = containerURL.appendingPathComponent("Working").path
                tempPath = containerURL.appendingPathComponent("Temp").path
            } else {
                basePath = FilePath.sharedDirectory.relativePath
                workingPath = FilePath.workingDirectory.relativePath
                tempPath = FilePath.cacheDirectory.relativePath
            }
        #else
            basePath = FilePath.sharedDirectory.relativePath
            workingPath = FilePath.workingDirectory.relativePath
            tempPath = FilePath.cacheDirectory.relativePath
        #endif

        startOptionsURL = URL(fileURLWithPath: basePath).appendingPathComponent(ExtensionStartOptions.snapshotFileName)

        #if os(macOS)
            if Variant.useSystemExtension {
                let socketPath = basePath + "/command.sock"
                let machServiceName = AppConfiguration.appGroupID + ".system"
                xpcService = CommandXPCService(socketPath: socketPath)
                xpcListener = NSXPCListener(machServiceName: machServiceName)
                xpcListener.delegate = xpcService
            }
        #endif

        let effectiveOptions = try resolveStartOptions(startOptions)
        KNLink.configDebugLog("[extension] startTunnel resolvedOptions keys=\(Array(effectiveOptions.keys).sorted()) hasConfigContent=\(effectiveOptions["configContent"] != nil)")
        if effectiveOptions["configContent"] == nil {
            KNLink.configDebugLog("[extension] startTunnel missing configContent before service setup")
            throw ExtensionStartupError("(packet-tunnel) error: missing configContent in tunnel options")
        }
        do {
            try persistStartOptions(effectiveOptions)
        } catch {
            throw ExtensionStartupError("(packet-tunnel) error: persist start options: \(error.localizedDescription)")
        }

        applyStartOptions(effectiveOptions)

        let options = LibboxSetupOptions()
        options.basePath = basePath
        options.workingPath = workingPath
        options.tempPath = tempPath

        options.logMaxLines = 3000
        options.debug = Variant.inDebug
        options.crashReportSource = "NetworkExtension"

        #if os(tvOS)
            if let port = effectiveOptions["commandServerPort"] as? NSNumber {
                options.commandServerListenPort = port.int32Value
            }
            if let secret = effectiveOptions["commandServerSecret"] as? String {
                options.commandServerSecret = secret
            }
        #endif

        #if os(macOS)
            options.oomKillerEnabled = (effectiveOptions["oomKillerEnabled"] as? NSNumber)?.boolValue ?? false
            let oomMemoryLimitMB = (effectiveOptions["oomMemoryLimitMB"] as? NSNumber)?.int64Value ?? 0
            options.oomMemoryLimit = oomMemoryLimitMB * 1024 * 1024
            options.oomKillerDisabled = !((effectiveOptions["oomKillerKillConnections"] as? NSNumber)?.boolValue ?? false)
        #else
            options.oomKillerEnabled = true
        #endif

        var setupError: NSError?
        LibboxSetup(options, &setupError)
        if let setupError {
            throw ExtensionStartupError("(packet-tunnel) error: setup service: \(setupError.localizedDescription)")
        }
        LibboxPromoteOOMDraft()

        var error: NSError?
        commandServer = LibboxNewCommandServer(platformInterface, platformInterface, &error)
        if let error {
            throw ExtensionStartupError("(packet-tunnel): create command server error: \(error.localizedDescription)")
        }
        do {
            try commandServer!.start()
        } catch {
            throw ExtensionStartupError("(packet-tunnel): start command server error: \(error.localizedDescription)")
        }

        #if os(macOS)
            if Variant.useSystemExtension {
                xpcListener.resume()
                Self.logger.info("set Command Server")
                xpcService.commandServer = commandServer
            }
        #endif

        do {
            try await startService()
        } catch {
            #if os(macOS)
                if Variant.useSystemExtension {
                    xpcService.markServiceNotReady(error)
                }
            #endif
            throw error
        }
        writeMessage("(packet-tunnel): Here I stand")
        #if os(macOS)
            if Variant.useSystemExtension {
                xpcService.markServiceReady()
            }
        #endif
        #if os(iOS)
            if #available(iOS 18.0, *) {
                ControlCenter.shared.reloadControls(ofKind: ExtensionProfile.controlKind)
            }
        #endif
    }

    func writeMessage(_ message: String) {
        if let commandServer {
            commandServer.writeMessage(2, message: message)
        }
    }

    private func startService() async throws {
        // configContent 来源：
        //  • KNLink 模式：优先用本机缓存的服务端加密配置启动；远程配置后台静默同步。
        //  • 否则：沿用从 tunnelOptions 传入的 configContent。
        var configContent: String
        let knlinkMode = await SharedPreferences.knlinkMode.get()
        let primaryDeviceID = await SharedPreferences.knlinkDeviceID.get()
        let backupDeviceID = await SharedPreferences.knlinkDeviceIDBackup.get()
        let knlinkDeviceID = primaryDeviceID.isEmpty ? backupDeviceID : primaryDeviceID
        let useKNLink = knlinkMode || !knlinkDeviceID.isEmpty // 设备已激活即走 JIT，兜底 flag 未置上
        var startedFromKNLinkCache = false
        KNLink.configDebugLog("[extension] startService knlinkMode=\(knlinkMode) deviceID=\(knlinkDeviceID.isEmpty ? "<empty>" : knlinkDeviceID) useKNLink=\(useKNLink)")
        if useKNLink {
            let cachedContent: String?
            do {
                cachedContent = try await KNLink.fetchCachedConfigContentJIT()
            } catch {
                cachedContent = nil
                KNLink.configDebugLog("[extension] startService cached config unavailable error=\(error)")
            }
            if let cachedContent {
                configContent = cachedContent
                startedFromKNLinkCache = true
                KNLink.configDebugLog("[extension] startService KNLink mode using cached config bytes=\(configContent.utf8.count)")
            } else {
                KNLink.configDebugLog("[extension] startService KNLink cache unavailable; fetching remote config")
                do {
                    configContent = try await KNLink.fetchConfigContentJIT()
                    KNLink.configDebugLog("[extension] startService fetched remote config bytes=\(configContent.utf8.count)")
                } catch {
                    KNLink.configDebugLog("[extension] startService failed to fetch remote config error=\(error)")
                    throw ExtensionStartupError("(packet-tunnel) error: KNLink fetch config: \(error.localizedDescription)")
                }
            }
        } else if let content = tunnelOptions?["configContent"] as? String {
            KNLink.configDebugLog("[extension] startService KNLink mode disabled; using tunnel option config bytes=\(content.utf8.count)")
            configContent = content
        } else {
            KNLink.configDebugLog("[extension] startService missing configContent in tunnel options")
            throw ExtensionStartupError("(packet-tunnel) error: missing configContent in tunnel options")
        }

        let options = LibboxOverrideOptions()
        do {
            try commandServer!.startOrReloadService(configContent, options: options)
        } catch {
            guard useKNLink, startedFromKNLinkCache else {
                throw ExtensionStartupError("(packet-tunnel) error: start service: \(error.localizedDescription)")
            }
            KNLink.configDebugLog("[extension] startService cached config failed; fetching remote config and retrying error=\(error)")
            do {
                configContent = try await KNLink.fetchConfigContentJIT()
                try commandServer!.startOrReloadService(configContent, options: options)
                startedFromKNLinkCache = false
                KNLink.configDebugLog("[extension] startService remote retry succeeded bytes=\(configContent.utf8.count)")
            } catch {
                KNLink.configDebugLog("[extension] startService remote retry failed error=\(error)")
                throw ExtensionStartupError("(packet-tunnel) error: start service: \(error.localizedDescription)")
            }
        }
        if useKNLink, startedFromKNLinkCache {
            refreshKNLinkConfigInBackground(currentContent: configContent)
        }
        #if os(macOS)
            if !Variant.useSystemExtension, commandServer!.needWIFIState() {
                locationManager = CLLocationManager()
                locationDelegate = stubLocationDelegate()
                locationManager!.delegate = locationDelegate
                locationManager!.requestLocation()
            }
        #endif
    }

    private func refreshKNLinkConfigInBackground(currentContent: String) {
        KNLink.configDebugLog("[extension] startService scheduling silent remote config sync")
        Task { [weak self] in
            do {
                let freshContent = try await KNLink.fetchConfigContentJIT()
                guard let self, let commandServer = self.commandServer else { return }
                if freshContent == currentContent {
                    KNLink.configDebugLog("[extension] silent remote config sync no change")
                    return
                }
                let options = LibboxOverrideOptions()
                try commandServer.startOrReloadService(freshContent, options: options)
                KNLink.configDebugLog("[extension] silent remote config sync reloaded service bytes=\(freshContent.utf8.count)")
            } catch {
                KNLink.configDebugLog("[extension] silent remote config sync failed; keep cached config error=\(error)")
            }
        }
    }

    #if os(macOS)

        class stubLocationDelegate: NSObject, CLLocationManagerDelegate {
            func locationManagerDidChangeAuthorization(_: CLLocationManager) {}

            func locationManager(_: CLLocationManager, didUpdateLocations _: [CLLocation]) {}

            func locationManager(_: CLLocationManager, didFailWithError _: Error) {}
        }

    #endif

    func stopService() {
        do {
            try commandServer?.closeService()
        } catch {
            writeMessage("(packet-tunnel) stop service: \(error.localizedDescription)")
        }
        platformInterface.reset()
    }

    func reloadService() async throws {
        writeMessage("(packet-tunnel) reloading service")
        reasserting = true
        defer {
            reasserting = false
        }
        try await startService()
    }

    override open func stopTunnel(with reason: NEProviderStopReason) async {
        writeMessage("(packet-tunnel) stopping, reason: \(reason)")
        stopService()
        if let server = commandServer {
            try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
            server.close()
            commandServer = nil
        }
        #if os(macOS)
            if Variant.useSystemExtension {
                xpcService.markServiceNotReady(NSError(domain: "CommandXPC", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Command server stopped",
                ]))
                xpcListener.invalidate()
                xpcListener = nil
                xpcService.commandServer = nil
                xpcService = nil
                UserServiceEndpointRegistry.shared.clear()
            }
            locationManager = nil
            locationDelegate = nil
        #endif
        #if os(iOS)
            if #available(iOS 18.0, *) {
                ControlCenter.shared.reloadControls(ofKind: ExtensionProfile.controlKind)
            }
        #endif
    }

    override open func handleAppMessage(_ messageData: Data) async -> Data? {
        do {
            let options = try ExtensionStartOptions.decode(messageData)
            applyStartOptions(options)
            try persistStartOptions(options)
            try await reloadService()
            return nil
        } catch {
            return error.localizedDescription.data(using: .utf8)
        }
    }

    override open func sleep() async {
        if let commandServer {
            commandServer.pause()
        }
    }

    override open func wake() {
        if let commandServer {
            commandServer.wake()
        }
    }
}
