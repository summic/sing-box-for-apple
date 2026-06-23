import Combine
import Foundation
import Libbox
import os

private let logger = Logger(category: "CommandClient")

public struct LogEntry: Identifiable {
    public let id = UUID()
    public let level: Int
    public let message: String

    public init(level: Int, message: String) {
        self.level = level
        self.message = message
    }
}

public struct LogBuffer {
    public var entries: [LogEntry]
    /// Cumulative count of entries trimmed from the front since the last reset,
    /// letting consumers compute incremental deltas after the buffer saturates.
    public var droppedCount: Int

    public init(entries: [LogEntry] = [], droppedCount: Int = 0) {
        self.entries = entries
        self.droppedCount = droppedCount
    }

    public var totalCount: Int {
        droppedCount + entries.count
    }
}

public enum LogLevel: Int, CaseIterable, Identifiable {
    public var id: Self {
        self
    }

    case error = 2
    case warn = 3
    case info = 4
    case debug = 5
    case trace = 6

    public var name: String {
        switch self {
        case .error:
            return "Error"
        case .warn:
            return "Warn"
        case .info:
            return "Info"
        case .debug:
            return "Debug"
        case .trace:
            return "Trace"
        }
    }
}

public struct TrafficSnapshot {
    public var status: LibboxStatusMessage?
    public var uplinkHistory: [CGFloat]
    public var downlinkHistory: [CGFloat]

    public init(
        status: LibboxStatusMessage? = nil,
        uplinkHistory: [CGFloat] = Array(repeating: 0, count: 30),
        downlinkHistory: [CGFloat] = Array(repeating: 0, count: 30)
    ) {
        self.status = status
        self.uplinkHistory = uplinkHistory
        self.downlinkHistory = downlinkHistory
    }
}

private struct KNLinkConnectionSignal: Sendable {
    enum EventKind: Sendable {
        case opened
        case updated
        case closed
    }

    let kind: EventKind
    let id: String
    let domain: String
    let destination: String
    let createdAt: Int64
    let closedAt: Int64
    let uploadTotal: Int64
    let downloadTotal: Int64
    let outbound: String
    let outboundType: String
    let chain: [String]
}

