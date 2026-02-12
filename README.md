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

Download the latest release from [GitHub Releases](https://github.com/vizzly-testing/menubar/releases).

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
git clone https://github.com/vizzly-testing/menubar.git
cd menubar

# Open in Xcode
open Vizzly/Vizzly.xcodeproj
```

## How It Works

The menubar app watches `~/.vizzly/servers.json` for running TDD servers and monitors project/log files for live updates. It spawns CLI commands for server lifecycle management.

## Sparkle Updates

Vizzly uses [Sparkle](https://sparkle-project.org/) for in-app updates.

### One-time setup

1. Generate Sparkle keys locally (`generate_keys` from Sparkle tools).
2. Add `SUPublicEDKey` in the Vizzly app target build settings (Info.plist key).
3. Add a GitHub Actions secret named `SPARKLE_PRIVATE_KEY` with the full private key contents.
4. Add a GitHub Actions secret named `HOMEBREW_TAP_GITHUB_TOKEN` with repo write access to `vizzly-testing/homebrew-tap`.

### Release flow (manual binary, automated appcast)

1. Build/sign/notarize `Vizzly.app` locally.
2. Zip the signed app (for example `Vizzly-1.0.0.zip`).
3. Create/publish a GitHub release with a tag (for example `v1.0.0`).
4. Upload the signed `.zip` asset to that release.
5. GitHub Actions workflow `.github/workflows/update-appcast.yml` will:
   - pick the most recently updated `.zip` asset in that release
   - generate and sign `appcast.xml`
   - upload `appcast.xml` to the same release
   - update `vizzly-testing/homebrew-tap/Casks/vizzly.rb` with the release version + SHA256

Sparkle feed URL in the app points to:

`https://github.com/vizzly-testing/menubar/releases/latest/download/appcast.xml`

See [PLAN.md](./PLAN.md) for detailed architecture documentation.

## License

MIT
