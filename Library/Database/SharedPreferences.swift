import Foundation

#if os(macOS)
    public enum MenuBarExtraSpeedMode: Int, CaseIterable {
        case disabled = 0
        case enabled = 1
        case unified = 2

        public var name: String {
            switch self {
            case .disabled:
                return NSLocalizedString("Disabled", comment: "")
            case .enabled:
                return NSLocalizedString("Enabled", comment: "")
            case .unified:
                return NSLocalizedString("Unified", comment: "")
            }
        }
    }
#endif

public enum SharedPreferences {
    public static let selectedProfileID = Preference<Int64>("selected_profile_id", defaultValue: -1)

    #if os(iOS)
        private static let excludeLocalNetworksByDefault = true
    #elseif os(macOS)
        private static let excludeLocalNetworksByDefault = false
    #endif

    #if !os(tvOS)
        public static let includeAllNetworks = Preference<Bool>("include_all_networks", defaultValue: false)
        public static let excludeAPNs = Preference<Bool>("exclude_apns", defaultValue: true)
        public static let excludeLocalNetworks = Preference<Bool>("exclude_local_networks", defaultValue: excludeLocalNetworksByDefault)
        public static let excludeCellularServices = Preference<Bool>("exclude_cellular_services", defaultValue: true)
        public static let enforceRoutes = Preference<Bool>("enforce_routes", defaultValue: false)
        public static let excludeDeviceCommunication = Preference<Bool>("exclude_device_communication", defaultValue: true)

    #endif

    public static func resetPacketTunnel() async {
        #if !os(tvOS)
            let names = [
                includeAllNetworks.name,
                excludeAPNs.name,
                excludeLocalNetworks.name,
                excludeCellularServices.name,
                enforceRoutes.name,
                excludeDeviceCommunication.name,
            ]
            try? await batchDelete(names)
        #endif
    }

    public static let maxLogLines = Preference<Int>("max_log_lines", defaultValue: 300)

    #if os(macOS)
        public static let oomKillerEnabled = Preference<Bool>("oom_killer_enabled", defaultValue: false)
        public static let oomMemoryLimitMB = Preference<Int>("oom_memory_limit_mb", defaultValue: 50)
        public static let oomKillerKillConnections = Preference<Bool>("oom_killer_kill_connections", defaultValue: false)
    #endif

    #if os(macOS)
        public static let showMenuBarExtra = Preference<Bool>("show_menu_bar_extra", defaultValue: true)
        public static let menuBarExtraInBackground = Preference<Bool>("menu_bar_extra_in_background", defaultValue: false)
        public static let menuBarExtraSpeedMode = Preference<Int>("menu_bar_extra_speed_mode_1", defaultValue: MenuBarExtraSpeedMode.enabled.rawValue)
        public static let startedByUser = Preference<Bool>("started_by_user", defaultValue: false)

        public static func resetMacOS() async {
            try? await batchDelete([
                showMenuBarExtra.name,
                menuBarExtraInBackground.name,
                menuBarExtraSpeedMode.name,
            ])
        }
    #endif

    #if os(iOS)
        public static let networkPermissionRequested = Preference<Bool>("network_permission_requested", defaultValue: false)
    #endif

    public static let systemProxyEnabled = Preference<Bool>("system_proxy_enabled", defaultValue: true)

    #if os(tvOS)
        public static let commandServerPort = Preference<Int32>("command_server_port", defaultValue: 0)
        public static let commandServerSecret = Preference<String>("command_server_secret", defaultValue: "")
    #endif

    // Profile Override

    public static let excludeDefaultRoute = Preference<Bool>("exclude_default_route", defaultValue: false)
    public static let autoRouteUseSubRangesByDefault = Preference<Bool>("auto_route_use_sub_ranges_by_default", defaultValue: false)
    public static let excludeAPNsRoute = Preference<Bool>("exclude_apple_push_notification_services", defaultValue: false)

    public static func resetProfileOverride() async {
        try? await batchDelete([excludeDefaultRoute.name, autoRouteUseSubRangesByDefault.name, excludeAPNsRoute.name])
    }

    // Connections Filter