private actor KNLinkSignalReporter {
    static let shared = KNLinkSignalReporter()

    private struct StatKey: Hashable {
        let domain: String
        let path: String
    }

    private struct StatAccumulator {
        var ok = 0
        var fail = 0
    }

    private struct ReportStat: Encodable {
        let domain: String
        let path: String
        let ok: Int
        let fail: Int
    }

    private struct ReportRecord: Encodable {
        let domain: String
        let action: String
        let path: String
        let bytes: Int64
        let failed: Bool
    }

    private struct ReportBody: Encodable {
        let window: String
        let stats: [ReportStat]
        let records: [ReportRecord]
    }

    private let minimumFlushInterval: TimeInterval = 300
    private let urgentFlushDelay: TimeInterval = 30
    private let maxBackoff: TimeInterval = 1800
    private let maxRecords = 30
    private let urgentStatCount = 120
    private let urgentRecordCount = 30

    private var activeSignals: [String: KNLinkConnectionSignal] = [:]
    private var reportedClosedIds: [String] = []
    private var reportedClosedIdSet = Set<String>()
    private var stats: [StatKey: StatAccumulator] = [:]
    private var records: [ReportRecord] = []
    private var lastFlushAt: Date?
    private var nextRetryAt: Date?
    private var failureCount = 0
    private var flushTask: Task<Void, Never>?
    private var isFlushing = false

    func ingest(_ signals: [KNLinkConnectionSignal]) async {
        guard await SharedPreferences.knlinkMode.get(), !CommandTarget.isRemote else {
            return
        }
        var closedCount = 0
        for signal in signals {
            switch signal.kind {
            case .opened, .updated:
                activeSignals[signal.id] = signal
            case .closed:
                if reportedClosedIdSet.contains(signal.id) {
                    continue
                }
                let merged = mergeClosedSignal(signal)
                activeSignals.removeValue(forKey: signal.id)
                guard addClosedSignal(merged) else {
                    continue
                }
                rememberClosedId(signal.id)
                closedCount += 1
            }
        }
        guard closedCount > 0 else { return }
        scheduleFlush(urgent: stats.count >= urgentStatCount || records.count >= urgentRecordCount)
    }

    func flushSoon() async {
        scheduleFlush(urgent: true)
    }

    private func mergeClosedSignal(_ signal: KNLinkConnectionSignal) -> KNLinkConnectionSignal {
        guard let existing = activeSignals[signal.id] else { return signal }
        return KNLinkConnectionSignal(
            kind: .closed,
            id: signal.id,
            domain: signal.domain.isEmpty ? existing.domain : signal.domain,
            destination: signal.destination.isEmpty ? existing.destination : signal.destination,
            createdAt: signal.createdAt > 0 ? signal.createdAt : existing.createdAt,
            closedAt: signal.closedAt > 0 ? signal.closedAt : existing.closedAt,
            uploadTotal: max(signal.uploadTotal, existing.uploadTotal),
            downloadTotal: max(signal.downloadTotal, existing.downloadTotal),
            outbound: signal.outbound.isEmpty ? existing.outbound : signal.outbound,
            outboundType: signal.outboundType.isEmpty ? existing.outboundType : signal.outboundType,
            chain: signal.chain.isEmpty ? existing.chain : signal.chain
        )
    }

    private func addClosedSignal(_ signal: KNLinkConnectionSignal) -> Bool {
        guard signal.outboundType != "dns" else {
            return false
        }
        guard let domain = normalizedDomain(from: signal) else {
            return false
        }
        let route = routeInfo(for: signal)
        let bytes = max(0, signal.uploadTotal) + max(0, signal.downloadTotal)
        let failed = route.action != "block" && bytes == 0
        if route.action != "block" {
            let key = StatKey(domain: domain, path: route.path)
            var current = stats[key] ?? StatAccumulator()
            if failed {
                current.fail += 1
            } else {
                current.ok += 1
            }
            stats[key] = current
        }
        if records.count >= maxRecords {
            records.removeFirst(records.count - maxRecords + 1)
        }
        records.append(ReportRecord(domain: domain, action: route.action, path: route.path, bytes: bytes, failed: failed))
        return true
    }

    private func normalizedDomain(from signal: KNLinkConnectionSignal) -> String? {
        let candidates = [signal.domain, signal.destination]
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let host = trimmed
                .components(separatedBy: ":")
                .first?
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .lowercased() ?? ""
            guard host.contains("."), !host.allSatisfy({ $0.isNumber || $0 == "." }) else {
                continue
            }
            return host
        }
        return nil
    }

    private func routeInfo(for signal: KNLinkConnectionSignal) -> (action: String, path: String) {
        let outbound = signal.outbound.trimmingCharacters(in: .whitespacesAndNewlines)
        let outboundType = signal.outboundType.trimmingCharacters(in: .whitespacesAndNewlines)
        let chain = signal.chain.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if outbound == "block" || outboundType == "block" || chain.contains("block") {
            return ("block", "block")
        }
        if outbound == "direct" || outboundType == "direct" || chain.contains("direct") {
            return ("direct", "direct")
        }
        let path = chain.first { $0 != "proxy" && $0 != "proxy-auto" } ?? outbound
        return ("proxy", path.isEmpty ? "proxy" : path)
    }

    private func rememberClosedId(_ id: String) {
        reportedClosedIds.append(id)
        reportedClosedIdSet.insert(id)
        if reportedClosedIds.count > 1000 {
            let overflow = reportedClosedIds.count - 1000
            let removed = reportedClosedIds.prefix(overflow)
            reportedClosedIds.removeFirst(overflow)
            for id in removed {
                reportedClosedIdSet.remove(id)
            }
        }
    }

    private func scheduleFlush(urgent: Bool) {
        guard !stats.isEmpty || !records.isEmpty else { return }
        let now = Date()
        let intervalDue = lastFlushAt?.addingTimeInterval(minimumFlushInterval) ?? now.addingTimeInterval(urgent ? urgentFlushDelay : minimumFlushInterval)
        let retryDue = nextRetryAt ?? now
        let baseDue = max(intervalDue, retryDue)
        let due = urgent ? max(now.addingTimeInterval(urgentFlushDelay), retryDue) : baseDue
        let delay = max(1, due.timeIntervalSince(now))
        if flushTask != nil { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.flushIfPossible()
        }
    }

    private func flushIfPossible() async {
        flushTask = nil
        guard !isFlushing, (!stats.isEmpty || !records.isEmpty) else { return }
        if let nextRetryAt, Date() < nextRetryAt {
            scheduleFlush(urgent: false)
            return
        }
        isFlushing = true
        let snapshotStats = stats
        let snapshotRecords = records
        do {
            try await upload(stats: snapshotStats, records: snapshotRecords)
            for (key, value) in snapshotStats {
                guard var current = stats[key] else { continue }
                current.ok -= value.ok
                current.fail -= value.fail
                if current.ok <= 0 && current.fail <= 0 {
                    stats.removeValue(forKey: key)
                } else {
                    stats[key] = current
                }
            }
            if records.count == snapshotRecords.count {
                records.removeAll()
            } else {
                records.removeFirst(min(snapshotRecords.count, records.count))
            }
            failureCount = 0
            nextRetryAt = nil
            lastFlushAt = Date()
        } catch {
            failureCount += 1
            let backoff = min(pow(2.0, Double(max(0, failureCount - 1))) * 60, maxBackoff)
            nextRetryAt = Date().addingTimeInterval(backoff)
            KNLink.configDebugLog("[report] upload failed failureCount=\(failureCount) nextRetrySeconds=\(Int(backoff)) error=\(error.localizedDescription)")
        }
        isFlushing = false
        if !stats.isEmpty || !records.isEmpty {
            scheduleFlush(urgent: false)
        }
    }

    private func upload(stats snapshotStats: [StatKey: StatAccumulator], records snapshotRecords: [ReportRecord]) async throws {
        let token = try await KNLink.ensureDeviceToken(deviceName: "iOS Device", deviceType: "singbox")
        let serverBase = await SharedPreferences.knlinkServerBase.get()
        guard let url = URL(string: "\(serverBase)/api/report") else {
            throw URLError(.badURL)
        }
        let reportStats = snapshotStats.map { key, value in
            ReportStat(domain: key.domain, path: key.path, ok: value.ok, fail: value.fail)
        }
        let body = ReportBody(window: Self.currentHourWindow(), stats: reportStats, records: snapshotRecords)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw KNLink.ActivationError.badResponse(status, String(data: data, encoding: .utf8) ?? "")
        }
        KNLink.configDebugLog("[report] uploaded stats=\(reportStats.count) records=\(snapshotRecords.count)")
    }

    private static func currentHourWindow() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:00"
        return formatter.string(from: Date())
    }
}

