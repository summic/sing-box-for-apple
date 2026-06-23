import Foundation
import Libbox
import Library
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif
import SwiftUI

// KN Link 仪表盘用到的系统背景色，跨平台（iOS UIKit / macOS AppKit）
private extension Color {
    static var knAppBackground: Color {
        #if os(macOS)
            return Color(nsColor: .windowBackgroundColor)
        #else
            return Color(uiColor: .systemBackground)
        #endif
    }

    static var knCardBackground: Color {
        #if os(macOS)
            return Color(nsColor: .controlBackgroundColor)
        #else
            return Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }
}

@MainActor
public struct OverviewView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @EnvironmentObject private var profile: ExtensionProfile
    @StateObject private var coordinator = OverviewViewModel()
    @ObservedObject private var configuration: DashboardCardConfiguration

    @Binding private var profileList: [ProfilePreview]
    @Binding private var selectedProfileID: Int64
    @Binding private var systemProxyAvailable: Bool
    @Binding private var systemProxyEnabled: Bool

    public init(
        _ profileList: Binding<[ProfilePreview]>,
        _ selectedProfileID: Binding<Int64>,
        _ systemProxyAvailable: Binding<Bool>,
        _ systemProxyEnabled: Binding<Bool>,
        cardConfiguration: DashboardCardConfiguration
    ) {
        _profileList = profileList
        _selectedProfileID = selectedProfileID
        _systemProxyAvailable = systemProxyAvailable
        _systemProxyEnabled = systemProxyEnabled
        _configuration = ObservedObject(wrappedValue: cardConfiguration)
    }

    public var body: some View {
        Group {
            if configuration.isLoading {
                ProgressView()
            } else {
                #if os(tvOS)
                    ScrollView {
                        cardGrid
                            .padding()
                    }
                #else
                    MobileOverviewHome(
                        coordinator: coordinator,
                        commandClient: environments.commandClient,
                        profileList: $profileList,
                        selectedProfileID: $selectedProfileID
                    )
                #endif
            }
        }
        .alert($coordinator.alert)
        .disabled(!Variant.screenshotMode && (!profile.status.isSwitchable || coordinator.reasserting))
    }

    @ViewBuilder
    private var cardGrid: some View {
        let visibleCards = configuration.orderedEnabledCards.filter(shouldShowCard)
        let groupedCards = groupCards(visibleCards)

        VStack(spacing: 16) {
            ForEach(Array(groupedCards.enumerated()), id: \.offset) { _, group in
                if group.count == 2 {
                    HStack(spacing: 16) {
                        cardView(for: group[0])
                            .frame(maxWidth: .infinity)
                        cardView(for: group[1])
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    cardView(for: group[0])
                }
            }
        }
    }

    private func groupCards(_ cards: [DashboardCard]) -> [[DashboardCard]] {
        var result: [[DashboardCard]] = []
        var index = 0

        while index < cards.count {
            let card = cards[index]
            if card.isHalfWidth, index + 1 < cards.count, cards[index + 1].isHalfWidth {
                result.append([card, cards[index + 1]])
                index += 2
            } else {
                result.append([card])
                index += 1
            }
        }
        return result
    }

    private func shouldShowCard(_ card: DashboardCard) -> Bool {
        switch card {
        case .status, .connections, .uploadTraffic, .downloadTraffic, .clashMode:
            return Variant.screenshotMode || profile.status.isConnected
        case .httpProxy:
            return (Variant.screenshotMode || profile.status.isConnectedStrict) && systemProxyAvailable
        case .profile:
            return true
        }
    }

    @ViewBuilder
    private func cardView(for card: DashboardCard) -> some View {
        switch card {
        case .status:
            StatusCard()
                .environmentObject(environments.commandClient)
        case .connections:
            ConnectionsCard()
                .environmentObject(environments.commandClient)
        case .uploadTraffic:
            UploadTrafficCard()
                .environmentObject(environments.commandClient)
        case .downloadTraffic:
            DownloadTrafficCard()
                .environmentObject(environments.commandClient)
        case .httpProxy:
            HTTPProxyCard(
                systemProxyAvailable: $systemProxyAvailable,
                systemProxyEnabled: $systemProxyEnabled
            ) { enabled in
                await coordinator.setSystemProxyEnabled(enabled, profile: profile)
            }
        case .clashMode:
            ClashModeCard()
                .environmentObject(environments.commandClient)
        case .profile:
            ProfileCard(
                profileList: $profileList,
                selectedProfileID: Binding(
                    get: { selectedProfileID },
                    set: { newID in
                        coordinator.reasserting = true
                        Task {
                            await coordinator.switchProfile(newID, profile: profile, environments: environments)
                        }
                    }
                )
            )
        }
    }
}

