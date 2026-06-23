import Foundation
import Libbox
import Library
import SwiftUI

@MainActor
public final class STUNTestViewModel: BaseViewModel, OutboundSelectable {
    @Published public var phase: Int32 = -1
    @Published public var externalAddr: String = ""
    @Published public var latencyMs: Int32 = 0
    @Published public var natMapping: Int32 = 0
    @Published public var natFiltering: Int32 = 0
    @Published public var natTypeSupported: Bool = false
    @Published public var isRunning = false
    @Published public var selectedOutbound: String = ""

    @Published public var server: String = LibboxSTUNDefaultServer {
        didSet {
            guard !isLoadingPreferences else { return }
            saveServerTask?.cancel()
            saveServerTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await SharedPreferences.stunServer.set(server)
            }
        }
    }

    private var isLoadingPreferences = false
    private var saveServerTask: Task<Void, Never>?
    private var standaloneTest: LibboxSTUNTest?
    private var stunSession: LibboxSTUNTestSession?
    private var runningTask: Task<Void, Never>?
    private static let knownProxyEndpoints = Set([
        "106.75.169.134:443",
    ])

    public func loadPreferences() async {
        isLoadingPreferences = true
        let saved = await SharedPreferences.stunServer.get()
        if !saved.isEmpty {
            server = Self.sanitizedServer(saved)
            if server != saved {
                await SharedPreferences.stunServer.set(server)
            }
        }
        isLoadingPreferences = false
    }

    public func startTest(vpnConnected: Bool) {
        let validatedServer = Self.sanitizedServer(server)
        if validatedServer != server {
            server = validatedServer
            Task {
                await SharedPreferences.stunServer.set(validatedServer)
            }
            alert = AlertState(
                errorMessage: String(localized: "The STUN server was set to a KNLink proxy node. Proxy nodes do not answer STUN binding requests. It has been reset to \(validatedServer).")
            )
            return
        }

        phase = -1
        externalAddr = ""
        latencyMs = 0
        natMapping = 0
        natFiltering = 0
        natTypeSupported = false
        isRunning = true

        let server = server
        let outboundTag = selectedOutbound

        if vpnConnected {
            let handler = TestHandler(self)
            Task { [weak self] in
                do {
                    let session = try await Task.detached {
                        try CommandTarget.standaloneClient().startSTUNTest(server, outboundTag: outboundTag, handler: handler)
                    }.value
                    self?.stunSession = session
                } catch {
                    guard let self else { return }
                    self.isRunning = false
                    self.alert = AlertState(action: "STUN test", error: error)
                }
            }
        } else {
            let test = LibboxNewSTUNTest()!
            standaloneTest = test
            let handler = TestHandler(self)
            test.start(server, handler: handler)
        }
    }

    private static func sanitizedServer(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return LibboxSTUNDefaultServer }
        if let endpoint = endpointKey(trimmed), knownProxyEndpoints.contains(endpoint) {
            return LibboxSTUNDefaultServer
        }
        return trimmed
    }

    private static func endpointKey(_ value: String) -> String? {
        if let url = URL(string: value), let host = url.host {
            if let port = url.port {
                return "\(host.lowercased()):\(port)"
            }
            return host.lowercased()
        }
        var raw = value
        if let schemeRange = raw.range(of: "://") {
            raw.removeSubrange(raw.startIndex ..< schemeRange.upperBound)
        }
        raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !raw.isEmpty else { return nil }
        return raw.lowercased()
    }

    public func cancel() {
        try? stunSession?.close()
        stunSession = nil
        runningTask?.cancel()
        runningTask = nil
        standaloneTest?.cancel()
        standaloneTest = nil
        isRunning = false
    }

    private final class TestHandler: NSObject, LibboxSTUNTestHandlerProtocol, @unchecked Sendable {
        private weak var viewModel: STUNTestViewModel?

        init(_ viewModel: STUNTestViewModel?) {
            self.viewModel = viewModel
        }

        func onProgress(_ progress: LibboxSTUNTestProgress?) {
            guard let progress else { return }
            let phase = progress.phase
            let externalAddr = progress.externalAddr
            let latencyMs = progress.latencyMs
            let natMapping = progress.natMapping
            let natFiltering = progress.natFiltering
            DispatchQueue.main.async { [self] in
                guard let viewModel, viewModel.isRunning else { return }
                viewModel.phase = phase
                if !externalAddr.isEmpty {
                    viewModel.externalAddr = externalAddr
                }
                if latencyMs > 0 {
                    viewModel.latencyMs = latencyMs
                }
                viewModel.natMapping = natMapping
                viewModel.natFiltering = natFiltering
            }
        }

        func onResult(_ result: LibboxSTUNTestResult?) {
            guard let result else { return }
            let externalAddr = result.externalAddr
            let latencyMs = result.latencyMs
            let natMapping = result.natMapping
            let natFiltering = result.natFiltering
            let natTypeSupported = result.natTypeSupported
            DispatchQueue.main.async { [self] in
                guard let viewModel, viewModel.isRunning else { return }
                viewModel.phase = LibboxSTUNPhaseDone
                viewModel.externalAddr = externalAddr
                viewModel.latencyMs = latencyMs
                viewModel.natMapping = natMapping
                viewModel.natFiltering = natFiltering
                viewModel.natTypeSupported = natTypeSupported
                viewModel.isRunning = false
                viewModel.stunSession = nil
                viewModel.runningTask = nil
                viewModel.standaloneTest = nil
            }
        }

        func onError(_ message: String?) {
            DispatchQueue.main.async { [self] in
                guard let viewModel, viewModel.isRunning else { return }
                viewModel.isRunning = false
                viewModel.stunSession = nil
                viewModel.runningTask = nil
                viewModel.standaloneTest = nil
                if let message {
                    viewModel.alert = AlertState(errorMessage: message)
                }
            }
        }
    }
}
