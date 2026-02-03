//
//  VizzlyApp.swift
//  Vizzly
//
//  Created by Robert DeLuca on 1/27/26.
//

import ServiceManagement
import SwiftUI

// MARK: - Design Tokens

extension Color {
  static let vzBg = Color(red: 0.059, green: 0.090, blue: 0.165)
  static let vzSurface = Color(red: 0.118, green: 0.161, blue: 0.231)
  static let vzMuted = Color(red: 0.580, green: 0.639, blue: 0.722)
  static let vzAccent = Color(red: 0.961, green: 0.620, blue: 0.043)
  static let vzSuccess = Color(red: 0.063, green: 0.725, blue: 0.506)
  static let vzDanger = Color(red: 0.937, green: 0.267, blue: 0.267)
  static let vzInfo = Color(red: 0.231, green: 0.510, blue: 0.965)
}

// MARK: - App

@main
struct VizzlyApp: App {
  @StateObject private var serverManager = ServerManager()

  var body: some Scene {
    MenuBarExtra {
      PanelView(serverManager: serverManager)
    } label: {
      MenuBarLabel(serverManager: serverManager)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView()
    }

    WindowGroup(id: "logs", for: String.self) { $serverId in
      if let serverId, let server = serverManager.servers.first(where: { $0.id == serverId }) {
        LogsWindow(server: server, serverManager: serverManager)
      }
    }
    .windowResizability(.contentSize)
  }
}

// MARK: - Menu Bar Label

struct MenuBarLabel: View {
  @ObservedObject var serverManager: ServerManager

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: serverManager.servers.isEmpty ? "square.stack.3d.up" : "square.stack.3d.up.fill")
        .font(.system(size: 13))

      if let fails = failCount {
        Text("\(fails)")
          .font(.system(size: 9, weight: .bold, design: .rounded))
          .padding(.horizontal, 4)
          .padding(.vertical, 1)
          .background(Capsule().fill(Color.vzDanger))
          .foregroundStyle(.white)
      }
    }
    .foregroundStyle(tint)
  }

  private var tint: Color {
    if serverManager.servers.isEmpty { return .primary }
    if serverManager.hasFailures { return .vzDanger }
    if serverManager.allHealthy { return .vzSuccess }
    return .vzAccent
  }

  private var failCount: Int? {
    let n = serverManager.serverStats.values.reduce(0) { $0 + $1.failed }
    return n > 0 ? n : nil
  }
}

// MARK: - Panel

