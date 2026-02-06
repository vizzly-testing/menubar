# Vizzly Menubar

A native macOS menubar app for managing [Vizzly](https://vizzly.dev) TDD servers.

## Features

- See all running TDD servers at a glance
- Quick stats (passed/failed tests) per server
- One-click access to dashboards
- Start/stop servers without terminal
- Notifications on test completion

## Installation

### Direct Download

Download the latest release from [GitHub Releases](https://github.com/vizzly-testing/vizzly-menubar/releases).

### Homebrew

```bash
brew install --cask vizzly
```

## Requirements

- macOS 15.7 or later
- [Vizzly CLI](https://github.com/vizzly-testing/cli) installed (`npm install -g @vizzly-testing/cli`)

## Development

```bash
# Clone the repo
git clone https://github.com/vizzly-testing/vizzly-menubar.git
cd vizzly-menubar

# Open in Xcode
open Vizzly.xcodeproj
```

## How It Works

The menubar app watches `~/.vizzly/servers.json` for running TDD servers and monitors project/log files for live updates. It spawns CLI commands for server lifecycle management.

See [PLAN.md](./PLAN.md) for detailed architecture documentation.

## License

MIT
