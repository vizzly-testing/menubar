# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## What is This?

Vizzly Menubar is a native macOS menubar app that manages Vizzly TDD servers. It's a companion to the `@vizzly-testing/cli` package, providing a persistent UI for server management without needing a terminal open.

**Key principle**: This is a *control plane* only. The React web reporter (served by the TDD server) is the primary UI for viewing comparisons and managing baselines.

## Tech Stack

- **Language**: Swift 5.9+
- **UI**: AppKit (NSMenu) + SwiftUI (Preferences)
- **Min macOS**: 13.0 (Ventura)
- **Build**: Xcode / xcodebuild

## Project Structure

```
vizzly-menubar/
├── Vizzly.xcodeproj
├── Sources/
│   ├── App/                    # App lifecycle
│   ├── Menu/                   # NSStatusItem, menu building
│   ├── Services/               # Business logic
│   ├── Models/                 # Data models
│   └── Views/                  # SwiftUI views
├── Resources/                  # Assets, localization
└── Tests/
```

## Communication with CLI

The app communicates with the Vizzly CLI via:

1. **File watching**: `~/.vizzly/servers.json` - registry of running servers
2. **DistributedNotification**: `dev.vizzly.serverChanged` - instant update signal
3. **HTTP polling**: Server health and stats endpoints
4. **Process spawning**: Runs `vizzly tdd start/stop` commands

## Development

```bash
# Open in Xcode
open Vizzly.xcodeproj

# Build from command line
xcodebuild -scheme Vizzly -configuration Debug build

# Run tests
xcodebuild -scheme Vizzly -configuration Debug test
```

## Related Repositories

- `vizzly-testing/cli` - The CLI that this app manages
- `vizzly-testing/vizzly` - The cloud platform

## Git Commits

Use gitmoji for commit messages. Keep commits clear and concise.

**NEVER add AI attribution to commits or PRs.**
