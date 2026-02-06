//
//  Server.swift
//  Vizzly
//
//  Created by Robert DeLuca on 1/27/26.
//

import Foundation

struct Server: Identifiable, Codable, Equatable {
    let id: String
    let port: Int
    let pid: Int
    let directory: String
    let startedAt: Date
    let configPath: String?
    let name: String
    let logFile: String?

    // Optionally embedded in registry for quick access
    let stats: ServerStats?

    var dashboardURL: URL {
        URL(string: "http://localhost:\(port)")!
    }

    var healthURL: URL {
        URL(string: "http://localhost:\(port)/health")!
    }

    var reportDataURL: URL {
        URL(string: "http://localhost:\(port)/api/report-data")!
    }

    var directoryURL: URL {
        URL(fileURLWithPath: directory)
    }

    var displayName: String {
        name.isEmpty ? URL(fileURLWithPath: directory).lastPathComponent : name
    }

    var logFileURL: URL? {
        if let logFile = logFile {
            return URL(fileURLWithPath: logFile)
        }
        // Default location
        return URL(fileURLWithPath: directory).appendingPathComponent(".vizzly/server.log")
    }

    // Custom coding to handle missing stats
    enum CodingKeys: String, CodingKey {
        case id, port, pid, directory, startedAt, configPath, name, logFile, stats
    }

    init(
        id: String,
        port: Int,
        pid: Int,
        directory: String,
        startedAt: Date,
        configPath: String?,
        name: String,
        logFile: String?,
        stats: ServerStats?
    ) {
        self.id = id
        self.port = port
        self.pid = pid
        self.directory = directory
        self.startedAt = startedAt
        self.configPath = configPath
        self.name = name
        self.logFile = logFile
        self.stats = stats
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        port = try container.decode(Int.self, forKey: .port)
        pid = try container.decode(Int.self, forKey: .pid)
        directory = try container.decode(String.self, forKey: .directory)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        configPath = try container.decodeIfPresent(String.self, forKey: .configPath)
        name = try container.decode(String.self, forKey: .name)
        logFile = try container.decodeIfPresent(String.self, forKey: .logFile)
        stats = try container.decodeIfPresent(ServerStats.self, forKey: .stats)
    }
}

struct ServerRegistry: Codable {
    let version: Int
    let servers: [Server]

    static let empty = ServerRegistry(version: 1, servers: [])
}

struct SingleServerRegistry: Decodable {
    let pid: Int
    let port: Int
    let startTimeMs: Double?

    enum CodingKeys: String, CodingKey {
        case pid, port, startTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = try container.decode(Int.self, forKey: .pid)

        if let intPort = try? container.decode(Int.self, forKey: .port) {
            port = intPort
        } else if let stringPort = try? container.decode(String.self, forKey: .port), let parsed = Int(stringPort) {
            port = parsed
        } else {
            throw DecodingError.dataCorruptedError(forKey: .port, in: container, debugDescription: "Expected int or string for port")
        }

        if let millis = try? container.decode(Double.self, forKey: .startTime) {
            startTimeMs = millis
        } else if let intMillis = try? container.decode(Int.self, forKey: .startTime) {
            startTimeMs = Double(intMillis)
        } else {
            startTimeMs = nil
        }
    }

    func asServer(directory: String, name: String) -> Server {
        let seconds = (startTimeMs ?? Date().timeIntervalSince1970 * 1000) / 1000
        return Server(
            id: "single-\(pid)-\(port)",
            port: port,
            pid: pid,
            directory: directory,
            startedAt: Date(timeIntervalSince1970: seconds),
            configPath: nil,
            name: name,
            logFile: nil,
            stats: nil
        )
    }
}

struct ServerStats: Codable, Equatable {
    let total: Int
    let passed: Int
    let failed: Int
    let errors: Int
    let updatedAt: Date?

    var isHealthy: Bool { failed == 0 && errors == 0 }
    var hasFailures: Bool { failed > 0 }

    var summary: String {
        if total == 0 {
            return "No tests"
        }
        if isHealthy {
            return "✓ \(passed)/\(total)"
        }
        return "✗ \(failed) failed"
    }

    static let empty = ServerStats(total: 0, passed: 0, failed: 0, errors: 0, updatedAt: nil)

