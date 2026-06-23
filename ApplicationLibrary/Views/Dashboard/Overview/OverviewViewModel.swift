import Foundation
import Libbox
import Library
import SwiftUI

@MainActor
public final class OverviewViewModel: BaseViewModel {
    @Published public var reasserting = false
    @Published public var isStarting = false

    public func switchProfile(_ profileID: Int64, profile: ExtensionProfile, environments: ExtensionEnvironments) async {
        await SharedPreferences.selectedProfileID.set(profileID)
        environments.selectedProfileUpdate.send()

        if profile.status.isConnected {
            do {
                try await profile.reloadService()
            } catch {
                alert = AlertState(action: "reload service", error: error)
            }
        }
        reasserting = false
    }

    public func setServiceEnabled(_ enabled: Bool, profile: ExtensionProfile) async {
        KNLink.configDebugLog("[home] setServiceEnabled enabled=\(enabled) statusBefore=\(profile.status.rawValue)")
        do {
            if enabled {
                isStarting = true
                KNLink.configDebugLog("[home] calling profile.start")
                try await profile.start()
                KNLink.configDebugLog("[home] profile.start returned statusAfter=\(profile.status.rawValue)")
            } else {
                KNLink.configDebugLog("[home] calling profile.stop")
                try await profile.stop()
                KNLink.configDebugLog("[home] profile.stop returned statusAfter=\(profile.status.rawValue)")
            }
        } catch {
            isStarting = false
            let action = enabled ? "start service" : "stop service"
            KNLink.configDebugLog("[home] setServiceEnabled failed action=\(action) error=\(error)")
            alert = AlertState(action: action, error: error)
        }
    }

    @available(iOS 16.0, macOS 13.0, tvOS 17.0, *)
    public func checkStartupError(profile: ExtensionProfile) async {
        if let alertState = await profile.checkLastDisconnectError() {
            alert = alertState
        }
    }

    public nonisolated func setSystemProxyEnabled(_ enabled: Bool, profile: ExtensionProfile) async {
        do {
            await SharedPreferences.systemProxyEnabled.set(enabled)
            if enabled {
                try LibboxNewStandaloneCommandClient()!.setSystemProxyEnabled(enabled)
            } else {
                await MainActor.run { reasserting = true }
                try await profile.restart()
                await MainActor.run { reasserting = false }
            }
        } catch {
            await MainActor.run { alert = AlertState(action: "update system proxy settings", error: error) }
        }
    }
}
