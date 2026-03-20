# Spool Specification

## Overview

Spool is a native macOS menu bar app for recording conversations, generating transcripts, and writing post-call Markdown summaries into a user-owned folder structure.

The product should feel like a small, serious utility:

- always available
- low-friction
- native to macOS
- explicit about where files go
- reliable under permissions and network failure

This document is intended to be detailed enough that a developer or coding agent could implement the product from scratch.

## Product Goals

Spool exists to solve one core workflow:

1. A user starts a recording from the menu bar.
2. Spool captures microphone and system audio.
3. Spool produces transcript artifacts during and after the session.
4. Spool generates a structured Markdown summary after the session ends.
5. Spool stores everything in a predictable folder chosen by the user.

## Non-Goals

Spool is not a live meeting copilot.

Do not build any of these into V1:

- live suggestion overlays
- knowledge base or document search
- transcript editing workspace
- cloud sync product
- collaboration or multi-user features
- CRM integrations
- web dashboard

## Product Shape

- macOS app
- menu bar-only by default
- no Dock icon during normal use
- settings window for configuration
- no mandatory home screen
- local transcript artifacts plus cloud summary generation

## Core User Experience

### Happy Path

1. User launches Spool.
2. Spool lives in the menu bar.
3. If setup is incomplete, Spool opens Settings.
4. User chooses an output directory and enters an OpenAI API key.
5. User grants microphone and system audio recording permissions.
6. User starts recording from the menu.
7. Spool writes transcript artifacts while recording.
8. User stops recording.
9. Spool finalizes transcript output.
10. Spool sends transcript text to OpenAI for summarization.
11. Spool writes a Markdown summary and renames the session folder using the best title available.
12. User can open the latest summary or session folder from the menu.

### UX Principles

- Menu bar state must always reflect actual recording state.
- Errors should be specific and actionable.
- Transcript artifacts must survive summary failures.
- Folder names should be descriptive, not generic.
- The app should not jitter, resize, or visually disappear during state changes.

## Functional Requirements

### FR1: Launch Behavior

- The app launches as a menu bar utility.
- The app should use `LSUIElement = true`.
- The app should not show a Dock icon during normal operation.
- On launch, Spool should warm up permission state and validate required setup.
- If required setup is missing, Settings should open automatically.

### FR2: Menu Bar Shell

The status item must expose:

- `Start Recording`
- `Stop Recording` when active
- status line
- current session path line when relevant
- `Open Latest Summary`
- `Open Latest Session Folder`
- `Open Output Folder`
- `Settings`
- `Quit`

Menu items must not advertise keyboard shortcuts unless those shortcuts are actually implemented and reliable.

### FR3: Recording Lifecycle

Spool must maintain a recording state machine with at least these states:

- `idle`
- `checkingPermissions`
- `ready`
- `recording`
- `stopping`
- `finalizingTranscript`
- `summarizing`
- `completed`
- `failed`

Start flow:

1. Validate setup.
2. Validate required permissions.
3. Create session folder and metadata files.
4. Start microphone capture.
5. Start system audio capture.
6. Start transcription pipeline.
7. Update menu state.

Stop flow:

1. Stop audio capture.
2. Finalize transcript artifacts.
3. Mark session stopped in metadata.
4. Run summary generation.
5. Write summary artifact.
6. Rename session using best title available.
7. Update menu state and latest-session actions.

### FR4: Permissions

Spool must explicitly handle:

- microphone access
- system audio recording access

Permission checks should happen:

- on app launch
- when the app becomes active
- before recording starts

If permissions are missing:

- the menu should explain what is missing
- the user should be directed to fix permissions
- the app should not leave a half-created session behind

### FR5: Audio Capture

Spool should capture:

- microphone audio for the local speaker
- system audio for the remote side of a call

Implementation guidance:

- microphone capture can use standard Core Audio / AVFoundation capture
- system audio should use Core Audio process taps
- avoid a `ScreenCaptureKit`-driven implementation if the goal is system audio capture rather than screen recording