#if !os(tvOS)
    private struct MobileOverviewHome: View {
        @EnvironmentObject private var environments: ExtensionEnvironments
        @EnvironmentObject private var profile: ExtensionProfile
        @ObservedObject var coordinator: OverviewViewModel
        @ObservedObject var commandClient: CommandClient

        @Binding var profileList: [ProfilePreview]
        @Binding var selectedProfileID: Int64
        @State private var currentTime = Date()
        @State private var showProfileSelector = false
        @State private var servers: [ServerOption] = []        // 只放 API 返回的配置，不再用假数据
        @State private var selectedServerID = ""
        @State private var cachedSelectedServer: ServerOption?
        @State private var measuredDelays: [String: String] = [:]
        @State private var matchedRuleName: String?
        @State private var detectedClientIp: String?
        @State private var detectedRegion: String?
        @State private var detectedClientCountry: String?
        @State private var globalConfigID = "" // 合并后的单份全局配置 id（全局节点都归它）

        private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

        private var selectedServer: ServerOption {
            if !selectedServerID.isEmpty, let server = servers.first(where: { $0.id == selectedServerID }) {
                return server
            }
            if let cachedSelectedServer {
                return cachedSelectedServer
            }
            return ServerOption.placeholder
        }

        var body: some View {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 28) {
                    header
                    connectionSummary
                    powerOrb

                    Spacer()
                        .frame(height: 28)

                    serverCard
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 30)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background(Color.knAppBackground.ignoresSafeArea())
            .sheet(isPresented: $showProfileSelector) {
                ProfileSelectionSheet(
                    servers: servers,
                    commandClient: commandClient,
                    initialMode: selectedServer.mode,
                    matchedRuleName: matchedRuleName,
                    detectedClientIp: detectedClientIp,
                    detectedRegion: detectedRegion,
                    detectedClientCountry: detectedClientCountry,
                    selectedServerID: $selectedServerID,
                    measuredDelays: $measuredDelays
                ) { server in
                    await selectRemoteServer(server)
                }
            }
            .task {
                await loadCachedSelectedServer()
                await loadRemoteServers()
                if profile.status.isConnectedStrict {
                    commandClient.connect()
                }
            }
            .onReceive(timer) { _ in
                guard !Variant.screenshotMode else { return }
                currentTime = Date()
            }
            .onChangeCompat(of: profile.status) { status in
                if status.isConnectedStrict {
                    commandClient.connect()
                }
                if coordinator.isStarting {
                    if status == .disconnected {
                        coordinator.isStarting = false
                        if #available(iOS 16.0, *) {
                            Task { await coordinator.checkStartupError(profile: profile) }
                        }
                    } else if status.isConnectedStrict {
                        coordinator.isStarting = false
                        environments.commandClient.connect()
                    }
                }
            }
        }

        private var header: some View {
            Text("KN Link")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
            .foregroundStyle(.primary)
        }

        private var connectionSummary: some View {
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                    Text("已连接")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(Color(red: 0.12, green: 0.62, blue: 0.34))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(red: 0.12, green: 0.62, blue: 0.34).opacity(0.12), in: Capsule())
                .opacity(profile.status.isConnectedStrict ? 1 : 0)
                .frame(height: 38)

                ZStack {
                    if profile.status.isConnectedStrict {
                        Text(runtimeDuration)
                            .font(.system(size: 52, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .transition(.asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .move(edge: .top).combined(with: .opacity)
                            ))
                    }
                }
                .frame(height: 62)
                .clipped()
                .animation(.spring(response: 0.35, dampingFraction: 0.82), value: profile.status.isConnectedStrict)
            }
        }

        private var powerOrb: some View {
            ZStack {
                DecorativeRings(
                    color: powerRingColor,
                    showsPlanets: coordinator.isStarting && !profile.status.isConnectedStrict
                )
                    .frame(width: 250, height: 250)

                if profile.status.isConnectedStrict {
                    PowerAuroraGlow()
                        .frame(width: 190, height: 190)
                        .transition(.opacity)
                }

                Button {
                    KNLink.configDebugLog("[home] power button tapped currentStatus=\(profile.status.rawValue) willEnable=\(!profile.status.isConnected)")
                    Task {
                        await coordinator.setServiceEnabled(!profile.status.isConnected, profile: profile)
                    }
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 108, height: 108)
                        .background(
                            powerButtonGradient,
                            in: Circle()
                        )
                        .shadow(color: powerRingColor.opacity(profile.status.isConnectedStrict ? 0.28 : 0.18), radius: 24, y: 12)
                }
                .buttonStyle(.plain)
                .disabled(!profile.status.isEnabled || coordinator.reasserting)
            }
            .frame(height: 260)
        }

        private var serverCard: some View {
            VStack(spacing: shouldShowTrafficStats ? 18 : 0) {
                serverCell

                if shouldShowTrafficStats {
                    Divider()

                    HStack(spacing: 0) {
                        TrafficMetric(
                            title: "Download",
                            value: downlinkText
                        )
                        .padding(.leading, 10)
                        .padding(.trailing, 24)
                        .frame(maxWidth: .infinity)

                        Divider()
                            .frame(height: 42)

                        TrafficMetric(
                            title: "Upload",
                            value: uplinkText
                        )
                        .padding(.leading, 30)
                        .padding(.trailing, 4)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(18)
            .background(Color.knCardBackground, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.06), radius: 24, y: 12)
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: shouldShowTrafficStats)
        }

        private var serverCell: some View {
            Button {
                showProfileSelector = true
            } label: {
                HStack(spacing: 14) {
                    FlagImage(regionCode: selectedServer.regionCode)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(selectedServer.mode.displayName)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(currentNodeName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(coordinator.reasserting)
        }

        private var shouldShowTrafficStats: Bool {
            profile.status.isConnectedStrict
        }

        private var runtimeDuration: String {
            guard profile.status.isConnectedStrict, let connectedDate = profile.connectedDate else {
                return "00:00:00"
            }
            let interval: TimeInterval
            if Variant.screenshotMode {
                interval = 252
            } else {
                interval = max(0, currentTime.timeIntervalSince(connectedDate))
            }
            let hours = Int(interval) / 3600
            let minutes = Int(interval) / 60 % 60
            let seconds = Int(interval) % 60
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }

        private var currentNodeName: String {
            selectedServer.name
        }

        private var downlinkText: String {
            if Variant.screenshotMode {
                return "249 MB/s"
            }
            guard let message = commandClient.status, message.trafficAvailable else {
                return "..."
            }
            return "\(LibboxFormatBytes(message.downlink))/s"
        }

        private var uplinkText: String {
            if Variant.screenshotMode {
                return "38 B/s"
            }
            guard let message = commandClient.status, message.trafficAvailable else {
                return "..."
            }
            return "\(LibboxFormatBytes(message.uplink))/s"
        }

        private var homeBlue: Color {
            Color(red: 0.08, green: 0.39, blue: 0.88)
        }

        private var latencyGreen: Color {
            Color(red: 0.12, green: 0.62, blue: 0.34)
        }

        private var powerRingColor: Color {
            profile.status.isConnectedStrict ? Color(red: 0.34, green: 0.78, blue: 0.54) : homeBlue
        }

        private var powerButtonGradient: LinearGradient {
            if profile.status.isConnectedStrict {
                return LinearGradient(
                    colors: [Color(red: 0.20, green: 0.72, blue: 0.42), Color(red: 0.10, green: 0.52, blue: 0.29)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            return LinearGradient(
                colors: [Color(red: 0.08, green: 0.14, blue: 0.25), Color(red: 0.03, green: 0.07, blue: 0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        private func loadRemoteServers() async {
            do {
                // 唯一数据源：服务端 /api/client/configs 的 groups（带 Hydra access token 鉴权）
                let groups = try await KNLink.fetchConfigList()
                // 规则模式：每份配置一项
                var list: [ServerOption] = groups.rule.map {
                    ServerOption(id: $0.id, name: $0.name, delay: "", mode: .rule,
                                 outboundTags: $0.nodes.map(\.name), regionCode: $0.cc, isMatched: $0.id == groups.matchedConfigId)
                }
                // 全局模式：从服务端下发的 sing-box 配置 selector「proxy」里展开真实节点。
                if let g = groups.global.first {
                    globalConfigID = g.id
                    do {
                        let nodes = try await KNLink.fetchSelectableConfigNodes(configURL: g.url, metadataNodes: g.nodes)
                        list += nodes.map {
                            ServerOption(id: $0.id, name: $0.name, delay: "", mode: .global,
                                         outboundTags: [$0.name], regionCode: $0.cc)
                        }
                    } catch {
                        NSLog("KNLink fetch global config nodes failed: \(error)")
                    }
                }
                servers = list // 失败不回退假数据；空就是空
                matchedRuleName = groups.rule.first { $0.id == groups.matchedConfigId }?.name
                detectedClientIp = groups.clientIp
                detectedRegion = groups.region
                detectedClientCountry = groups.clientCountry

                // 恢复上次选择
                let savedCfg = await SharedPreferences.knlinkSelectedConfigID.get()
                let savedNode = await SharedPreferences.knlinkSelectedNodeTag.get()
                if !globalConfigID.isEmpty, savedCfg == globalConfigID {
                    if !savedNode.isEmpty, let node = list.first(where: { $0.mode == .global && $0.name == savedNode }) {
                        selectedServerID = node.id
                        await rememberSelectedServer(node)
                    } else {
                        await SharedPreferences.knlinkSelectedConfigID.set("")
                        await SharedPreferences.knlinkSelectedNodeTag.set("")
                        await clearRememberedSelectedServer()
                        selectedServerID = ""
                    }
                } else if let node = list.first(where: { $0.id == savedCfg }) {
                    selectedServerID = node.id
                    await rememberSelectedServer(node)
                } else {
                    selectedServerID = ""
                }
            } catch {
                // 拉取失败时保留当前本地 UI 状态；连接侧会继续使用本机缓存配置。
                NSLog("KNLink fetchConfigList failed: \(error)")
            }
        }

        private func selectRemoteServer(_ server: ServerOption) async -> Bool {
            // 模式 B（JIT）：只记选择，连接那一刻用它解密那一份
            selectedServerID = server.id
            if server.mode == .global {
                // 全局：统一用服务端下发的全局配置；节点 tag 必须是 selector「proxy」里的具体成员。
                await SharedPreferences.knlinkSelectedConfigID.set(globalConfigID)
                await SharedPreferences.knlinkSelectedNodeTag.set(server.name)
            } else {
                await SharedPreferences.knlinkSelectedConfigID.set(server.id)
                await SharedPreferences.knlinkSelectedNodeTag.set("")
            }
            await rememberSelectedServer(server)
            return true
        }

        private func loadCachedSelectedServer() async {
            let selectedID = await SharedPreferences.knlinkSelectedConfigID.get()
            let name = await SharedPreferences.knlinkSelectedDisplayName.get()
            guard !selectedID.isEmpty, !name.isEmpty else { return }
            let region = await SharedPreferences.knlinkSelectedDisplayRegion.get()
            let modeValue = await SharedPreferences.knlinkSelectedDisplayMode.get()
            let mode = ServerSelectionMode(rawValue: modeValue) ?? .rule
            selectedServerID = selectedID
            cachedSelectedServer = ServerOption(
                id: selectedID,
                name: name,
                delay: "",
                mode: mode,
                outboundTags: [],
                regionCode: normalizedDisplayRegion(region)
            )
        }

        private func rememberSelectedServer(_ server: ServerOption) async {
            cachedSelectedServer = ServerOption(
                id: server.id,
                name: server.name,
                delay: server.delay,
                mode: server.mode,
                outboundTags: server.outboundTags,
                regionCode: normalizedDisplayRegion(server.regionCode),
                isMatched: server.isMatched
            )
            await SharedPreferences.knlinkSelectedDisplayName.set(server.name)
            await SharedPreferences.knlinkSelectedDisplayRegion.set(normalizedDisplayRegion(server.regionCode))
            await SharedPreferences.knlinkSelectedDisplayMode.set(server.mode.rawValue)
        }

        private func clearRememberedSelectedServer() async {
            cachedSelectedServer = nil
            await SharedPreferences.knlinkSelectedDisplayName.set("")
            await SharedPreferences.knlinkSelectedDisplayRegion.set("earth")
            await SharedPreferences.knlinkSelectedDisplayMode.set("")
        }

        private func normalizedDisplayRegion(_ regionCode: String) -> String {
            let code = regionCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return code.isEmpty || code == "xx" ? "earth" : code
        }
    }

    private struct ProfileSelectionSheet: View {
        let servers: [ServerOption]
        @ObservedObject var commandClient: CommandClient
        let matchedRuleName: String?
        let detectedClientIp: String?
        let detectedRegion: String?
        let detectedClientCountry: String?
        @Binding var selectedServerID: String
        @Binding var measuredDelays: [String: String]
        let selectServer: (ServerOption) async -> Bool

        @EnvironmentObject private var profile: ExtensionProfile
        @Environment(\.dismiss) private var dismiss
        @State private var selectedMode: ServerSelectionMode
        @State private var testingServerIDs: Set<String> = []
        @State private var isTestingVisibleServers = false

        private let urlTestGroupTag = "proxy"

        init(
            servers: [ServerOption],
            commandClient: CommandClient,
            initialMode: ServerSelectionMode,
            matchedRuleName: String?,
            detectedClientIp: String?,
            detectedRegion: String?,
            detectedClientCountry: String?,
            selectedServerID: Binding<String>,
            measuredDelays: Binding<[String: String]>,
            selectServer: @escaping (ServerOption) async -> Bool
        ) {
            self.servers = servers
            self.commandClient = commandClient
            self.matchedRuleName = matchedRuleName
            self.detectedClientIp = detectedClientIp
            self.detectedRegion = detectedRegion
            self.detectedClientCountry = detectedClientCountry
            _selectedMode = State(initialValue: initialMode)
            _selectedServerID = selectedServerID
            _measuredDelays = measuredDelays
            self.selectServer = selectServer
        }

        private var visibleServers: [ServerOption] {
            servers.filter { $0.mode == selectedMode }
        }

        private var canTestVisibleServers: Bool {
            !isTestingVisibleServers && visibleServers.contains { !$0.outboundTags.isEmpty }
        }

        private var latencyGreen: Color {
            Color(red: 0.12, green: 0.62, blue: 0.34)
        }

        private var detectedRegionName: String {
            switch detectedRegion?.lowercased() {
            case "cn":
                return "大陆"
            case "hk":
                return "香港"
            default:
                return "海外"
            }
        }

        private var detectedIpText: String {
            let ip = detectedClientIp?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ip.isEmpty ? "未知" : ip
        }

        private var recommendedRuleName: String {
            matchedRuleName ?? detectedRegionName
        }

        @ViewBuilder
        private var modeDescription: some View {
            switch selectedMode {
            case .rule:
                (
                    Text("根据你当前出口 IP ")
                        .foregroundColor(.secondary)
                    + Text(detectedIpText)
                        .foregroundColor(.primary)
                    + Text(" 判断你当前网络接入点位于 ")
                        .foregroundColor(.secondary)
                    + Text(detectedRegionName)
                        .foregroundColor(latencyGreen)
                    + Text("，推荐你选择 ")
                        .foregroundColor(.secondary)
                    + Text(recommendedRuleName)
                        .foregroundColor(latencyGreen)
                    + Text(" 节点接入。")
                        .foregroundColor(.secondary)
                )
            case .global:
                Text("本机所有流量都会通过所选出口接入网络，可能导致部分服务变慢或不可达。仅在明确需要全局代理时使用。")
                    .foregroundColor(.secondary)
            }
        }

        var body: some View {
            NavigationStackCompat {
                VStack(spacing: 0) {
                    Picker("Mode", selection: $selectedMode) {
                        Text("Rule Mode").tag(ServerSelectionMode.rule)
                        Text("Global Mode").tag(ServerSelectionMode.global)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)

                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 12) {
                            ForEach(visibleServers) { item in
                                NodeSelectionRow(
                                    item: item,
                                    isSelected: item.id == selectedServerID,
                                    select: {
                                        select(item)
                                    }
                                )
                            }

                            modeDescription
                                .font(.footnote)
                                .lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 6)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                    }
                }
                .navigationTitle("Select Node")
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            }
            .onReceive(commandClient.$groups) { groups in
                guard isTestingVisibleServers else { return }
                applyURLTestResults(from: groups)
            }
            .onAppear {
                if profile.status.isConnectedStrict {
                    commandClient.connect()
                }
            }
        }

        private func select(_ item: ServerOption) {
            selectedServerID = item.id
            Task {
                let success = await selectServer(item)
                if success {
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    dismiss()
                }
            }
        }

        private func testVisibleServers() {
            let targets = visibleServers.filter { !$0.outboundTags.isEmpty }
            guard !isTestingVisibleServers, !targets.isEmpty else { return }
            isTestingVisibleServers = true
            testingServerIDs.formUnion(targets.map(\.id))
            for item in targets {
                measuredDelays[item.id] = "测速中..."
            }
            Task {
                guard await ensureURLTestGroupReady() else {
                    let result = unavailableLatencyText()
                    for item in targets {
                        measuredDelays[item.id] = result
                        testingServerIDs.remove(item.id)
                    }
                    isTestingVisibleServers = false
                    return
                }

                do {
                    try await CommandTarget.standaloneClient().urlTest(urlTestGroupTag)
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    applyURLTestResults(from: commandClient.groups)
                } catch {
                    NSLog("Node URL test failed: %@", error.localizedDescription)
                    for item in targets {
                        measuredDelays[item.id] = "失败"
                        testingServerIDs.remove(item.id)
                    }
                }
                isTestingVisibleServers = false
            }
        }

        private func ensureURLTestGroupReady() async -> Bool {
            guard profile.status.isConnectedStrict else {
                return false
            }
            for _ in 0..<24 {
                if commandClient.isConnected,
                   commandClient.groups?.contains(where: { $0.tag == urlTestGroupTag }) == true
                {
                    return true
                }
                commandClient.connect()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return commandClient.isConnected &&
                commandClient.groups?.contains(where: { $0.tag == urlTestGroupTag }) == true
        }

        private func unavailableLatencyText() -> String {
            guard profile.status.isConnectedStrict else {
                return "未连接"
            }
            if commandClient.isConnected {
                return "需重连"
            }
            return "通道失败"
        }

        private func applyURLTestResults(from groups: [LibboxOutboundGroup]?) {
            let delays = delayByTag(from: groups)
            guard !delays.isEmpty else { return }

            for item in visibleServers where testingServerIDs.contains(item.id) {
                if let bestDelay = item.outboundTags.compactMap({ delays[$0] }).min() {
                    measuredDelays[item.id] = "\(bestDelay) ms"
                } else {
                    measuredDelays[item.id] = "无数据"
                }
                testingServerIDs.remove(item.id)
            }
        }

        private func delayByTag(from groups: [LibboxOutboundGroup]?) -> [String: Int] {
            guard let group = groups?.first(where: { $0.tag == urlTestGroupTag }) else {
                return [:]
            }
            var delays: [String: Int] = [:]
            let iterator = group.getItems()!
            while iterator.hasNext() {
                let item = iterator.next()!
                let delay = Int(item.urlTestDelay)
                if delay > 0 {
                    delays[item.tag] = delay
                }
            }
            return delays
        }

        private func latencyColor(for text: String) -> Color {
            guard let milliseconds = latencyMilliseconds(from: text) else {
                return latencyGreen
            }
            switch milliseconds {
            case ...120:
                return latencyGreen
            case ...250:
                return Color(red: 0.82, green: 0.56, blue: 0.05)
            default:
                return Color(red: 0.86, green: 0.18, blue: 0.16)
            }
        }

        private func latencyMilliseconds(from text: String) -> Int? {
            let digits = text.prefix { $0.isNumber }
            guard !digits.isEmpty else { return nil }
            return Int(digits)
        }
    }

    private struct NodeSelectionRow: View {
        let item: ServerOption
        let isSelected: Bool
        let select: () -> Void

        var body: some View {
            HStack(spacing: 14) {
                FlagImage(regionCode: item.regionCode)
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isSelected ? Color(red: 0.08, green: 0.39, blue: 0.88) : Color.secondary.opacity(0.35))
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                select()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.knCardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color(red: 0.08, green: 0.39, blue: 0.88).opacity(0.22) : Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
    }

    private enum ServerSelectionMode: String, CaseIterable, Identifiable {
        var id: Self { self }

        case rule
        case global

        var displayName: String {
            switch self {
            case .rule:
                return "规则模式"
            case .global:
                return "全局模式"
            }
        }
    }

    private struct ServerOption: Identifiable {
        let id: String
        let name: String
        let delay: String
        let mode: ServerSelectionMode
        let outboundTags: [String]
        let regionCode: String
        let isMatched: Bool

        init(id: String, name: String, delay: String, mode: ServerSelectionMode, outboundTags: [String], regionCode: String, isMatched: Bool = false) {
            self.id = id
            self.name = name
            self.delay = delay
            self.mode = mode
            self.outboundTags = outboundTags
            self.regionCode = regionCode
            self.isMatched = isMatched
        }

        // 加载完成前的占位（不是真实数据）
        static let placeholder = ServerOption(id: "", name: "同步节点中", delay: "", mode: .rule, outboundTags: [], regionCode: "earth")

    }

    private extension ServerSelectionMode {
        init(remoteValue: String?) {
            switch remoteValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "global", "global mode", "全局", "全局模式":
                self = .global
            default:
                self = .rule
            }
        }
    }

    private extension Dictionary where Key == String, Value == Any {
        func firstString(for keys: [String]) -> String? {
            for key in keys {
                if let value = self[key] as? String, !value.isEmpty {
                    return value
                }
                if let value = self[key] as? CustomStringConvertible {
                    let string = value.description
                    if !string.isEmpty {
                        return string
                    }
                }
            }
            return nil
        }

        func firstBool(for keys: [String]) -> Bool {
            for key in keys {
                if let value = self[key] as? Bool {
                    return value
                }
                if let value = self[key] as? NSNumber {
                    return value.boolValue
                }
                if let value = self[key] as? String {
                    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                    case "true", "1", "yes", "y":
                        return true
                    case "false", "0", "no", "n":
                        return false
                    default:
                        break
                    }
                }
            }
            return false
        }
    }

    private struct HeaderIcon: View {
        let systemName: String

        var body: some View {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 42, height: 42)
                .background(Color.primary.opacity(0.05), in: Circle())
        }
    }

    private struct PowerAuroraGlow: View {
        var body: some View {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let greenWave = (sin(t / 2.9 * 2 * .pi) + 1) / 2
                let blueWave = (sin(t / 3.7 * 2 * .pi + 1.4) + 1) / 2
                let mintWave = (sin(t / 4.6 * 2 * .pi + 2.1) + 1) / 2

                ZStack {
                    Circle()
                        .fill(Color(red: 0.20, green: 0.82, blue: 0.45).opacity(0.24 + 0.08 * greenWave))
                        .frame(width: 126, height: 126)
                        .blur(radius: 24)
                        .offset(x: -8 + 8 * greenWave, y: 8 - 6 * blueWave)

                    Circle()
                        .fill(Color(red: 0.20, green: 0.58, blue: 1.00).opacity(0.12 + 0.08 * blueWave))
                        .frame(width: 112, height: 112)
                        .blur(radius: 28)
                        .offset(x: 10 - 9 * blueWave, y: -10 + 7 * mintWave)

                    Circle()
                        .fill(Color(red: 0.44, green: 1.00, blue: 0.78).opacity(0.10 + 0.07 * mintWave))
                        .frame(width: 96, height: 96)
                        .blur(radius: 22)
                        .offset(x: 4 + 7 * mintWave, y: 12 - 8 * greenWave)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private struct DecorativeRings: View {
        let color: Color
        let showsPlanets: Bool

        var body: some View {
            ZStack {
                ForEach(0..<5) { index in
                    Circle()
                        .stroke(color.opacity(0.09 + Double(index) * 0.025), lineWidth: 1)
                        .scaleEffect(0.34 + CGFloat(index) * 0.16)
                }

                ForEach(0..<12) { index in
                    Capsule()
                        .fill(color.opacity(index.isMultiple(of: 3) ? 0.18 : 0.08))
                        .frame(width: 2, height: index.isMultiple(of: 2) ? 116 : 92)
                        .offset(y: -36)
                        .rotationEffect(.degrees(Double(index) * 30))
                }

                Circle()
                    .stroke(color.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [5, 9]))
                    .frame(width: 230, height: 230)

                if showsPlanets {
                    TimelineView(.animation) { timeline in
                        orbitingPlanets(at: timeline.date)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: showsPlanets)
            .animation(.easeInOut(duration: 0.25), value: color)
        }

        private func orbitingPlanets(at date: Date) -> some View {
            let t = date.timeIntervalSinceReferenceDate
            // 每个星球用不同周期 → 转速有快有慢；相位错开避免起步重叠
            func angle(period: Double, phase: Double) -> Double {
                t.truncatingRemainder(dividingBy: period) / period * 360 + phase
            }

            return ZStack {
                Planet(size: 11, color: Color(red: 0.49, green: 0.74, blue: 1.0))
                    .offset(y: -115)
                    .rotationEffect(.degrees(angle(period: 8.0, phase: 0)))

                Planet(size: 7, color: Color(red: 0.79, green: 0.89, blue: 1.0))
                    .offset(y: -115)
                    .rotationEffect(.degrees(angle(period: 4.0, phase: 126)))

                Planet(size: 5, color: Color(red: 0.23, green: 0.58, blue: 0.98))
                    .offset(y: -115)
                    .rotationEffect(.degrees(angle(period: 14.0, phase: 246)))
            }
        }
    }

    private struct Planet: View {
        let size: CGFloat
        let color: Color

        var body: some View {
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.85), lineWidth: 1)
                }
                .shadow(color: color.opacity(0.45), radius: 8, y: 2)
        }
    }

    private struct FlagImage: View {
        let regionCode: String

        // 跨平台加载国旗图（iOS UIImage / macOS NSImage）：先查资源目录，再查 bundle 内 png。
        private var flagImage: Image? {
            let normalizedRegionCode = regionCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let preferredName = normalizedRegionCode == "xx" || normalizedRegionCode.isEmpty ? "flag-earth" : "flag-\(normalizedRegionCode)"
            func bundleURL(_ name: String) -> URL? {
                ApplicationLibrary.bundle.url(forResource: name, withExtension: "png", subdirectory: "flag-png")
                    ?? ApplicationLibrary.bundle.url(forResource: name, withExtension: "png")
            }
            #if canImport(UIKit)
                if let img = UIImage(named: preferredName) ?? UIImage(named: "flag-earth") ?? UIImage(named: "flag-xx") {
                    return Image(uiImage: img)
                }
                for name in [preferredName, "flag-earth", "flag-xx"] {
                    if let url = bundleURL(name), let img = UIImage(contentsOfFile: url.path) {
                        return Image(uiImage: img)
                    }
                }
            #elseif canImport(AppKit)
                if let img = NSImage(named: preferredName) ?? NSImage(named: "flag-earth") ?? NSImage(named: "flag-xx") {
                    return Image(nsImage: img)
                }
                for name in [preferredName, "flag-earth", "flag-xx"] {
                    if let url = bundleURL(name), let img = NSImage(contentsOfFile: url.path) {
                        return Image(nsImage: img)
                    }
                }
            #endif
            return nil
        }

        var body: some View {
            ZStack {
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
                (flagImage ?? Image(systemName: "globe"))
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
                    .padding(5)
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)
        }
    }

    private struct SignalBars: View {
        let color: Color

        var body: some View {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<4) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color.opacity(0.35 + Double(index) * 0.15))
                        .frame(width: 4, height: CGFloat(8 + index * 4))
                }
            }
            .frame(width: 24, height: 28)
            .accessibilityHidden(true)
        }
    }

    private struct TrafficMetric: View {
        let title: LocalizedStringKey
        let value: String

        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: value)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
#endif
