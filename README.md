# Spool

Spool is a macOS menu bar app for recording conversations, generating transcripts, and writing post-call Markdown summaries to a folder you control.

It is designed for people who want a lightweight native app instead of a meeting bot, cloud dashboard, or locked-in note system.

## What It Does

- Lives in the macOS menu bar with no Dock icon
- Captures microphone and system audio
- Produces transcript artifacts for each session
- Generates a Markdown post-call summary with OpenAI
- Writes everything into a user-selected output directory

## Output Format

Each session is written into its own folder under your chosen output root:

```text
Calls/
  2026-03-17_21-14-01_customer-kickoff/
    events.jsonl
    logs.txt
    session.json
    transcript.raw.txt
    transcript.txt
    2026-03-17_customer-kickoff.md
```

Spool tries to derive a useful session title from the transcript and summary so filenames are descriptive rather than generic.

## Current Status

This repo is usable, but still early.

Working now:

- menu bar-only app shell
- configurable output folder
- Keychain-backed OpenAI API key storage
- microphone and system audio capture
- transcript artifact generation
- OpenAI summary generation with `gpt-5-nano`
- installable app bundle via build script

Still rough:

- global hotkeys are intentionally disabled for now
- error handling is improving, but not fully polished
- summary quality depends on transcript quality
- signing, notarization, and release packaging are not finished

## Requirements

- macOS 15+
- Xcode 16+ command line tools
- an OpenAI API key

Spool currently depends on:

- [FluidAudio](https://github.com/FluidInference/FluidAudio)

## Build

Debug build:

```bash
swift build
```

Build and install to `/Applications/Spool.app`:

```bash
bash scripts/build_swift_app.sh
```

Launch the installed app:

```bash
open /Applications/Spool.app
```

## First Run

On first launch, Spool will ask you to finish setup in Settings:

1. Choose an output folder.
2. Paste your OpenAI API key.
3. Grant microphone permission.
4. Grant system audio recording permission.

The API key is stored in macOS Keychain, not in a checked-in config file.

## How It Works

- `MicCapture` records your microphone input.
- `SystemAudioCapture` records system audio for the remote side of a call.
- `StreamingTranscriber` and `TranscriptionEngine` turn audio into transcript events.
- `OpenAISummaryService` generates the Markdown summary.
- `SessionStorage` owns folder creation, transcript files, logs, and session metadata.

## Repository Layout

```text
Sources/Spool/App/             App lifecycle and menu bar shell
Sources/Spool/Audio/           Microphone and system audio capture
Sources/Spool/Transcription/   Transcription pipeline
Sources/Spool/Summary/         OpenAI summary integration
Sources/Spool/Services/        Recording lifecycle and session storage
Sources/Spool/Models/          Settings and session models
Sources/Spool/Views/           Settings UI
scripts/                       Build and install scripts
```

## Privacy Model

Spool is built around user-owned local artifacts:

- transcripts are written to your chosen folder
- summaries are written as Markdown files
- the OpenAI API key is stored in Keychain

Audio and transcript content will be sent to OpenAI for summary generation when summarization is enabled.

## Contributing

This project is still moving quickly. If you want to contribute:

- keep changes native and macOS-first
- prefer small, reviewable patches
- avoid adding heavy dependencies unless they materially improve the capture or transcript pipeline
- preserve the install flow in `scripts/build_swift_app.sh`

See [AGENTS.md](AGENTS.md) for repo-specific guidance for coding agents and contributors.