struct PanelView: View {
  @ObservedObject var serverManager: ServerManager

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header
      header
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)

      Divider().opacity(0.3)

      // Content
      content
        .padding(10)

      Divider().opacity(0.3)

      // Footer
      footer
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
    .frame(width: 280)
    .background(Color.vzBg)
    .preferredColorScheme(.dark)
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "square.stack.3d.up.fill")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Color.vzAccent)

      Text("Vizzly")
        .font(.system(size: 13, weight: .semibold))

      Spacer()

      if serverManager.hasRunningServers {
        statusBadge
      }
    }
  }

  private var statusBadge: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(serverManager.hasFailures ? Color.vzDanger : (serverManager.allHealthy ? Color.vzSuccess : Color.vzAccent))
        .frame(width: 6, height: 6)
      Text("\(serverManager.servers.count)")
        .font(.system(size: 10, weight: .medium, design: .rounded))
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(.white.opacity(0.08))
    .clipShape(Capsule())
  }

  // MARK: Content

  @ViewBuilder
  private var content: some View {
    if let error = serverManager.lastError {
      errorBanner(error)
    }

    if !serverManager.isCLIConfigured {
      emptyState(
        icon: "square.stack.3d.up.fill",
        title: "Setup Required",
        subtitle: "npx vizzly --help"
      )
    } else if serverManager.servers.isEmpty {
      emptyState(
        icon: "square.stack.3d.up",
        title: "No Servers",
        subtitle: "Click + to start"
      )
    } else {
      serverList
    }
  }

  private var serverList: some View {
    VStack(spacing: 6) {
      ForEach(serverManager.servers) { server in
        ServerRowView(
          server: server,
          stats: serverManager.serverStats[server.id],
          serverManager: serverManager
        )
      }
    }
  }

  private func emptyState(icon: String, title: String, subtitle: String) -> some View {
    VStack(spacing: 6) {
      Image(systemName: icon)
        .font(.system(size: 20, weight: .light))
        .foregroundStyle(Color.vzMuted.opacity(0.6))
      Text(title)
        .font(.system(size: 11, weight: .medium))
      Text(subtitle)
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Color.vzMuted)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 16)
  }

  private func errorBanner(_ error: CLIError) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(Color.vzDanger)
      Text(error.message)
        .font(.system(size: 10))
        .lineLimit(1)
      Spacer()
      Button { serverManager.clearError() } label: {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .medium))
      }
      .buttonStyle(.plain)
    }
    .padding(8)
    .background(Color.vzDanger.opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .padding(.bottom, 6)
  }

  // MARK: Footer

  private var footer: some View {
    HStack(spacing: 6) {
      Button { startServer() } label: {
        Image(systemName: "plus")
          .font(.system(size: 11, weight: .medium))
          .frame(width: 28, height: 24)
      }
      .buttonStyle(FooterButtonStyle())
      .disabled(!serverManager.isCLIConfigured)
      .help("Start Server")

      Spacer()

      SettingsLink {
        Image(systemName: "gearshape")
          .font(.system(size: 11, weight: .medium))
          .frame(width: 28, height: 24)
      }
      .buttonStyle(FooterButtonStyle())
      .help("Settings")

      Button { NSApp.terminate(nil) } label: {
        Image(systemName: "power")
          .font(.system(size: 11, weight: .medium))
          .frame(width: 28, height: 24)
      }
      .buttonStyle(FooterButtonStyle())
      .help("Quit")
    }
  }

  private func startServer() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Start"
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer")
    NSApp.activate(ignoringOtherApps: true)
    if panel.runModal() == .OK, let url = panel.url {
      Task { await serverManager.startServer(in: url) }
    }
  }
}

// MARK: - Footer Button Style

struct FooterButtonStyle: ButtonStyle {
  @State private var isHovered = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(isHovered ? Color.vzAccent : Color.vzMuted)
      .background(
        RoundedRectangle(cornerRadius: 5)
          .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
      )
      .onHover { isHovered = $0 }
  }
}

// MARK: - Server Row

struct ServerRowView: View {
  let server: Server
  let stats: ServerStats?
  @ObservedObject var serverManager: ServerManager
  @Environment(\.openWindow) private var openWindow
  @State private var isHovered = false

  var body: some View {
    Button { serverManager.openDashboard(server) } label: {
      HStack(alignment: .top, spacing: 8) {
        // Status - aligned to first line
        Circle()
          .fill(statusColor)
          .frame(width: 6, height: 6)
          .padding(.top, 4)

        // Name + metadata
        VStack(alignment: .leading, spacing: 2) {
          Text(server.displayName)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)

          HStack(spacing: 6) {
            Text("localhost:\(String(server.port))")
              .font(.system(size: 9, design: .monospaced))
              .foregroundStyle(Color.vzMuted)

            if let stats, stats.total > 0 {
              HStack(spacing: 2) {
                Image(systemName: stats.isHealthy ? "checkmark" : "xmark")
                  .font(.system(size: 7, weight: .bold))
                Text("\(stats.isHealthy ? stats.passed : stats.failed)")
                  .font(.system(size: 9, weight: .semibold, design: .rounded))
              }
              .foregroundStyle(stats.isHealthy ? Color.vzSuccess : Color.vzDanger)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        // Menu
        serverMenu
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(isHovered ? Color.white.opacity(0.06) : Color.white.opacity(0.02))
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
  }

  private var serverMenu: some View {
    Menu {
      Button { serverManager.openDashboard(server) } label: {
        Label("Open Dashboard", systemImage: "globe")
      }
      Divider()
      Button {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "logs", value: server.id)
      } label: {
        Label("View Logs", systemImage: "doc.text")
      }
      Button { serverManager.openInFinder(server) } label: {
        Label("Show in Finder", systemImage: "folder")
      }
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(server.dashboardURL.absoluteString, forType: .string)
      } label: {
        Label("Copy URL", systemImage: "link")
      }
      Divider()
      Button(role: .destructive) {
        Task { await serverManager.stopServer(server) }
      } label: {
        Label("Stop", systemImage: "stop.fill")
      }
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 9))
        .foregroundStyle(Color.vzMuted.opacity(isHovered ? 1 : 0.5))
        .frame(width: 16, height: 16)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .padding(.top, 4)
  }

  private var statusColor: Color {
    guard let stats else { return .vzAccent }
    if stats.hasFailures { return .vzDanger }
    if stats.isHealthy { return .vzSuccess }
    return .vzAccent
  }
}

// MARK: - Settings

struct SettingsView: View {
  var body: some View {
    TabView {
      GeneralTab()
        .tabItem { Label("General", systemImage: "gear") }
      AboutTab()
        .tabItem { Label("About", systemImage: "info.circle") }
    }
    .frame(width: 360, height: 180)
  }
}

struct GeneralTab: View {
  @AppStorage("launchAtLogin") private var launchAtLogin = false

