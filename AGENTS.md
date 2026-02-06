# Repository Guidelines

## Project Structure & Module Organization
This repo is a native macOS menu bar app built with SwiftUI.

- `Vizzly/Vizzly/`: app source code
  - `VizzlyApp.swift`: app entry, menu bar UI, settings, logs window
  - `Services/ServerManager.swift`: registry watching, CLI process execution, server state
  - `Models/Server.swift`: shared models and log parsing
  - `Assets.xcassets/`: app icons and image assets
- `Vizzly/VizzlyTests/`: unit tests (Swift `Testing` framework)
- `Vizzly/VizzlyUITests/`: UI tests (`XCTest`)
- `Vizzly/Vizzly.xcodeproj/`: Xcode project and build settings

## Build, Test, and Development Commands
Run from repo root.

- `open Vizzly/Vizzly.xcodeproj`: open project in Xcode.
- `xcodebuild -project Vizzly/Vizzly.xcodeproj -scheme Vizzly -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`: unsigned local/CI build check.
- `xcodebuild -project Vizzly/Vizzly.xcodeproj -scheme Vizzly -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test -only-testing:VizzlyTests`: run unit tests.
- `xcodebuild -project Vizzly/Vizzly.xcodeproj -scheme Vizzly -destination 'platform=macOS' test`: run full test suite (requires local test runner permissions).

## Coding Style & Naming Conventions
- Follow Swift conventions: 4-space indentation, `UpperCamelCase` for types, `lowerCamelCase` for methods/properties.
- Prefer clear, functional logic and explicit state transitions over side-effect-heavy flows.
- Keep UI state updates on main actor paths; run blocking process/file work off main thread.
- Use structured logging (`Logger`) instead of `print`.

## Testing Guidelines
- Unit tests use `import Testing` with `@Test` and `#expect(...)`.
- UI tests use `XCTest` and should validate user-visible behavior.
- Prioritize outcome-based tests (e.g., parsed log level/details, server status behavior), not implementation details.
- Add tests for any non-trivial parsing, state derivation, or CLI behavior changes.

## Commit & Pull Request Guidelines
- Commit subjects must start with a gitmoji (for example: `🛠️`, `🐛`, `🧪`, `🧹`) and be action-oriented.
- Keep commits focused; include a short body for non-trivial changes.
- PRs should include:
  - what changed and why
  - how it was tested (exact commands)
  - screenshots/GIFs for menu bar or window UI changes
  - related issue/ticket references when available