public class CommandClient: ObservableObject {
    public enum ConnectionType {
        case status
        case groups
        case log
        case clashMode
        case connections
        case outbounds
    }

    public struct ConnectionError: Equatable {
        public enum Kind: Equatable {
            /// A connect attempt failed; retrying is not expected to succeed.
            case connectFailed
            /// An established connection dropped (app suspension, network
            /// change, server restart); reconnecting may recover.
            case connectionLost
        }

        public let kind: Kind
        public let message: String
    }

    private let connectionTypes: [ConnectionType]
    private let logMaxLines: Int
    private let localOnly: Bool
    private var commandClient: LibboxCommandClient?
    private var connectTask: Task<Void, Never>?
    private var activeConnectionToken: UInt64 = 0
    private var isConnecting = false
    @Published public var isConnected: Bool
    @Published public var lastError: ConnectionError?
    // Coalesce traffic updates so SwiftUI re-renders once per status tick.
    @Published private var trafficSnapshot = TrafficSnapshot()
    public var status: LibboxStatusMessage? {
        trafficSnapshot.status
    }

    public var statusPublisher: AnyPublisher<LibboxStatusMessage?, Never> {
        $trafficSnapshot
            .map(\.status)
            .eraseToAnyPublisher()
    }

    @Published public var groups: [LibboxOutboundGroup]?
    @Published public var outbounds: [LibboxOutboundGroupItem]?
    @Published public var logBuffer = LogBuffer()
    /// The server always sends the saved log backlog as the first message after
    /// subscribing (even when it is empty), so until it arrives an empty buffer
    /// means "still loading", not "no logs".
    @Published public private(set) var initialLogsReceived = false
    @Published public var defaultLogLevel = 0
    @Published public var selectedLogLevel: Int?
    @Published public var clashModeList: [String]
    @Published public var clashMode: String

