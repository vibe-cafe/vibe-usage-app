# Vibe Usage

macOS menu bar app for tracking AI coding tool token usage. Syncs data to [vibecafe.ai/usage](https://vibecafe.ai/usage).

Replaces the manual `npx @vibe-cafe/vibe-usage sync` workflow with background polling every 5 minutes.

## Features

- Menu bar app — no Dock icon, runs in the background
- Auto-syncs usage data every 5 minutes via `@vibe-cafe/vibe-usage` CLI
- Dashboard popover with summary cards, stacked bar chart, and multi-category filters
- Time range selector: 1D / 7D / 30D
- Auto-start on login (via SMAppService)
- Manages CLI session hooks (removes on start, restores on quit)

## Requirements

- macOS 14 (Sonoma) or later
- [Node.js](https://nodejs.org) (v20+) or [Bun](https://bun.sh)
- API Key from [vibecafe.ai/usage/setup](https://vibecafe.ai/usage/setup)

## Build

```bash
# Clone
git clone https://github.com/vibe-cafe/vibe-usage-app.git
cd vibe-usage-app

# Build (debug)
swift build

# Build (release)
swift build -c release

# Run
swift run
# or
.build/debug/VibeUsage
```

To open in Xcode:

```bash
open Package.swift
```

## Architecture

```
App (SwiftUI)
 ├─ reads ~/.vibe-usage/config.json (read-only)
 ├─ calls vibe-usage CLI for config writes (via CLIBridge)
 ├─ calls vibe-usage CLI for sync (via SyncEngine)
 └─ calls GET /api/usage directly for dashboard data (via APIClient)
```

The Mac app never writes to `config.json` directly. All config mutations go through the `@vibe-cafe/vibe-usage` CLI, which owns the config file format.

### Key modules

| Module | Purpose |
|--------|---------|
| `AppState` | `@Observable` global state, lifecycle, data fetching |
| `SyncEngine` | Shells out to `npx/bunx @vibe-cafe/vibe-usage sync` |
| `CLIBridge` | Shells out to `vibe-usage config set/get` for config writes |
| `APIClient` | HTTP client for `GET /api/usage` (Bearer auth with API Key) |
| `ConfigManager` | Read-only access to `~/.vibe-usage/config.json` |
| `HookManager` | Removes/restores CLI session hooks, writes PID marker |
| `SyncScheduler` | GCD timer for 5-minute polling interval |
| `RuntimeDetector` | Finds `bun` or `npx` in PATH and common install locations |

### Views

| View | Purpose |
|------|---------|
| `PopoverView` | Main dashboard (header, cards, filters, chart, footer) |
| `SummaryCardsView` | Cost, total/input/output/cached token cards |
| `FilterTagsView` | Multi-category tag filters (source, model, project, hostname) |
| `BarChartView` | Stacked daily bar chart with hover tooltips |
| `OnboardingView` | API Key + URL setup window |
| `SettingsView` | Config display/edit, auto-start toggle, reset |

## Local Development Testing

For testing the full stack locally without deploying to production:

### 1. Start the vibe-cafe web app

```bash
cd /path/to/vibe-cafe/apps/web
bun run dev
# Runs on http://localhost:3000
```

### 2. Get a test API Key

Open http://localhost:3000/usage/setup in your browser, sign in with your dev account, and generate an API key.

### 3. Configure the Mac app for local

Option A — via the app UI:

1. Run the Mac app: `swift run`
2. In the onboarding window, expand "高级设置"
3. Change API URL to `http://localhost:3000`
4. Paste your test API Key and click "开始使用"

Option B — via CLI:

```bash
# Point config at local server
npx @vibe-cafe/vibe-usage config set apiUrl http://localhost:3000

# Set your test API key
npx @vibe-cafe/vibe-usage config set apiKey vbu_your_test_key

# Verify
npx @vibe-cafe/vibe-usage config show
```

Then run the Mac app — it reads `~/.vibe-usage/config.json` on launch.

### 4. Verify

- Click the menu bar icon to open the popover
- The dashboard should load data from `localhost:3000`
- Click the refresh button (↻) to trigger a manual sync
- Check Settings (⚙) to confirm the API URL shows `http://localhost:3000`

### Switching back to production

```bash
npx @vibe-cafe/vibe-usage config set apiUrl https://vibecafe.ai
```

Or use "修改" in Settings → API URL.

## Config

Shared config at `~/.vibe-usage/config.json`:

```json
{
  "apiKey": "vbu_...",
  "apiUrl": "https://vibecafe.ai",
  "lastSync": "2025-01-01T00:00:00.000Z"
}
```

Both the Mac app and the `@vibe-cafe/vibe-usage` CLI read from this file. The CLI owns writes.

## Related

- [@vibe-cafe/vibe-usage](https://github.com/vibe-cafe/vibe-usage) — CLI for parsing and syncing usage data
- [vibecafe.ai/usage](https://vibecafe.ai/usage) — Web dashboard

## License

MIT
