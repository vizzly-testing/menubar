//
//  ServerManager.swift
//  Vizzly
//
//  Created by Robert DeLuca on 1/27/26.
//

import Foundation
import Combine
import AppKit

class ServerManager: ObservableObject {
    @Published private(set) var servers: [Server] = []
    @Published private(set) var serverStats: [String: ServerStats] = [:]
    @Published private(set) var serverLogs: [String: [LogEntry]] = [:]

    private let registryURL: URL
    private let vizzlyHomeURL: URL
    private var registryMonitor: FileMonitor?
    private var projectMonitors: [String: FileMonitor] = [:]
    private var logMonitors: [String: FileMonitor] = [:]

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        vizzlyHomeURL = home.appendingPathComponent(".vizzly")
        registryURL = vizzlyHomeURL.appendingPathComponent("servers.json")

        // Start watching immediately
        startWatching()
    }

    deinit {
        stopWatching()
    }

    // MARK: - Lifecycle

    private func startWatching() {
        loadRegistry()
        setupRegistryWatcher()
        setupDistributedNotificationListener()
    }

    func stopWatching() {
        registryMonitor?.stop()
        registryMonitor = nil

        for monitor in projectMonitors.values {
            monitor.stop()
        }
        projectMonitors.removeAll()

        for monitor in logMonitors.values {
            monitor.stop()
        }
        logMonitors.removeAll()

        // Remove Darwin notification observer
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(center, observer, nil, nil)
    }

    // MARK: - Registry Watching

    private func setupRegistryWatcher() {
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: vizzlyHomeURL, withIntermediateDirectories: true)

        registryMonitor = FileMonitor(url: vizzlyHomeURL) { [weak self] in
            self?.loadRegistry()
        }
        registryMonitor?.start()
    }

    private func setupDistributedNotificationListener() {
        // Listen for Darwin notifications from CLI (via notifyutil)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let manager = Unmanaged<ServerManager>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.loadRegistry()
                }
            },
            "dev.vizzly.serverChanged" as CFString,
            nil,
            .deliverImmediately
        )
    }

    // MARK: - Registry Loading

    private func loadRegistry() {
        let previousServerIds = Set(servers.map { $0.id })

        guard FileManager.default.fileExists(atPath: registryURL.path) else {
            servers = []
            cleanupProjectMonitors(for: [])
            return
        }

        do {
            let data = try Data(contentsOf: registryURL)
            let decoder = JSONDecoder()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let dateString = try container.decode(String.self)
                if let date = formatter.date(from: dateString) {
                    return date
                }
                // Fallback without fractional seconds
                let basicFormatter = ISO8601DateFormatter()
                if let date = basicFormatter.date(from: dateString) {
                    return date
                }
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(dateString)")
            }
            let registry = try decoder.decode(ServerRegistry.self, from: data)

            // Filter out stale servers (PID no longer exists)
            let liveServers = registry.servers.filter { server in
                kill(Int32(server.pid), 0) == 0
            }

            servers = liveServers

            // Update stats from registry if embedded
            for server in liveServers {
                if let stats = server.stats {
                    serverStats[server.id] = stats
                }
            }

            // Setup/cleanup project monitors for report-data.json
            let currentServerIds = Set(liveServers.map { $0.id })
            cleanupProjectMonitors(for: currentServerIds)
            setupProjectMonitors(for: liveServers, previousIds: previousServerIds)

        } catch {
            print("Failed to load registry: \(error)")
            servers = []
            cleanupProjectMonitors(for: [])
        }
    }

    // MARK: - Project File Watching

    private func setupProjectMonitors(for servers: [Server], previousIds: Set<String>) {
        for server in servers {
            // Skip if already monitoring
            guard projectMonitors[server.id] == nil else { continue }

            let vizzlyDir = URL(fileURLWithPath: server.directory).appendingPathComponent(".vizzly")

            // Watch report-data.json for stats updates
            let reportDataURL = vizzlyDir.appendingPathComponent("report-data.json")
            let statsMonitor = FileMonitor(url: reportDataURL) { [weak self] in
                self?.loadReportData(for: server)
            }
            statsMonitor.start()
            projectMonitors[server.id] = statsMonitor

            // Watch server.log for log updates
            if let logURL = server.logFileURL {
                let logMonitor = FileMonitor(url: logURL) { [weak self] in
                    self?.loadRecentLogs(for: server)
                }
                logMonitor.start()
                logMonitors[server.id] = logMonitor
            }

            // Initial load
            loadReportData(for: server)
            loadRecentLogs(for: server)
        }
    }

    private func cleanupProjectMonitors(for currentIds: Set<String>) {
        let staleIds = Set(projectMonitors.keys).subtracting(currentIds)
        for id in staleIds {
            projectMonitors[id]?.stop()
            projectMonitors.removeValue(forKey: id)
            logMonitors[id]?.stop()
            logMonitors.removeValue(forKey: id)
            serverStats.removeValue(forKey: id)
            serverLogs.removeValue(forKey: id)
        }
    }

    private func loadReportData(for server: Server) {
        let reportDataURL = URL(fileURLWithPath: server.directory)
            .appendingPathComponent(".vizzly/report-data.json")

        guard FileManager.default.fileExists(atPath: reportDataURL.path) else { return }

        do {
            let data = try Data(contentsOf: reportDataURL)
            let reportData = try JSONDecoder().decode(ReportData.self, from: data)
            serverStats[server.id] = reportData.stats
        } catch {
            print("Failed to load report data for \(server.name): \(error)")
        }
    }

    // MARK: - Log Reading

    private func loadRecentLogs(for server: Server, lineCount: Int = 100) {
        guard let logURL = server.logFileURL else {
            print("[Logs] No logFileURL for \(server.name)")
            return
        }

        guard FileManager.default.fileExists(atPath: logURL.path) else {
            print("[Logs] File not found: \(logURL.path)")
            return
        }

        do {
            let content = try String(contentsOf: logURL, encoding: .utf8)
            let rawLines = content.components(separatedBy: .newlines)
            let entries = rawLines.suffix(lineCount).compactMap { LogEntry.parse($0) }

            print("[Logs] Loaded \(entries.count) entries from \(rawLines.count) lines for \(server.name)")
            serverLogs[server.id] = entries
        } catch {
            print("[Logs] Failed to load for \(server.name): \(error)")
        }
    }

    func refreshLogs(for server: Server) {
        loadRecentLogs(for: server)
    }

    func openLogFile(for server: Server) {
        guard let logURL = server.logFileURL,
              FileManager.default.fileExists(atPath: logURL.path) else { return }
        NSWorkspace.shared.open(logURL)
    }

    // MARK: - HTTP Fetching (when needed)

    func fetchAuthStatus(for server: Server) async -> AuthStatus? {
        let url = server.dashboardURL.appendingPathComponent("api/auth/status")

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode(AuthStatus.self, from: data)
        } catch {
            return nil
        }
    }

    func checkHealth(for server: Server) async -> Bool {
        do {
            let (_, response) = try await URLSession.shared.data(from: server.healthURL)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Server Actions

    func openDashboard(_ server: Server) {
        NSWorkspace.shared.open(server.dashboardURL)
    }

    func openInFinder(_ server: Server) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: server.directory)
    }

    @Published var lastError: CLIError?

    func stopServer(_ server: Server) async {
        let result = await runCLICommand(["tdd", "stop"], in: server.directoryURL)

        if !result.success {
            let detail = [result.error, result.output]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            lastError = CLIError(message: "Failed to stop server", detail: detail)
        }

        loadRegistry()
    }

    func startServer(in directory: URL) async {
        let result = await runCLICommand(["tdd", "start"], in: directory)

        if !result.success {
            let detail = [result.error, result.output]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            lastError = CLIError(message: "Failed to start server", detail: detail)
        }

        loadRegistry()
    }

    func clearError() {
        lastError = nil
    }

    // MARK: - CLI Path Configuration

    /// Config structure for reading userPath from config.json
    private struct GlobalConfig: Codable {
        let userPath: String?
    }

    /// Get the user's PATH from CLI-written config
    /// Returns nil if CLI hasn't been run yet (user needs to run any vizzly command first)
    private func getUserPath() -> String? {
        let configURL = vizzlyHomeURL.appendingPathComponent("config.json")

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: configURL)
            let config = try JSONDecoder().decode(GlobalConfig.self, from: data)
            return config.userPath
        } catch {
            return nil
        }
    }

    /// Run a CLI command using the stored user PATH
    private func runCLICommand(_ args: [String], in directory: URL) async -> (success: Bool, output: String, error: String) {
        guard let userPath = getUserPath() else {
            return (false, "", "Vizzly CLI not configured. Run any 'vizzly' command in your terminal first to auto-configure.")
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["npx", "vizzly"] + args
        process.currentDirectoryURL = directory
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Use the stored user PATH
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = userPath
        process.environment = environment

        do {
            try process.run()

            // For daemon commands, wait a bit then check status
            if args.contains("start") {
                try await Task.sleep(for: .seconds(2))

                let stdoutData = stdoutPipe.fileHandleForReading.availableData
                let stderrData = stderrPipe.fileHandleForReading.availableData
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                if !process.isRunning && process.terminationStatus != 0 {
                    return (false, stdout, stderr)
                }
                return (true, stdout, stderr)
            } else {
                // For non-daemon commands, wait for completion
                process.waitUntilExit()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                return (process.terminationStatus == 0, stdout, stderr)
            }
        } catch {
            return (false, "", error.localizedDescription)
        }
    }

    // MARK: - Computed Properties

    var hasRunningServers: Bool {
        !servers.isEmpty
    }

    var hasFailures: Bool {
        serverStats.values.contains { $0.hasFailures }
    }

    var allHealthy: Bool {
        guard hasRunningServers else { return false }
        return serverStats.values.allSatisfy { $0.isHealthy }
    }

    /// Whether the CLI has been configured (user PATH exists in config)
    var isCLIConfigured: Bool {
        getUserPath() != nil
    }
}