    @Published public var connectionStateFilter = ConnectionStateFilter.active
    @Published public var connectionSort = ConnectionSort.byDate
    @Published public var connections: [LibboxConnection]?
    @Published public var hasAnyConnection: Bool = false
    private var connectionsStore: LibboxConnections?

    public var uplinkHistory: [CGFloat] {
        trafficSnapshot.uplinkHistory
    }

    public var downlinkHistory: [CGFloat] {
        trafficSnapshot.downlinkHistory
    }

    // Batch processing for logs
    private var pendingLogs: [LogEntry] = []
    private var logBatchTimer: DispatchWorkItem?
    private let logBatchInterval: TimeInterval = 0.1 // 100ms batch window

    public init(_ connectionTypes: [ConnectionType], logMaxLines: Int = 3000, localOnly: Bool = false) {
        self.connectionTypes = connectionTypes
        self.logMaxLines = logMaxLines
        self.localOnly = localOnly
        clashModeList = []
        clashMode = ""
        isConnected = false
    }

    public convenience init(_ connectionType: ConnectionType, logMaxLines: Int = 300, localOnly: Bool = false) {
        self.init([connectionType], logMaxLines: logMaxLines, localOnly: localOnly)
    }

    public func setupMockData() {
        isConnected = true
        clashModeList = ["rule", "global", "direct"]
        clashMode = "rule"
        trafficSnapshot = TrafficSnapshot(
            uplinkHistory: Array(repeating: CGFloat(1000), count: 30),
            downlinkHistory: Array(repeating: CGFloat(5000), count: 30)
        )
        hasAnyConnection = true
    }

    public func connect() {
        if isConnected || isConnecting {
            return
        }
        if let commandClient {
            try? commandClient.disconnect()
            self.commandClient = nil
        }
        isConnecting = true
        activeConnectionToken &+= 1
        let token = activeConnectionToken
        connectTask = Task { [weak self] in
            await self?.performConnection(token: token)
        }
    }

    public func disconnect() {
        if let connectTask {
            connectTask.cancel()
            self.connectTask = nil
        }
        isConnecting = false
        activeConnectionToken &+= 1
        if let commandClient {
            try? commandClient.disconnect()
            self.commandClient = nil
        }
        if isConnected {
            isConnected = false
        }
    }

    private func flushPendingLogs() {
        logBatchTimer = nil
        guard !pendingLogs.isEmpty else { return }

        // Build the new buffer locally so subscribers see a single, consistent publish.
        var buffer = logBuffer
        buffer.entries.append(contentsOf: pendingLogs)
        pendingLogs.removeAll()
        if buffer.entries.count > logMaxLines {
            let removeCount = buffer.entries.count - logMaxLines
            buffer.entries.removeFirst(removeCount)
            buffer.droppedCount += removeCount
        }
        logBuffer = buffer
    }

    public func clearLogs() {
        logBatchTimer?.cancel()
        logBatchTimer = nil
        pendingLogs.removeAll()
        logBuffer = LogBuffer()
    }