    enum CodingKeys: String, CodingKey {
        case total, passed, failed, errors, updatedAt
    }

    init(total: Int, passed: Int, failed: Int, errors: Int, updatedAt: Date? = nil) {
        self.total = total
        self.passed = passed
        self.failed = failed
        self.errors = errors
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try container.decode(Int.self, forKey: .total)
        passed = try container.decode(Int.self, forKey: .passed)
        failed = try container.decode(Int.self, forKey: .failed)
        errors = try container.decode(Int.self, forKey: .errors)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

struct HealthResponse: Codable {
    let status: String
    let port: Int
    let uptime: Double
    let mode: String
}

struct ReportData: Codable {
    let timestamp: Int?
    let summary: ReportSummary?

    struct ReportSummary: Codable {
        let total: Int
        let passed: Int
        let failed: Int
        let errors: Int
    }

    var stats: ServerStats {
        guard let summary = summary else {
            return .empty
        }
        return ServerStats(
            total: summary.total,
            passed: summary.passed,
            failed: summary.failed,
            errors: summary.errors
        )
    }
}

struct AuthStatus: Codable {
    let authenticated: Bool
    let user: AuthUser?

    struct AuthUser: Codable {
        let email: String
        let name: String?
    }
}

// MARK: - CLI Error

struct CLIError: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let detail: String
    let timestamp = Date()

    var displayDetail: String {
        // Clean up common error patterns
        detail
            .replacingOccurrences(of: "zsh:1: ", with: "")
            .replacingOccurrences(of: "bash: ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Log Entry

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date?
    let level: LogLevel
    let message: String
    let details: String?

    enum LogLevel: String {
        case debug, info, warn, error
        case success

        var icon: String {
            switch self {
            case .debug: return "ant"
            case .info: return "info.circle"
            case .warn: return "exclamationmark.triangle"
            case .error: return "xmark.circle"
            case .success: return "checkmark.circle"
            }
        }
    }

    init(timestamp: Date?, level: LogLevel, message: String, details: String? = nil) {
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.details = details
    }

    /// Parse CLI event-based JSON logs
    static func parse(_ line: String) -> LogEntry? {
        guard !line.isEmpty else { return nil }

        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Plain text fallback
            return LogEntry(timestamp: nil, level: .info, message: line)
        }

        // Parse timestamp
        var timestamp: Date?
        if let ts = json["timestamp"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            timestamp = formatter.date(from: ts)
            if timestamp == nil {
                // Try without fractional seconds
                formatter.formatOptions = [.withInternetDateTime]
                timestamp = formatter.date(from: ts)
            }
        }

        // Handle different event types from CLI
        if json["session_start"] as? Bool == true {
            let nodeVersion = json["node_version"] as? String ?? "unknown"
            let platform = json["platform"] as? String ?? "unknown"
            return LogEntry(
                timestamp: timestamp,
                level: .info,
                message: "Server started",
                details: "Node \(nodeVersion) on \(platform)"
            )
        }

        if let screenshot = json["screenshot"] as? String {
            let status = json["status"] as? String ?? "processed"
            let level: LogLevel = status == "failed" ? .error : (status == "passed" ? .success : .info)
            let diffPct = json["diffPercentage"] as? Double
            var details: String?
            if let diff = diffPct, diff > 0 {
                details = String(format: "%.1f%% diff", diff)
            }
            return LogEntry(
                timestamp: timestamp,
                level: level,
                message: "\(screenshot)",
                details: details
            )
        }

        if let event = json["event"] as? String {
            let level: LogLevel = event.contains("error") ? .error : .info
            return LogEntry(timestamp: timestamp, level: level, message: event)
        }

        // Standard winston format with level/message
        if let message = json["message"] as? String {
            let levelStr = json["level"] as? String ?? "info"
            let level = LogLevel(rawValue: levelStr) ?? .info
            return LogEntry(timestamp: timestamp, level: level, message: message)
        }

        // Unknown JSON structure - show key summary
        let keys = json.keys.filter { $0 != "timestamp" }.sorted().joined(separator: ", ")
        return LogEntry(timestamp: timestamp, level: .debug, message: keys.isEmpty ? "Event" : keys)
    }
}