// MARK: - File Monitor Helper

/// Watches a specific file, handling the case where the file may not exist yet.
/// When the file doesn't exist, watches the parent directory for file creation.
class FileMonitor {
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var dirDescriptor: Int32 = -1
    private let fileURL: URL
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        self.fileURL = url
        self.onChange = onChange
    }

    func start() {
        // Always watch the directory for file creation/deletion
        startDirectoryWatch()

        // If file exists, also watch it directly for modifications
        if FileManager.default.fileExists(atPath: fileURL.path) {
            startFileWatch()
        }
    }

    private func startDirectoryWatch() {
        let dirURL = fileURL.deletingLastPathComponent()

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        dirDescriptor = open(dirURL.path, O_EVTONLY)
        guard dirDescriptor != -1 else { return }

        dirSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirDescriptor,
            eventMask: [.write, .link, .rename],
            queue: .main
        )

        dirSource?.setEventHandler { [weak self] in
            guard let self = self else { return }

            // Check if our target file now exists and we're not watching it yet
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                if self.fileDescriptor == -1 {
                    self.startFileWatch()
                }
                self.onChange()
            }
        }

        dirSource?.setCancelHandler { [weak self] in
            if let fd = self?.dirDescriptor, fd != -1 {
                close(fd)
                self?.dirDescriptor = -1
            }
        }

        dirSource?.resume()
    }

    private func startFileWatch() {
        // Clean up existing file watch if any
        fileSource?.cancel()
        if fileDescriptor != -1 {
            close(fileDescriptor)
            fileDescriptor = -1
        }

        fileDescriptor = open(fileURL.path, O_EVTONLY)
        guard fileDescriptor != -1 else { return }

        fileSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )

        fileSource?.setEventHandler { [weak self] in
            guard let self = self else { return }

            let flags = self.fileSource?.data ?? []

            // If file was deleted or renamed, stop watching and rely on directory watch
            if flags.contains(.delete) || flags.contains(.rename) {
                self.fileSource?.cancel()
                self.fileSource = nil
                if self.fileDescriptor != -1 {
                    close(self.fileDescriptor)
                    self.fileDescriptor = -1
                }
            }

            self.onChange()
        }

        fileSource?.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd != -1 {
                close(fd)
                self?.fileDescriptor = -1
            }
        }

        fileSource?.resume()
    }

    func stop() {
        fileSource?.cancel()
        fileSource = nil
        dirSource?.cancel()
        dirSource = nil

        if fileDescriptor != -1 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        if dirDescriptor != -1 {
            close(dirDescriptor)
            dirDescriptor = -1
        }
    }
}
