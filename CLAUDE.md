# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Storyforge is an **AI-powered short video production tool** built with Flutter (primary target: Windows desktop). Users enter a creative prompt and the app orchestrates a pipeline of 5 AI agents to produce a 1-2 minute video:

```
Creative Input -> Planning -> Scripting -> Storyboarding -> Image Generation -> Video Generation -> Final Cut
```

A `DirectorAgent` reviews each stage's output with an LLM-based scoring loop and retries (up to 3x) if quality is insufficient.

## Key Commands

```bash
flutter pub get                          # Install dependencies
flutter run -d windows                   # Run on Windows desktop
flutter run -d <device>                  # Run on another platform
flutter build windows --release          # Build Windows release
flutter build apk --release              # Build release APK
dart analyze                             # Run static analysis
flutter test                             # Run all tests
flutter test test/widget_test.dart       # Run a single test
```

Windows build environment setup: `.\setup-windows-build-env.ps1`
Windows build script: `.\build-windows.ps1`

## Architecture

### Layered Structure

```
Screens (UI) -> Core (Agents/Business Logic) -> Services (External APIs) -> DB (Persistence)
                                            -> Models (Data)         -> DB (Persistence)
```

| Directory | Purpose |
|-----------|---------|
| `lib/config/` | API key/URL configuration via `shared_preferences` |
| `lib/core/` | Agent system: base `Agent`, concrete agents, `DirectorAgent` orchestrator |
| `lib/db/` | SQLite database (`AppDatabase`) + DAO layer (one class per table) |
| `lib/models/` | Data models: `Project`, `Brief`, `Script`, `Scene`, `Asset`, `Storyboard`, `VideoClip`, `FinalCut` |
| `lib/screens/` | 4 UI screens: `ProjectListScreen`, `CreateProjectScreen`, `ProjectDetailScreen`, `SettingsScreen` |
| `lib/services/` | `LlmService` (chat completions), `DashscopeService` (image/video gen), `AppLogger` |

### Agent Pattern

- `Agent` (abstract base in `lib/core/agent.dart`): defines `name`, `run(AgentContext)`, `review()`, `retry()`
- `AgentContext`: carries `projectId` and a `Map<String, dynamic>` data bag between stages
- `AgentResult<T>`: wraps success/failure with typed data
- `DirectorAgent` (`lib/core/director_agent.dart`): orchestrator that composes `PlanningAgent`, `ScriptAgent`, and `ProductionAgent`. Implements `runStageWithReview()` — generate, LLM-score (1-10), retry with feedback if score < 6, max 3 retries
- Workflow stages: `planning` -> `scripting` -> `asseting` -> `storyboarding` -> `generating` -> `cutting` -> `done`

### AI/LLM Integration

- **LLM**: `qwen3.6-plus` via `https://coding.dashscope.aliyuncs.com/v1` (OpenAI-compatible `/chat/completions`)
- **Image gen**: `wan2.7-image` via DashScope multimodal-generation (async, 5s polling, up to 120 polls)
- **Video gen**: `wan2.7-i2v` via DashScope video-synthesis (image-to-video, 720P, async polling)
- **HTTP proxy**: configurable via settings for enterprise networks

### Navigation & State Management

- **Navigation**: Manual `Navigator.push` / `Navigator.pushReplacement`. `MaterialApp` with hardcoded `home: HomeScreen` (bottom nav with Projects/Settings tabs).
- **State**: Screens use `setState`. No Riverpod providers are actively used in screens despite being a dependency.

### Database

- SQLite via `sqflite_common_ffi` (desktop FFI support, not mobile `sqflite`)
- 8 tables: projects, briefs, scripts, assets, storyboards, video_clips, final_cuts, tasks
- DAO layer: one class per table (`ProjectDao`, `BriefDao`, etc.) with CRUD methods
- DAOs instantiate `AppDatabase` directly — no dependency injection

## Important Notes

- **Unused dependencies**: `riverpod`/`flutter_riverpod` and `go_router` are declared in `pubspec.yaml` but not used in actual code. Don't assume they're wired up.
- **No dependency injection**: Services and DAOs are instantiated with `new` throughout.
- **Logging**: `AppLogger` writes to `%LOCALAPPDATA%\Storyforge\logs\storyforge.log` on Windows with structured text entries.
- **Dart SDK**: `^3.6.2`, Flutter 3.27+

## User Preferences

- **Language**: Always respond in Chinese (中文). This applies to all conversations, code explanations, and project discussions.
