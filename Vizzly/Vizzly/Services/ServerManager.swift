//
//  ServerManager.swift
//  Vizzly
//
//  Created by Robert DeLuca on 1/27/26.
//

import Foundation
import Combine
import AppKit
import os

class ServerManager: ObservableObject {
    @Published private(set) var servers: [Server] = []
    @Published private(set) var serverStats: [String: ServerStats] = [:]
    @Published private(set) var serverLogs: [String: [LogEntry]] = [:]
    @Published private(set) var commandErrorsByDirectory: [String: [CLIError]] = [:]
    @Published private(set) var lastRegistryRefreshAt: Date?

    private let registryURL: URL
    private let singleServerURL: URL
    private let vizzlyHomeURL: URL
    private var registryMonitor: FileMonitor?
    private var projectMonitors: [String: FileMonitor] = [:]
    private var logMonitors: [String: FileMonitor] = [:]
    private var workingDirectoryCache: [Int: String] = [:]
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "dev.vizzly.menubar", category: "ServerManager")

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        vizzlyHomeURL = home.appendingPathComponent(".vizzly")
        registryURL = vizzlyHomeURL.appendingPathComponent("servers.json")
        singleServerURL = vizzlyHomeURL.appendingPathComponent("server.json")

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
        lastRegistryRefreshAt = Date()
        let previousServerIds = Set(servers.map { $0.id })
        var loadedServers: [Server] = []

        if let registryServers = loadMultiServerRegistry() {
            loadedServers.append(contentsOf: registryServers)
        }

        if let singleServer = loadSingleServerRegistry() {
            if !loadedServers.contains(where: { $0.pid == singleServer.pid && $0.port == singleServer.port }) {
                loadedServers.append(singleServer)
            }
        }

        let liveServers = loadedServers.filter { isProcessAlive(pid: $0.pid) }
        servers = liveServers
        let livePids = Set(liveServers.map { $0.pid })
        workingDirectoryCache = workingDirectoryCache.filter { livePids.contains($0.key) }

        for server in liveServers {
            if let stats = server.stats {
                serverStats[server.id] = stats
            }
        }

        let currentServerIds = Set(liveServers.map { $0.id })
        cleanupProjectMonitors(for: currentServerIds)
        setupProjectMonitors(for: liveServers, previousIds: previousServerIds)
    }

    private func loadMultiServerRegistry() -> [Server]? {
        guard FileManager.default.fileExists(atPath: registryURL.path) else {
            return nil
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
                let basicFormatter = ISO8601DateFormatter()
                if let date = basicFormatter.date(from: dateString) {
                    return date
                }
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(dateString)")
            }
            let registry = try decoder.decode(ServerRegistry.self, from: data)
            return registry.servers
        } catch {
            logger.error("Failed to load servers.json: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func loadSingleServerRegistry() -> Server? {
        guard FileManager.default.fileExists(atPath: singleServerURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: singleServerURL)
            let payload = try JSONDecoder().decode(SingleServerRegistry.self, from: data)
            let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
            let directory = resolveWorkingDirectory(for: payload.pid) ?? homeDirectory
            let name = projectDisplayName(for: directory)
            return payload.asServer(directory: directory, name: name)
        } catch {
            logger.error("Failed to load server.json: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func isProcessAlive(pid: Int) -> Bool {
        errno = 0
        if kill(Int32(pid), 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private func resolveWorkingDirectory(for pid: Int) -> String? {
        if let cached = workingDirectoryCache[pid] {
            return cached
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            let directory = output
                .split(separator: "\n")
                .first(where: { $0.hasPrefix("n/") })
                .map { String($0.dropFirst()) }

            if let directory {
                let standardized = URL(fileURLWithPath: directory).standardizedFileURL.path
                workingDirectoryCache[pid] = standardized
                return standardized
            }

            return nil
        } catch {
            return nil
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
        cleanupCommandErrors(for: currentIds)
    }

    private func cleanupCommandErrors(for currentIds: Set<String>) {
        let currentDirectories = Set(
            servers
                .filter { currentIds.contains($0.id) }
                .map { URL(fileURLWithPath: $0.directory).standardizedFileURL.path }
        )
        commandErrorsByDirectory = commandErrorsByDirectory.filter { currentDirectories.contains($0.key) }
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
            logger.error("Failed to load report data for \(server.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Log Reading

    private func loadRecentLogs(for server: Server, lineCount: Int = 100) {
        guard let logURL = server.logFileURL else {
            logger.debug("No log file URL for \(server.name, privacy: .public)")
            return
        }

        guard FileManager.default.fileExists(atPath: logURL.path) else {
            logger.debug("Log file not found: \(logURL.path, privacy: .public)")
            return
        }

        do {
            let content = try String(contentsOf: logURL, encoding: .utf8)
            let rawLines = content.components(separatedBy: .newlines)
            let entries = rawLines.suffix(lineCount).compactMap { LogEntry.parse($0) }

            serverLogs[server.id] = entries
        } catch {
            logger.error("Failed to load logs for \(server.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
            let error = CLIError(message: "Failed to stop server", detail: detail)
            lastError = error
            appendCommandError(error, directory: server.directoryURL)
        }

        loadRegistry()
    }

    func startServer(in directory: URL) async {
        let result = await runCLICommand(["tdd", "start"], in: directory)

        if !result.success {
            let detail = [result.error, result.output]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let error = CLIError(message: "Failed to start server", detail: detail)
            lastError = error
            appendCommandError(error, directory: directory)
        }

        loadRegistry()
    }

    func clearError() {
        lastError = nil
    }

    func commandErrors(for server: Server) -> [CLIError] {
        let key = URL(fileURLWithPath: server.directory).standardizedFileURL.path
        return commandErrorsByDirectory[key] ?? []
    }

    func clearCommandErrors(for server: Server) {
        let key = URL(fileURLWithPath: server.directory).standardizedFileURL.path
        commandErrorsByDirectory.removeValue(forKey: key)
    }

    private func appendCommandError(_ error: CLIError, directory: URL) {
        let key = directory.standardizedFileURL.path
        var current = commandErrorsByDirectory[key] ?? []
        current.append(error)
        commandErrorsByDirectory[key] = Array(current.suffix(20))
    }

    // MARK: - CLI Path Configuration

    /// Config structure for reading userPath from config.json
    private struct GlobalConfig: Codable {
        let userPath: String?
        let runtime: Runtime?
        let projects: [String: Project]?

        struct Runtime: Codable {
            let npxPath: String?
        }

        struct Project: Codable {
            let projectName: String?
        }
    }

    private enum CLIConfigurationIssue {
        case missingConfig
        case missingUserPath
        case missingNpxPath

        var message: String {
            switch self {
            case .missingConfig:
                return "Missing ~/.vizzly/config.json. Run `vizzly --help` in Terminal first."
            case .missingUserPath:
                return "Missing `userPath` in ~/.vizzly/config.json."
            case .missingNpxPath:
                return "Missing `runtime.npxPath` in ~/.vizzly/config.json."
            }
        }
    }

    private func loadGlobalConfig() -> GlobalConfig? {
        let configURL = vizzlyHomeURL.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: configURL)
            return try JSONDecoder().decode(GlobalConfig.self, from: data)
        } catch {
            return nil
        }
    }

    private func currentCLIConfigurationIssue() -> CLIConfigurationIssue? {
        guard let config = loadGlobalConfig() else {
            return .missingConfig
        }
        guard let userPath = config.userPath, !userPath.isEmpty else {
            return .missingUserPath
        }
        guard let npxPath = config.runtime?.npxPath, !npxPath.isEmpty else {
            return .missingNpxPath
        }
        return nil
    }

    var cliConfigurationIssueMessage: String? {
        currentCLIConfigurationIssue()?.message
    }

    func openCLIConfigInFinder() {
        let configURL = vizzlyHomeURL.appendingPathComponent("config.json")
        if FileManager.default.fileExists(atPath: configURL.path) {
            NSWorkspace.shared.selectFile(configURL.path, inFileViewerRootedAtPath: vizzlyHomeURL.path)
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: vizzlyHomeURL.path)
        }
    }

    /// Run a CLI command using the stored user PATH
    private func runCLICommand(_ args: [String], in directory: URL) async -> (success: Bool, output: String, error: String) {
        guard let config = loadGlobalConfig() else {
            return (false, "", CLIConfigurationIssue.missingConfig.message)
        }

        guard let userPath = config.userPath, !userPath.isEmpty else {
            return (false, "", CLIConfigurationIssue.missingUserPath.message)
        }

        guard let npxPath = config.runtime?.npxPath, !npxPath.isEmpty else {
            return (false, "", CLIConfigurationIssue.missingNpxPath.message)
        }

        return await Task.detached(priority: .userInitiated) { [args, directory, userPath, npxPath] in
            let process = Process()
            let fileManager = FileManager.default
            let tempDir = fileManager.temporaryDirectory
            let stdoutURL = tempDir.appendingPathComponent("vizzly-menubar-\(UUID().uuidString)-stdout.log")
            let stderrURL = tempDir.appendingPathComponent("vizzly-menubar-\(UUID().uuidString)-stderr.log")

            _ = fileManager.createFile(atPath: stdoutURL.path, contents: nil)
            _ = fileManager.createFile(atPath: stderrURL.path, contents: nil)

            guard
                let stdoutHandle = try? FileHandle(forWritingTo: stdoutURL),
                let stderrHandle = try? FileHandle(forWritingTo: stderrURL)
            else {
                return (false, "", "Failed to prepare output capture for CLI command.")
            }

            process.executableURL = URL(fileURLWithPath: npxPath)
            process.arguments = ["vizzly"] + args
            process.currentDirectoryURL = directory
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle

            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = userPath
            process.environment = environment

            defer {
                try? stdoutHandle.close()
                try? stderrHandle.close()
                try? fileManager.removeItem(at: stdoutURL)
                try? fileManager.removeItem(at: stderrURL)
            }

            do {
                try process.run()
                process.waitUntilExit()

                let stdoutData = (try? Data(contentsOf: stdoutURL)) ?? Data()
                let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                return (process.terminationStatus == 0, stdout, stderr)
            } catch {
                return (false, "", error.localizedDescription)
            }
        }.value
    }

    private func projectDisplayName(for directory: String) -> String {
        let normalizedDirectory = URL(fileURLWithPath: directory).standardizedFileURL.path
        if let projects = loadGlobalConfig()?.projects {
            for (path, project) in projects {
                let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
                if normalizedPath == normalizedDirectory, let name = project.projectName, !name.isEmpty {
                    return name
                }
            }
        }
        return URL(fileURLWithPath: normalizedDirectory).lastPathComponent
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
        guard servers.allSatisfy({ serverStats[$0.id] != nil }) else { return false }
        return servers.allSatisfy { server in
            guard let stats = serverStats[server.id] else { return false }
            return stats.isHealthy
        }
    }

    /// Whether the CLI has been configured (user PATH exists in config)
    var isCLIConfigured: Bool {
        currentCLIConfigurationIssue() == nil
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