    public static let connectionStateFilter = Preference<Int>("connection_state_filter", defaultValue: 0)
    public static let connectionSort = Preference<Int>("connection_sort", defaultValue: 0)

    // Remote Control

    public static let activeRemoteServerID = Preference<Int64>("active_remote_server_id", defaultValue: 0)

    // On Demand Rules

    public static let alwaysOn = Preference<Bool>("always_on", defaultValue: false)
    public static let onDemandEnabled = Preference<Bool>("on_demand_enabled", defaultValue: false)
    public static let onDemandRules = Preference<[OnDemandRule]>("on_demand_rules", defaultValue: [])

    public static func resetOnDemandRules() async throws {
        try await batchDelete([alwaysOn.name, onDemandEnabled.name, onDemandRules.name])
    }

    // Update (macOS standalone)

    #if os(macOS)
        public static let checkUpdateEnabled = Preference<Bool>("check_update_enabled", defaultValue: false)
        public static let updateCheckPrompted = Preference<Bool>("update_check_prompted", defaultValue: false)
        public static let updateTrack = Preference<String>("update_track", defaultValue: "")
        public static let cachedUpdateInfo = Preference<String>("cached_update_info", defaultValue: "")
        public static let lastShownUpdateVersion = Preference<String>("last_shown_update_version", defaultValue: "")
    #endif

    // Core

    public static let disableDeprecatedWarnings = Preference<Bool>("disable_deprecated_warnings", defaultValue: false)

    // Tools

    public static let nqConfigURL = Preference<String>("nq_config_url", defaultValue: "")
    public static let nqSerial = Preference<Bool>("nq_serial", defaultValue: false)
    public static let nqHttp3 = Preference<Bool>("nq_http3", defaultValue: false)
    public static let nqMaxRuntime = Preference<Int>("nq_max_runtime", defaultValue: 30)
    public static let stunServer = Preference<String>("stun_server", defaultValue: "")
    public static let tailscaleSSHRememberedUsernames = Preference<[String: String]>("tailscale_ssh_remembered_usernames", defaultValue: [:])
    public static let tailscaleSSHRememberedTerminalTypes = Preference<[String: String]>("tailscale_ssh_remembered_terminal_types", defaultValue: [:])
    public static let tailscaleSSHQuickConnectPeers = Preference<Set<String>>("tailscale_ssh_quick_connect_peers", defaultValue: [])
    #if os(macOS)
        public static let tailscaleSSHForwardAgent = Preference<Bool>("tailscale_ssh_forward_agent", defaultValue: false)
    #endif
    public static let tailscaleSSHGhosttyLightTheme = Preference<String>("tailscale_ssh_ghostty_light_theme", defaultValue: "Alabaster")
    public static let tailscaleSSHGhosttyDarkTheme = Preference<String>("tailscale_ssh_ghostty_dark_theme", defaultValue: "Afterglow")
    public static let tailscaleSSHGhosttyLightConfig = Preference<String>("tailscale_ssh_ghostty_light_config", defaultValue: "")
    public static let tailscaleSSHGhosttyDarkConfig = Preference<String>("tailscale_ssh_ghostty_dark_config", defaultValue: "")
    public static let tailscaleSSHTerminalFontFollowTheme = Preference<Bool>("tailscale_ssh_terminal_font_follow_theme", defaultValue: true)
    public static let tailscaleSSHTerminalFontFamily = Preference<String>("tailscale_ssh_terminal_font_family", defaultValue: "")
    #if os(macOS)
        public static let tailscaleSSHTerminalFontSize = Preference<Double>("tailscale_ssh_terminal_font_size", defaultValue: 13)
    #else
        public static let tailscaleSSHTerminalFontSize = Preference<Double>("tailscale_ssh_terminal_font_size", defaultValue: 10)
    #endif

    // Dashboard

    public static let enabledDashboardCards = Preference<[String]>("enabled_dashboard_cards", defaultValue: [])
    public static let dashboardCardOrder = Preference<[String]>("dashboard_card_order", defaultValue: [])

    // KNLink