The privacy indicator shown by macOS is acceptable and expected.

### FR6: Transcription

Spool should transcribe during the recording session and accumulate incremental transcript artifacts.

Required transcript outputs:

- incremental utterance events
- raw transcript text
- finalized plain text transcript

Recommended behavior:

- local transcription by default
- chunked processing for long recordings
- simple speaker split between local mic and remote/system audio

V1 speaker assumptions:

- mic audio maps to `You`
- system audio maps to `Them`
- remote multi-speaker diarization is out of scope

### FR7: Summary Generation

Summary generation runs after recording stops and transcript finalization completes.

Current provider requirement:

- OpenAI only

Current default model:

- `gpt-5-nano`

Summary requirements:

- output must be Markdown
- include structured sections
- include frontmatter
- avoid generic titles like `Untitled Call`
- derive the best available title from summary content, then transcript content, then fallback naming

If summary generation fails:

- transcript artifacts must still be preserved
- session metadata must record the failure
- `logs.txt` must contain the specific error
- the menu should show a short, human-readable failure message

### FR8: Output Directory

The user chooses a root output directory in Settings.

Spool writes one folder per session directly under that root using:

```text
YYYY-MM-DD_HH-mm-ss_slug
```

Example:

```text
2026-03-17_21-14-01_customer-kickoff
```

The folder should contain:

- `session.json`
- `events.jsonl`
- `logs.txt`
- `transcript.raw.txt`
- `transcript.txt`
- `YYYY-MM-DD_slug.md`

### FR9: Session Naming

Initial session creation may use a fallback slug such as `untitled-call`.

After transcript finalization and summary generation, Spool should rename the folder and summary file using the best title available.

Title selection priority:

1. parsed summary frontmatter title
2. parsed summary H1
3. transcript-derived title heuristic
4. fallback `Untitled Call`

Generic titles should be normalized away when the transcript contains enough context to infer a better one.

### FR10: Settings

Required settings:

- output root directory
- summary provider
- summary model
- summary base URL
- OpenAI API key

Current behavior requirements:

- provider defaults to `OpenAI`
- model defaults to `gpt-5-nano`
- base URL defaults to `https://api.openai.com/v1`
- API key is stored in macOS Keychain

The app may support more providers later, but V1 public behavior should be optimized for OpenAI.

### FR11: Session Recovery

Spool should be able to detect interrupted sessions on startup.

Interrupted states include:

- `recording`
- `finalizingTranscript`
- `summarizing`

Recovery expectations:

- incomplete sessions remain inspectable on disk
- transcript artifacts are never discarded
- if summary is missing but transcript exists, a later recovery flow may offer `Finish Summary`

## Non-Functional Requirements

### Reliability

- summary failure must not destroy transcript outputs
- permission failure must not leave the app stuck in a false recording state
- failed starts must not leave stale session UI state behind

### Performance

- startup should feel fast
- menu bar interaction should feel instant
- app icon should remain stable during state transitions
- long sessions should not require full in-memory buffering of all raw audio

### Privacy

- user chooses the output directory
- API keys are stored in Keychain
- transcript content is sent to OpenAI only for summarization
- the app should be explicit that cloud summarization sends transcript text externally

### Transparency

- file layout should be easy to inspect in Finder
- failures should be visible in both UI and `logs.txt`
- settings should make provider configuration obvious

## Output Artifacts

### Session Folder Layout

```text
<output-root>/
  2026-03-17_21-14-01_customer-kickoff/
    session.json
    events.jsonl
    logs.txt
    transcript.raw.txt
    transcript.txt
    2026-03-17_customer-kickoff.md
```

### `session.json`

Suggested shape:

```json
{
  "session_id": "uuid",
  "title": "Customer Kickoff",
  "status": "completed",
  "started_at": "2026-03-17T21:14:01Z",
  "stopped_at": "2026-03-17T21:52:44Z",
  "output_root": "/Users/example/Calls",
  "paths": {
    "summary_markdown": "2026-03-17_customer-kickoff.md",
    "transcript": "transcript.txt",
    "raw_transcript": "transcript.raw.txt",
    "events": "events.jsonl",
    "logs": "logs.txt"
  },
  "summary": {
    "provider": "openAI",
    "model": "gpt-5-nano",
    "status": "completed"
  }
}
```

### `events.jsonl`

Suggested events:

```json
{"type":"session_started","timestamp":"2026-03-17T21:14:01Z"}
{"type":"utterance","timestamp":"2026-03-17T21:14:09Z","speaker":"You","text":"Thanks for making the time."}
{"type":"utterance","timestamp":"2026-03-17T21:14:12Z","speaker":"Them","text":"Happy to be here."}
{"type":"session_stopped","timestamp":"2026-03-17T21:52:44Z"}
{"type":"summary_completed","timestamp":"2026-03-17T21:53:11Z","path":"2026-03-17_customer-kickoff.md"}
```

### `transcript.raw.txt`

Append-only, low-level text output from the live transcription stream.

### `transcript.txt`

Human-readable finalized transcript.

Suggested shape:

```text
# Customer Kickoff

[21:14:09] You: Thanks for making the time.
[21:14:12] Them: Happy to be here.
```

### Summary Markdown

Suggested output:

```markdown
---
title: "Customer Kickoff"
session_start: 2026-03-17T21:14:01Z
date_of_call: 2026-03-17
participants:
  - You
  - Them
---

# Customer Kickoff

## Overview

Short narrative summary.

## Key Points

- Item

## Decisions

- Item

## Action Items

- Owner: follow up on pricing

## Open Questions

- Question

## Notable Quotes

- "Quote"
```

## Architecture

Spool should be organized into these top-level domains:

1. `AppShell`
2. `RecordingController`
3. `CapturePipeline`
4. `TranscriptionPipeline`
5. `SummaryPipeline`
6. `SessionStorage`

### AppShell

Responsibilities:

- app launch behavior
- menu bar status item
- menu updates
- settings window routing
- menu action wiring
- app activation policy

Recommended implementation:

- AppKit `NSStatusItem`
- AppKit `NSMenu`
- SwiftUI settings window

### RecordingController

Responsibilities:

- source of truth for app state
- orchestrates permissions, capture, transcription, summary, and storage
- exposes current session information to the menu
- converts lower-level failures into user-visible status

### CapturePipeline

Responsibilities:

- microphone capture lifecycle
- system audio capture lifecycle
- stream normalized audio chunks into transcription

### TranscriptionPipeline

Responsibilities:

- initialize ASR stack
- accept mic and system audio streams
- emit utterance events
- write transcript artifacts incrementally

### SummaryPipeline

Responsibilities:

- transform finalized transcript into structured Markdown
- validate summary output
- return title candidates
- write completion or failure results into storage

### SessionStorage

Responsibilities:

- create session folders
- write metadata files
- append utterance events
- append logs
- finalize transcript output
- rename sessions after title resolution
- recover interrupted sessions

## Current Implementation Guidance

Use these choices unless there is a strong reason to change them:

- Swift 6
- Swift Package Manager
- macOS 15 minimum
- menu bar shell in AppKit
- settings UI in SwiftUI
- OpenAI summary provider
- Keychain-backed API key storage
- `FluidAudio` as the starting point for transcription-related infrastructure

## Naming Heuristics

Summary titles should not default to generic labels if transcript content can support something better.

Recommended title heuristic:

1. Try YAML frontmatter title from summary.
2. Try summary H1.
3. Derive from first meaningful transcript line.
4. Remove generic prefixes such as:
   - `Post-Call Summary:`
   - `Summary:`
5. Normalize to title case.
6. Slugify for filesystem-safe names.

Transcript-derived titles should:

- strip speaker labels
- remove filler punctuation
- keep roughly 3 to 6 useful words
- avoid generic phrases like `test call`, `untitled call`, or `new thing` when there is stronger content later in the transcript