    public func filterConnectionsNow() {
        guard let store = connectionsStore else {
            return
        }
        let result = filterConnections(store)
        connections = result.connections
        hasAnyConnection = result.hasAny
    }

    private func filterConnections(_ message: LibboxConnections) -> (connections: [LibboxConnection], hasAny: Bool) {
        let hasAny = message.iterator()?.hasNext() ?? false
        message.filterState(Int32(connectionStateFilter.rawValue))
        switch connectionSort {
        case .byDate:
            message.sortByDate()
        case .byTraffic:
            message.sortByTraffic()
        case .byTrafficTotal:
            message.sortByTrafficTotal()
        }
        let connectionIterator = message.iterator()!
        var connections: [LibboxConnection] = []
        while connectionIterator.hasNext() {
            connections.append(connectionIterator.next()!)
        }
        return (connections: connections, hasAny: hasAny)
    }

    private func initializeConnectionFilterState() async {
        let newFilter: ConnectionStateFilter = await .init(rawValue: SharedPreferences.connectionStateFilter.get()) ?? .active
        let newSort: ConnectionSort = await .init(rawValue: SharedPreferences.connectionSort.get()) ?? .byDate
        await MainActor.run {
            connectionStateFilter = newFilter
            connectionSort = newSort
        }
    }

    private nonisolated func performConnection(token: UInt64) async {
        if connectionTypes.contains(.connections) {
            await initializeConnectionFilterState()
        }

        let clientOptions = LibboxCommandClientOptions()
        for connectionType in connectionTypes {
            switch connectionType {
            case .status:
                clientOptions.addCommand(LibboxCommandStatus)
            case .groups:
                clientOptions.addCommand(LibboxCommandGroup)
            case .log:
                clientOptions.addCommand(LibboxCommandLog)
            case .clashMode:
                clientOptions.addCommand(LibboxCommandClashMode)
            case .connections:
                clientOptions.addCommand(LibboxCommandConnections)
            case .outbounds:
                clientOptions.addCommand(LibboxCommandOutbounds)
            }
        }
        clientOptions.statusInterval = Int64(NSEC_PER_SEC)
        let client: LibboxCommandClient
        if !localOnly, let server = CommandTarget.remoteServer {
            var clientError: NSError?
            let remoteClient = LibboxNewRemoteCommandClient(clientHandler(self, connectionToken: token), clientOptions, CommandTarget.libboxOptions(server), &clientError)
            if let clientError {
                await reportConnectError(token: token, error: clientError)
                await finishConnectionAttempt(token: token, client: nil)
                return
            }
            client = remoteClient!
        } else {
            client = LibboxNewCommandClient(clientHandler(self, connectionToken: token), clientOptions)!
        }
        do {
            try client.connect()
        } catch {
            await reportConnectError(token: token, error: error)
            await finishConnectionAttempt(token: token, client: nil)
            return
        }
        await finishConnectionAttempt(token: token, client: client)
    }

    private func reportConnectError(token: UInt64, error: Error) async {
        await MainActor.run { [self] in
            guard token == activeConnectionToken else { return }
            lastError = ConnectionError(kind: .connectFailed, message: error.localizedDescription)
        }
    }

    private func finishConnectionAttempt(token: UInt64, client: LibboxCommandClient?) async {
        await MainActor.run { [self] in
            defer {
                isConnecting = false
                connectTask = nil
            }
            guard token == activeConnectionToken else {
                if let client {
                    try? client.disconnect()
                }
                return
            }
            if let client {
                commandClient = client
            }
        }
    }

    private class clientHandler: NSObject, LibboxCommandClientHandlerProtocol {
        private let commandClient: CommandClient
        private let connectionToken: UInt64

        init(_ commandClient: CommandClient, connectionToken: UInt64) {
            self.commandClient = commandClient
            self.connectionToken = connectionToken
        }

        private func isActiveConnection() -> Bool {
            commandClient.activeConnectionToken == connectionToken
        }

