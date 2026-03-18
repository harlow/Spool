# AGENTS

This file is for people and coding agents making changes in this repository.

## Product Shape

Spool is a native macOS menu bar app.

Core product constraints:

- menu bar-only by default
- no Dock icon during normal use
- transcript-first workflow
- Markdown summary output
- user-selected output directory
- OpenAI-backed summarization

Do not turn this into a web app, Electron app, or multi-platform abstraction project.

## Stack

- Swift Package Manager
- Swift 6
- AppKit menu bar shell with SwiftUI settings UI
- `FluidAudio` for transcription-related audio pipeline support

The app is packaged as a macOS app bundle by `scripts/build_swift_app.sh`, not by an Xcode project.

## Important Paths

- `Sources/Spool/App`
- `Sources/Spool/Audio`
- `Sources/Spool/Transcription`
- `Sources/Spool/Summary`
- `Sources/Spool/Services`
- `Sources/Spool/Views`
- `scripts/build_swift_app.sh`

## Build And Run

Compile:

```bash
swift build
```

Package and install:

```bash
bash scripts/build_swift_app.sh
```

Run:

```bash
open /Applications/Spool.app
```

The build script installs to `/Applications/Spool.app`. Do not quietly change that workflow without a strong reason.

## Repo Rules

- Keep `.build/`, `dist/`, and other local artifacts out of git.
- Do not commit API keys, Keychain exports, transcripts, or test call artifacts.
- Do not hard-code user-specific filesystem paths.
- Keep bundle identifiers, entitlements, and `Info.plist` aligned.
- Preserve the menu bar-only behavior unless there is an explicit product change.

## Permissions

This app depends on macOS privacy permissions.

Be careful when changing:

- microphone access
- system audio recording access
- startup permission checks
- menu state shown when permissions are missing

Small permission regressions can make the app feel broken even when the underlying pipeline still works.

## Settings And Secrets

- The OpenAI API key belongs in Keychain.
- Do not move API key storage into plist files, defaults, or checked-in config.
- If you add new provider settings, assume this repo may be public.

## Session Artifacts

Each recording session can generate:

- `session.json`
- `events.jsonl`
- `logs.txt`
- `transcript.raw.txt`
- `transcript.txt`
- a Markdown summary

Changes to session naming, folder naming, or summary naming should be made carefully because they affect the user’s filesystem organization.

## Summary Pipeline

Current default:

- provider: OpenAI
- model: `gpt-5-nano`

If you change prompts, naming heuristics, or summary parsing, verify:

- the summary still writes valid Markdown
- the title is not generic when the transcript has enough context
- session rename behavior still works

## Hotkeys

Global hotkeys are intentionally not a current priority.

- Do not reintroduce fake or non-functional shortcut labels.
- If you add real global hotkeys later, make sure they are actually wired and permission-safe.

## UI Guidance

- Keep the app visually quiet.
- Prefer stability over cleverness in the menu bar.
- Avoid status item jitter, resizing, or icon swaps that make the icon disappear.
- The menu should always reflect the real recording state.

## Before You Finish A Change

At minimum:

1. Run `swift build`.
2. If the change affects the shipped app, run `bash scripts/build_swift_app.sh`.
3. If the change affects runtime behavior, relaunch `/Applications/Spool.app`.
4. Check that you did not introduce user-specific paths, secrets, or generated artifacts into git.

## Good Next Steps

Safe areas to improve:

- summary prompt quality
- session naming quality
- error reporting and logs
- settings UX
- release packaging and signing

Areas to treat carefully:

- system audio capture
- permission startup flow
- status item lifecycle
- app bundle structure