  var body: some View {
    Form {
      Toggle("Launch at login", isOn: $launchAtLogin)
        .onChange(of: launchAtLogin) { _, on in
          try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }
    .formStyle(.grouped)
  }
}

struct AboutTab: View {
  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: "square.stack.3d.up.fill")
        .font(.system(size: 32))
        .foregroundStyle(Color.vzAccent)

      Text("Vizzly")
        .font(.system(size: 16, weight: .semibold))

      Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        Link("Website", destination: URL(string: "https://vizzly.dev")!)
        Link("Docs", destination: URL(string: "https://docs.vizzly.dev")!)
      }
      .font(.system(size: 11))
      .foregroundStyle(Color.vzAccent)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Logs Window

struct LogsWindow: View {
  let server: Server
  @ObservedObject var serverManager: ServerManager
  @State private var autoScroll = true

  private var logs: [LogEntry] { serverManager.serverLogs[server.id] ?? [] }

  var body: some View {
    VStack(spacing: 0) {
      // Toolbar
      HStack(spacing: 10) {
        Circle()
          .fill(statusColor)
          .frame(width: 6, height: 6)

        Text(server.displayName)
          .font(.system(size: 12, weight: .medium))

        Text(":\(String(server.port))")
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary)

        Spacer()

        Toggle(isOn: $autoScroll) {
          Image(systemName: "arrow.down.to.line")
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .tint(autoScroll ? .vzAccent : .secondary)

        Button { serverManager.refreshLogs(for: server) } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
      }
      .padding(10)
      .background(.bar)

      Divider()

      // Logs
      if logs.isEmpty {
        ContentUnavailableView("No Logs", systemImage: "text.alignleft", description: Text("Logs appear as requests are processed"))
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(logs) { entry in
                LogRow(entry: entry).id(entry.id)
              }
            }
            .padding(8)
          }
          .onChange(of: logs.count) {
            if autoScroll, let last = logs.last {
              withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
          }
        }
      }
    }
    .frame(minWidth: 400, minHeight: 250)
  }

  private var statusColor: Color {
    guard let stats = serverManager.serverStats[server.id] else { return .vzAccent }
    if stats.hasFailures { return .vzDanger }
    if stats.isHealthy { return .vzSuccess }
    return .vzAccent
  }
}

struct LogRow: View {
  let entry: LogEntry

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      if let ts = entry.timestamp {
        Text(ts, style: .time)
          .font(.system(size: 9, design: .monospaced))
          .foregroundStyle(.tertiary)
          .frame(width: 56, alignment: .trailing)
      }

      Image(systemName: entry.level.icon)
        .font(.system(size: 9))
        .foregroundStyle(levelColor)
        .frame(width: 12)

      Text(entry.message)
        .font(.system(size: 10))
        .textSelection(.enabled)
    }
    .padding(.vertical, 3)
  }

  private var levelColor: Color {
    switch entry.level {
    case .debug: return .secondary
    case .info: return .vzInfo
    case .warn: return .vzAccent
    case .error: return .vzDanger
    case .success: return .vzSuccess
    }
  }
}