        func connected() {
            DispatchQueue.main.async { [self] in
                guard isActiveConnection() else { return }
                if commandClient.connectionTypes.contains(.log) {
                    commandClient.initialLogsReceived = false
                    commandClient.clearLogs()
                }
                commandClient.lastError = nil
                commandClient.isConnected = true
            }
        }

        func disconnected(_ message: String?) {
            DispatchQueue.main.async { [self] in
                guard isActiveConnection() else { return }
                if let message {
                    commandClient.lastError = ConnectionError(kind: .connectionLost, message: message)
                }
                commandClient.isConnected = false
            }
            Task {
                await KNLinkSignalReporter.shared.flushSoon()
            }
            if let message {
                logger.debug("client disconnected: \(message)")
            }
        }

        func setDefaultLogLevel(_ level: Int32) {
            DispatchQueue.main.async { [self] in
                guard isActiveConnection() else { return }
                commandClient.defaultLogLevel = Int(level)
            }
        }

        func clearLogs() {
            DispatchQueue.main.async { [self] in
                guard isActiveConnection() else { return }
                commandClient.clearLogs()
            }
        }

        func writeLogs(_ messageList: (any LibboxLogIteratorProtocol)?) {
            guard let messageList else {
                return
            }
            guard isActiveConnection() else { return }

            // Collect new logs
            var newLogs: [LogEntry] = []
            while messageList.hasNext() {
                let logEntry = messageList.next()!
                newLogs.append(LogEntry(level: Int(logEntry.level), message: logEntry.message))
            }

            DispatchQueue.main.async { [self] in
                guard isActiveConnection() else { return }
                if !commandClient.initialLogsReceived {
                    commandClient.initialLogsReceived = true
                }
                guard !newLogs.isEmpty else { return }
                commandClient.pendingLogs.append(contentsOf: newLogs)
                if commandClient.logBatchTimer == nil {
                    if commandClient.logBuffer.entries.isEmpty {
                        // First batch after connect: paint the backlog immediately
                        // instead of waiting out the batch window.
                        commandClient.flushPendingLogs()
                    } else {
                        let workItem = DispatchWorkItem { [weak commandClient] in
                            guard let commandClient else { return }
                            commandClient.flushPendingLogs()
                        }
                        commandClient.logBatchTimer = workItem
                        DispatchQueue.main.asyncAfter(deadline: .now() + commandClient.logBatchInterval, execute: workItem)
                    }
                }
            }
        }

        func writeStatus(_ message: LibboxStatusMessage?) {
            DispatchQueue.main.async { [self] in
                guard isActiveConnection() else { return }
                var snapshot = commandClient.trafficSnapshot
                snapshot.status = message
                if let message, message.trafficAvailable {
                    snapshot.uplinkHistory.removeFirst()
                    snapshot.uplinkHistory.append(CGFloat(message.uplink))

                    snapshot.downlinkHistory.removeFirst()
                    snapshot.downlinkHistory.append(CGFloat(message.downlink))
                }
                commandClient.trafficSnapshot = snapshot
            }
        }

        func writeGroups(_ groups: LibboxOutboundGroupIteratorProtocol?) {
            guard let groups else {
                return
            }
            guard isActiveConnection() else { return }
            var newGroups: [LibboxOutboundGroup] = []
            while groups.hasNext() {
                newGroups.append(groups.next()!)
            }
            DispatchQueue.main.async { [self] in
                guard isActiveConnection() else { return }
                commandClient.groups = newGroups
            }
        }

        func writeOutbounds(_ message: (any LibboxOutboundGroupItemIteratorProtocol)?) {
            guard let message else { return }
            guard isActiveConnection() else { return }
            var newOutbounds: [LibboxOutboundGroupItem] = []
            while message.hasNext() {
                newOutbounds.append(message.next()!)
            }
            DispatchQueue.main.async { [self] in
                guard isActiveConnection() else { return }
                commandClient.outbounds = newOutbounds
            }
        }