    /// 服务端地址（设置页可改）。生产默认指向 link.beforeve.com；本地调试可在设置页改回局域网 IP。
    public static let knlinkServerBase = Preference<String>("knlink_server_base", defaultValue: "https://link.beforeve.com")
    /// OAuth 登录后保存的会话/Bearer 令牌（激活与拉取配置时鉴权）
    public static let knlinkSessionToken = Preference<String>("knlink_session_token", defaultValue: "")
    /// KNLink 模式：开启后，隧道优先使用本机缓存的服务端加密配置启动，再静默同步远程配置。
    public static let knlinkMode = Preference<Bool>("knlink_mode", defaultValue: false)
    /// KN Account（Hydra）地址与移动端公有客户端 ID（PKCE 直连授权用）
    public static let knlinkSsoBase = Preference<String>("knlink_sso_base", defaultValue: "https://account.beforeve.com")
    public static let knlinkSsoMobileClientID = Preference<String>("knlink_sso_mobile_client_id", defaultValue: "kn-b4af6eff94ca")
    /// Apple TV 设备码流程专用客户端 ID（device_code grant）
    public static let knlinkSsoDeviceClientID = Preference<String>("knlink_sso_device_client_id", defaultValue: "kn-fd70857e7d1d")
    /// 激活后服务端返回的设备 ID（配置请求带 ?device= 指明用哪台设备的公钥加密）
    public static let knlinkDeviceID = Preference<String>("knlink_device_id", defaultValue: "")
    /// 设备 ID 的永久备份。普通退出登录不能清理；用于修复旧版本误删主 deviceId 后的恢复。
    public static let knlinkDeviceIDBackup = Preference<String>("knlink_device_id_backup", defaultValue: "")
    /// 服务端颁发的设备上报令牌。用于 /api/report；普通退出登录不能清理。
    public static let knlinkDeviceToken = Preference<String>("knlink_device_token", defaultValue: "")
    /// 用户在分组列表里选中的配置 id（空=未选择，连接时不自动兜底）
    public static let knlinkSelectedConfigID = Preference<String>("knlink_selected_config_id", defaultValue: "")
    /// 全局模式下用户选中的节点 tag（=节点名）；空=未选择。仅对全局单份配置生效。
    public static let knlinkSelectedNodeTag = Preference<String>("knlink_selected_node_tag", defaultValue: "")
    /// 首页展示用的最近一次选择，避免远程列表同步前显示占位状态。
    public static let knlinkSelectedDisplayName = Preference<String>("knlink_selected_display_name", defaultValue: "")
    public static let knlinkSelectedDisplayRegion = Preference<String>("knlink_selected_display_region", defaultValue: "earth")
    public static let knlinkSelectedDisplayMode = Preference<String>("knlink_selected_display_mode", defaultValue: "")
    /// 当前可用配置的加密缓存。只保存服务端给本设备公钥加密后的 blob，不保存明文 sing-box 配置。
    public static let knlinkCachedConfigID = Preference<String>("knlink_cached_config_id", defaultValue: "")
    public static let knlinkCachedConfigURL = Preference<String>("knlink_cached_config_url", defaultValue: "")
    public static let knlinkCachedConfigIsGlobal = Preference<Bool>("knlink_cached_config_is_global", defaultValue: false)
    public static let knlinkCachedEncryptedConfig = Preference<String>("knlink_cached_encrypted_config", defaultValue: "")
    public static let knlinkCachedConfigUpdatedAt = Preference<Double>("knlink_cached_config_updated_at", defaultValue: 0)
    /// OIDC userinfo 缓存；过期时间与 access token 保持一致，避免每次进设置页都拉取。
    public static let knlinkCachedUserInfo = Preference<[String: String]>("knlink_cached_user_info", defaultValue: [:])
    public static let knlinkCachedUserInfoExpiry = Preference<Double>("knlink_cached_user_info_expiry", defaultValue: 0)
    public static let knlinkCachedUserAvatarURL = Preference<String>("knlink_cached_user_avatar_url", defaultValue: "")
    public static let knlinkCachedUserAvatarData = Preference<Data>("knlink_cached_user_avatar_data", defaultValue: Data())
}
