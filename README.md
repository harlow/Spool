# Spool

Spool is a macOS menu bar recorder-first meeting utility. It is being built as a native Swift app focused on:

- menu bar-first control
- transcript-first artifacts
- post-call Markdown summaries
- explicit user-owned output folders

## Current status

The repo currently includes the app shell and storage foundation:

- menu bar-only app lifecycle
- settings and onboarding windows
- persisted output and summary settings
- session folder and summary filename generation

Audio capture, transcription, summarization providers, and global hotkeys are the next implementation phases.

## Build

```bash
swift build
./scripts/build_swift_app.sh
```