        func initializeClashMode(_ modeList: LibboxStringIteratorProtocol?, currentMode: String?) {
            DispatchQueue.main.async { [self] in
                guard isActiveConnection() else { return }
                commandClient.clashModeList = modeList!.toArray()
                commandClient.clashMode = currentMode!
            }
        }

        func updateClashMode(_ newMode: String?) {
            DispatchQueue.main.async { [self] in
                guard isActiveConnection() else { return }
                commandClient.clashMode = newMode!
            }
        }

        func write(_ events: LibboxConnectionEvents?) {
            guard let events else {
                return
            }
            let signals = collectSignals(events)
            DispatchQueue.main.async { [self] in
                guard isActiveConnection() else { return }
                if commandClient.connectionsStore == nil {
                    commandClient.connectionsStore = LibboxNewConnections()
                }
                commandClient.connectionsStore?.apply(events)
                let result = commandClient.filterConnections(commandClient.connectionsStore!)
                commandClient.connections = result.connections
                commandClient.hasAnyConnection = result.hasAny
            }
            if !signals.isEmpty {
                Task {
                    await KNLinkSignalReporter.shared.ingest(signals)
                }
            }
        }

        private func collectSignals(_ events: LibboxConnectionEvents) -> [KNLinkConnectionSignal] {
            guard !CommandTarget.isRemote else {
                return []
            }
            guard let iterator = events.iterator() else {
                return []
            }
            var signals: [KNLinkConnectionSignal] = []
            while iterator.hasNext() {
                guard let event = iterator.next() else { continue }
                let kind: KNLinkConnectionSignal.EventKind
                switch Int64(event.type) {
                case LibboxConnectionEventNew:
                    kind = .opened
                case LibboxConnectionEventUpdate:
                    kind = .updated
                case LibboxConnectionEventClosed:
                    kind = .closed
                default:
                    continue
                }
                guard let connection = event.connection else {
                    if kind == .closed, !event.id_.isEmpty {
                        signals.append(KNLinkConnectionSignal(
                            kind: kind,
                            id: event.id_,
                            domain: "",
                            destination: "",
                            createdAt: 0,
                            closedAt: event.closedAt,
                            uploadTotal: event.uplinkDelta,
                            downloadTotal: event.downlinkDelta,
                            outbound: "",
                            outboundType: "",
                            chain: []
                        ))
                    }
                    continue
                }
                signals.append(KNLinkConnectionSignal(
                    kind: kind,
                    id: connection.id_,
                    domain: connection.domain,
                    destination: connection.destination,
                    createdAt: connection.createdAt,
                    closedAt: max(connection.closedAt, event.closedAt),
                    uploadTotal: max(connection.uplinkTotal, event.uplinkDelta),
                    downloadTotal: max(connection.downlinkTotal, event.downlinkDelta),
                    outbound: connection.outbound,
                    outboundType: connection.outboundType,
                    chain: connection.chain()?.toArray() ?? []
                ))
            }
            return signals
        }
    }
}

public enum ConnectionStateFilter: Int, CaseIterable, Identifiable {
    public var id: Self {
        self
    }

    case all
    case active
    case closed
}

public extension ConnectionStateFilter {
    var name: String {
        switch self {
        case .all:
            return NSLocalizedString("All", comment: "")
        case .active:
            return NSLocalizedString("Active", comment: "")
        case .closed:
            return NSLocalizedString("Closed", comment: "")
        }
    }
}

public enum ConnectionSort: Int, CaseIterable, Identifiable {
    public var id: Self {
        self
    }

    case byDate
    case byTraffic
    case byTrafficTotal
}

public extension ConnectionSort {
    var name: String {
        switch self {
        case .byDate:
            return NSLocalizedString("Date", comment: "")
        case .byTraffic:
            return NSLocalizedString("Traffic", comment: "")
        case .byTrafficTotal:
            return NSLocalizedString("Traffic Total", comment: "")
        }
    }
}