## Logging And Diagnostics

Every session folder should contain `logs.txt`.

At minimum, log:

- session creation
- permission failures
- capture startup failures
- utterance append failures
- transcript finalization failures
- summary request failures
- session rename failures

UI guidance:

- show a concise status in the menu
- keep full details in `logs.txt`
- avoid surfacing raw implementation jargon unless there is no better message

## Permissions Design

### Microphone

- request and validate microphone permission
- explain clearly why the app needs it

### System Audio

- request and validate system audio recording permission
- warm this up on launch so the user is not surprised at first record

### Accessibility

Not required in the current build because global hotkeys are not a priority.

Do not add accessibility requirements unless a real feature needs them.

## Build And Packaging

Build toolchain:

- Swift Package Manager
- custom shell script to package `.app`

Current packaging flow:

```bash
swift build
bash scripts/build_swift_app.sh
open /Applications/Spool.app
```

Requirements:

- keep the bundle install flow simple
- copy the app icon into the bundle
- preserve `Info.plist` and entitlements consistency
- keep `.build/` and `dist/` out of git

## Testing Strategy

### Manual Test Matrix

Test these flows:

- first launch with no settings
- missing API key
- missing output directory
- microphone permission denied
- system audio permission denied
- short successful recording
- long recording
- summary failure with transcript preserved
- app relaunch after interrupted session
- session rename after summary title improvement
- folder naming remains flat
- menu bar icon remains stable through all states

### Acceptance Criteria

Spool is acceptable when all of these are true:

- a user can launch it and understand setup without external documentation
- a user can record from the menu bar without a main window
- transcript artifacts are written to a predictable user-owned folder
- summary generation produces Markdown with a useful title
- summary failure does not destroy transcript output
- errors are diagnosable from both the menu and `logs.txt`

## Risks

### Risk 1: System Audio Capture Reliability

macOS system audio capture is sensitive to permissions and implementation details.

Mitigations:

- keep permission checks explicit
- prefer stable Core Audio tap-based implementation
- preserve mic-only fallback where possible

### Risk 2: Weak Title Generation

Summaries may still return generic titles.

Mitigations:

- strengthen prompt instructions
- prefer frontmatter parsing over raw H1 only
- keep transcript-derived title heuristics

### Risk 3: Summary Hallucination

LLM-generated summaries can invent details.

Mitigations:

- keep transcript accessible
- use structured prompts
- avoid overclaiming speaker attribution accuracy

### Risk 4: Startup And Permission Confusion

Users may think recording is broken when setup is incomplete.

Mitigations:

- validate setup on launch
- open Settings automatically when required
- make permission state visible in the menu

## Implementation Plan

### Phase 0: Repo Foundation

- create Swift package app structure
- wire menu bar shell
- add app icon, `Info.plist`, and entitlements
- add build script that installs to `/Applications`

### Phase 1: Settings And Setup

- output directory selection
- OpenAI settings
- Keychain-backed API key storage
- setup validation on launch

### Phase 2: Recording Shell

- recording controller state machine
- menu state wiring
- session creation
- session metadata persistence

### Phase 3: Capture And Transcription

- microphone capture
- system audio capture
- transcription pipeline
- transcript artifacts

### Phase 4: Summary Pipeline

- summary prompt
- OpenAI request path
- Markdown output
- title extraction and rename

### Phase 5: Recovery And Diagnostics

- interrupted session detection
- better logging
- cleaner error presentation
- startup permission hardening

### Phase 6: Release Hardening

- app signing
- notarization
- launch at login if desired
- optional hotkey work if it becomes important

## Final Recommendation

Build and maintain Spool as a focused native macOS recorder utility with:

- menu bar-first interaction
- transcript-first persistence
- OpenAI-powered post-call Markdown summaries
- explicit user-owned filesystem output

Favor reliability, transparency, and low UI overhead over feature breadth.
