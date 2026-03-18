# Spool PRD And Build Plan

## Executive Summary

This document proposes a new macOS-native app focused on a simpler, recorder-first workflow than OpenGranola.

The target product is:

- A menu bar app
- With a global shortcut to start and stop recording
- That captures microphone audio and call/system audio
- Produces raw transcript artifacts during and after the call
- Produces a post-call Markdown summary using GPT, Claude, or a local model
- Stores all session artifacts in a directory chosen by the user

The core recommendation is:

- Start a new repo for the new product
- Reuse selected low-level audio and transcription components from this repo
- Do not try to pivot OpenGranola in place

OpenGranola is architected as a live copilot. The requested product is architected as a background recorder and post-call summarizer. Those are materially different products with different shell, lifecycle, data model, settings, and output semantics.

## Recommendation

### Decision

Build a new repo in Swift 6 using SwiftUI + AppKit, and selectively port:

- `MicCapture.swift`
- `SystemAudioCapture.swift`
- parts of `StreamingTranscriber.swift`
- parts of `TranscriptionEngine.swift`
- settings/keychain patterns from `AppSettings.swift`

Do not port as-is:

- `ContentView.swift`
- `OpenGranolaApp.swift`
- `OverlayPanel.swift`
- `SuggestionEngine.swift`
- `KnowledgeBase.swift`
- current session and UI models that are tied to live suggestions

### Why New Repo Is Better

OpenGranola is built around:

- a main window
- live transcript visibility
- live AI suggestions
- a knowledge base
- an overlay panel
- a conversation-assistance data model

The new app needs:

- a status item / menu bar shell
- a global hotkey
- mostly background operation
- explicit per-session output folders
- transcript-first persistence
- post-call summarization
- low-friction settings and onboarding

Trying to convert this repo in place would mean deleting or bypassing a large percentage of the current product. That is more expensive than transplanting the stable capture/transcription pieces into a new architecture.

## Product Vision

### Product Goal

Create the lightest possible Mac utility for recording conversations and turning them into usable artifacts.

The product should feel like:

- always available
- one shortcut away
- reliable under pressure
- low UI overhead
- explicit about where files go
- local-first in transcription when possible
- flexible in summarization provider

### Primary Use Case

A user is about to join a Zoom, Meet, Teams, Slack, or phone call on their Mac.

They press a global shortcut.

The app:

- starts a new session
- captures mic and system audio
- transcribes the call
- writes raw transcript artifacts as the call proceeds

When the user stops recording, the app:

- finalizes the transcript
- runs summarization
- writes a structured Markdown summary
- stores everything in the user’s chosen output directory
- gives the user a quick way to open the result

### Non-Goals For V1

- live in-call suggestions
- knowledge-base search
- floating overlay
- full speaker diarization across multiple remote participants
- editing the transcript inside the app
- cloud syncing
- collaboration features
- calendar integration

## Product Principles

### 1. Recorder First

Recording and transcript generation are the product center. Summarization is downstream of that core flow.

### 2. Background Native Utility

The app should not behave like a large desktop workspace. It should behave like a serious menu bar utility.

### 3. Explicit File Ownership

All outputs must land in a user-chosen folder structure that is easy to inspect in Finder and easy to use with Obsidian, Notes, plain Markdown, or downstream tooling.

### 4. Local-First Transcription

Prefer local transcription by default when feasible. Use external models only when the user chooses them.

### 5. Provider-Flexible Summarization

Users should be able to choose GPT, Claude, or local Ollama-compatible models for the summary stage.

### 6. Fast Recovery

If the app crashes or the machine reboots mid-session, artifacts should still be recoverable and incomplete sessions should be detectable.

## User Personas

### Persona A: Founder / Operator

Needs a reliable transcript and summary of investor, customer, or recruiting calls.

### Persona B: Researcher / Interviewer

Needs raw text plus a concise summary and decisions list.

### Persona C: Solo Power User

Needs an app that stays out of the way and drops Markdown files into a known folder.

## User Stories

- As a user, I want to start recording from a keyboard shortcut so I do not need to find a window first.
- As a user, I want the app to live in the menu bar so it is always available.
- As a user, I want the app to capture both my voice and the other side of the call.
- As a user, I want the transcript to be saved automatically even if I forget to export.
- As a user, I want the app to create a Markdown summary after the call ends.
- As a user, I want to choose where session files are stored.
- As a user, I want to open the latest session quickly from the menu bar.
- As a user, I want clear permission handling so I understand why recording fails.
- As a user, I want the app to survive interrupted sessions without losing everything.

## Product Scope

### V1 Includes

- menu bar app shell
- start/stop recording from menu and global shortcut
- mic capture
- system audio capture
- real-time transcript accumulation
- raw transcript persistence
- plain text transcript export
- Markdown summary generation after stop
- output directory selection
- model/provider configuration for summaries
- onboarding and permissions repair UI
- notification when summary is ready

### V1.5 Optional

- “mark moment” shortcut
- transcript preview window
- automatic title generation from meeting content
- launch at login
- optional raw audio capture
- template selection for summaries

### V2 Possible

- better speaker labeling
- post-call action item extraction with confidence
- calendar title inference
- optional CRM / note app export
- team sharing

## High-Level System Design

### Architecture Overview

The app should be split into six top-level domains:

1. `AppShell`
2. `RecordingController`
3. `CapturePipeline`
4. `TranscriptionPipeline`
5. `SummaryPipeline`
6. `SessionStorage`

### AppShell

Responsibilities:

- own process launch behavior
- create the menu bar status item
- manage the settings window
- manage onboarding and permission prompts
- expose menu actions
- drive Dock/menu bar presence rules

Implementation direction:

- use `NSStatusItem`
- use AppKit for status item, menu, app activation policy, and some lifecycle details
- use SwiftUI for settings and onboarding windows

Reasoning:

`NSStatusItem` gives tighter control than `MenuBarExtra` for a recorder utility. This matters if the app later needs nuanced state transitions, popovers, alternate-click behavior, custom icon tinting, or agent-style launch.

### RecordingController

Responsibilities:

- source of truth for session lifecycle
- coordinate permissions, capture, transcription, and summary flow
- drive menu state and notifications
- expose observable app state to the UI

Suggested states:

- `idle`
- `checkingPermissions`
- `ready`
- `recording`
- `stopping`
- `finalizingTranscript`
- `summarizing`
- `completed`
- `failed`

### CapturePipeline

Responsibilities:

- start and stop mic capture
- start and stop system audio capture
- surface audio errors cleanly
- feed audio buffers into the transcription layer
- optionally write raw audio later if added

Reused source candidates:

- `/Users/harlow/Code/OpenGranola/OpenGranola/Sources/OpenGranola/Audio/MicCapture.swift`
- `/Users/harlow/Code/OpenGranola/OpenGranola/Sources/OpenGranola/Audio/SystemAudioCapture.swift`

### TranscriptionPipeline

Responsibilities:

- boot ASR and VAD once per session
- process mic and system audio independently
- emit normalized utterance events
- append transcript outputs incrementally

Reused source candidates:

- `/Users/harlow/Code/OpenGranola/OpenGranola/Sources/OpenGranola/Transcription/StreamingTranscriber.swift`
- `/Users/harlow/Code/OpenGranola/OpenGranola/Sources/OpenGranola/Transcription/TranscriptionEngine.swift`

Important design note:

The current repo uses source-based speaker separation:

- mic => `you`
- system audio => `them`

That is acceptable for V1. It will not separate multiple remote speakers from each other. The product should describe this honestly in docs and settings.

### SummaryPipeline

Responsibilities:

- read the finalized transcript
- build a summarization prompt
- call the configured provider
- validate and normalize output
- write `summary.md`

Supported providers for V1:

- OpenAI-compatible endpoint
- Anthropic-compatible endpoint
- Ollama-compatible local endpoint

Implementation guidance:

- do not reuse the current suggestion engine
- do reuse transport patterns or keychain handling where useful
- keep the summary pipeline independent of any live copilot abstractions

### SessionStorage

Responsibilities:

- create session folders
- write rolling raw transcript
- write plain text transcript
- write structured event log
- write summary Markdown
- persist session metadata
- detect interrupted sessions

## Functional Requirements

### FR1: Menu Bar App

The app shall launch into the menu bar.

The app shall not require a main window to be open during normal use.

The app shall provide menu actions for:

- Start Recording
- Stop Recording
- Open Latest Summary
- Open Latest Session Folder
- Open Output Root Folder
- Settings
- Quit

### FR2: Global Shortcut

The app shall support a global shortcut for toggling recording start/stop.

The app should support a second optional shortcut for “mark moment” in a later milestone.

The app shall persist the shortcut in settings.

The app shall validate shortcut conflicts where feasible.

### FR3: Permissions

The app shall clearly manage and explain:

- microphone permission
- screen recording / screen capture permission
- accessibility permission if required for global hotkey implementation

The app shall not silently fail when any permission is missing.

The app shall provide repair actions or instructions.

### FR4: Session Lifecycle

When recording starts, the app shall:

- validate permissions
- create a new session folder
- record session metadata
- initialize ASR/VAD models
- start mic and system audio capture
- begin transcript persistence
- update the menu bar icon/state

When recording stops, the app shall:

- stop capture cleanly
- flush transcript writers
- finalize transcript files
- run summarization
- write summary Markdown
- update session metadata
- notify the user when complete

### FR5: Transcript Outputs

The app shall write transcript artifacts incrementally during the call.

V1 outputs:

- `events.jsonl`
- `transcript.raw.txt`
- `transcript.txt`

Where:

- `events.jsonl` stores structured utterance events
- `transcript.raw.txt` stores incremental text with timestamps and source labels
- `transcript.txt` stores a finalized, cleaned plain text version

### FR6: Summary Output

The app shall generate a `summary.md` file after the call ends.

The Markdown summary shall include:

- title
- date and time
- duration
- participants labels available to the system
- overview
- key discussion points
- decisions made
- action items
- open questions
- notable quotes
- transcript source references if useful

The app shall include metadata frontmatter at the top of the file.

### FR7: Output Directory

The user shall choose a root output directory in settings.

The app shall create a predictable per-session folder structure under that root.

The app shall never require export to preserve results.

### FR8: Settings

The app shall provide settings for:

- output root directory
- transcript locale
- microphone device
- summary provider
- API key or local endpoint config
- summary model
- global shortcut
- launch at login
- open summary automatically on completion
- file naming pattern

### FR9: Notifications

The app shall notify the user when:

- recording starts
- recording stops
- summary generation completes
- a session fails

### FR10: Recovery

The app shall mark incomplete sessions when interrupted.

The app shall detect these on next launch.

The app shall offer to complete summarization if enough transcript data exists.

## Non-Functional Requirements

### Reliability

- no silent data loss
- transcript writes must be append-safe
- stop action must be idempotent
- failure in summarization must not destroy transcript outputs

### Performance

- start recording in under 2 seconds after models are warm
- UI actions should remain responsive during capture
- summarization may take longer, but should be clearly reflected in state

### Privacy

- transcription should support local-first operation
- summary provider usage must be explicit
- API keys must be stored in Keychain
- transcripts remain on disk in the user-selected directory

### Transparency

- clearly disclose what is captured
- clearly disclose when external providers are used
- clearly disclose output locations

## UX Specification

### Menu Bar States

#### Idle

Status item icon is neutral.

Menu shows:

- Start Recording
- Open Latest Session
- Open Output Folder
- Settings
- Quit

#### Recording

Status item icon changes color or badge.

Menu shows:

- Stop Recording
- Session timer
- Current output folder
- Open Current Session Folder
- Settings
- Quit

#### Processing

Status item icon indicates work in progress.

Menu shows:

- Finalizing Transcript...
- Summarizing...
- Open Current Session Folder
- Settings
- Quit

#### Error

Status item icon indicates failure.

Menu shows:

- Retry / Repair Permissions
- Open Logs
- Open Session Folder
- Settings
- Quit

### Onboarding Flow

First launch should open a lightweight onboarding/settings window if any of these are missing:

- output directory
- microphone permission
- screen capture permission
- summary provider configuration

Onboarding should explain:

- what the app records
- where files are stored
- how the shortcut works
- whether summaries are local or cloud-based

### Settings UI

The settings UI should be small and utilitarian, not a large workspace.

Sections:

- General
- Recording
- Output
- Summary
- Shortcuts
- Privacy
- Advanced

### Notifications

Use native notifications for:

- `Recording started`
- `Recording stopped`
- `Summary ready`
- `Recording failed`

`Summary ready` notification should offer:

- Open Summary
- Reveal In Finder

## Session File Layout

### Root Layout

Recommended structure:

```text
<output-root>/
  2026/
    03/
      2026-03-17_14-32-08_customer-research-call/
        session.json
        events.jsonl
        transcript.raw.txt
        transcript.txt
        summary.md
        logs.txt
```

This layout gives:

- clean chronological grouping
- human-readable folders
- compatibility with note tools and backup systems
- easy manual inspection

### `session.json`

Purpose:

- durable metadata
- crash recovery
- audit trail

Suggested schema:

```json
{
  "session_id": "uuid",
  "started_at": "2026-03-17T21:32:08Z",
  "ended_at": "2026-03-17T22:14:55Z",
  "duration_seconds": 2567,
  "status": "completed",
  "app_version": "0.1.0",
  "transcription": {
    "engine": "FluidAudio",
    "model": "Parakeet-TDT-v2",
    "locale": "en-US"
  },
  "summary": {
    "provider": "anthropic",
    "model": "claude-3-7-sonnet",
    "completed": true
  },
  "audio": {
    "mic_device_name": "MacBook Pro Microphone",
    "system_audio_enabled": true
  },
  "artifacts": {
    "events_jsonl": "events.jsonl",
    "transcript_raw": "transcript.raw.txt",
    "transcript_final": "transcript.txt",
    "summary_markdown": "summary.md"
  }
}
```

### `events.jsonl`

Purpose:

- structured utterance stream
- machine-readable post-processing
- crash-safe incremental write

Suggested event shape:

```json
{"type":"session_started","timestamp":"2026-03-17T21:32:08Z"}
{"type":"utterance_final","speaker":"you","timestamp":"2026-03-17T21:32:15Z","text":"Thanks for making the time today."}
{"type":"utterance_final","speaker":"them","timestamp":"2026-03-17T21:32:19Z","text":"Happy to. I wanted to walk through the pilot feedback."}
{"type":"session_stopped","timestamp":"2026-03-17T22:14:55Z"}
{"type":"summary_completed","timestamp":"2026-03-17T22:15:20Z","path":"summary.md"}
```

### `transcript.raw.txt`

Purpose:

- append-friendly human-readable transcript
- near-verbatim record of final utterances

Format:

```text
[14:32:15] You: Thanks for making the time today.
[14:32:19] Them: Happy to. I wanted to walk through the pilot feedback.
```

### `transcript.txt`

Purpose:

- finalized transcript
- easier for direct reading and summarizer input

Possible format:

```text
Spool
Date: Mar 17, 2026
Duration: 42m 47s

You: Thanks for making the time today.
Them: Happy to. I wanted to walk through the pilot feedback.
```

### `summary.md`

Purpose:

- portable meeting artifact
- readable in editors, note apps, and git repos

Recommended shape:

```md
---
title: Customer Research Call
started_at: 2026-03-17T21:32:08Z
ended_at: 2026-03-17T22:14:55Z
duration_seconds: 2567
summary_provider: anthropic
summary_model: claude-3-7-sonnet
transcription_model: Parakeet-TDT-v2
session_id: uuid
---

# Customer Research Call

## Overview

...

## Key Points

...

## Decisions

...

## Action Items

...

## Open Questions

...

## Notable Quotes

...
```

## Data Model

### Core Types

Suggested new model layer:

- `Session`
- `SessionStatus`
- `UtteranceEvent`
- `SummaryResult`
- `AppSettings`
- `PermissionStatus`
- `ShortcutBinding`

### `UtteranceEvent`

Suggested fields:

- `id`
- `speaker`
- `source`
- `text`
- `startedAt`
- `endedAt`
- `sequenceNumber`
- `confidence` optional

Suggested speaker/source enums:

- `speaker`: `you`, `them`, `unknown`
- `source`: `microphone`, `systemAudio`

This is cleaner than reusing the current suggestion-heavy `Models.swift`.

## Audio And Transcription Design

### Reuse Strategy

Directly evaluate porting:

- `/Users/harlow/Code/OpenGranola/OpenGranola/Sources/OpenGranola/Audio/MicCapture.swift`
- `/Users/harlow/Code/OpenGranola/OpenGranola/Sources/OpenGranola/Audio/SystemAudioCapture.swift`
- `/Users/harlow/Code/OpenGranola/OpenGranola/Sources/OpenGranola/Transcription/StreamingTranscriber.swift`
- `/Users/harlow/Code/OpenGranola/OpenGranola/Sources/OpenGranola/Transcription/TranscriptionEngine.swift`

Expected refactors after port:

- remove UI-specific status coupling
- remove transcript store coupling
- emit typed utterance events through a simpler protocol
- centralize write targets in `SessionStorage`
- isolate model loading and permission handling

### Current Model Fit

The current repo uses FluidAudio with Parakeet-TDT v2. That is a credible default for the new app because:

- it already works in this codebase
- it is local-first
- it handles long-running sessions via chunking + VAD
- it avoids sending audio to a cloud ASR provider by default

Recommendation:

- keep Parakeet-TDT v2 for V1
- validate quality with real call recordings before considering a model switch
- do not prematurely widen the surface area with multiple ASR backends in V1

### Speaker Separation Assumption

V1 assumption:

- your mic is one speaker channel
- all remote/system audio is one speaker channel

This means:

- call summaries can still be useful
- remote speaker diarization is not guaranteed
- transcript language should use `You` and `Them` rather than pretending to know exact remote participants

## Summary Pipeline Design

### Summary Generation Trigger

The summary stage runs only after recording stops and transcript finalization completes.

Rationale:

- simpler product semantics
- avoids live latency tradeoffs
- avoids polluting the UI with in-call generation states

### Summary Provider Abstraction

Implement a provider-neutral interface:

```swift
protocol SummaryProvider {
    func summarize(transcript: FinalTranscript, template: SummaryTemplate) async throws -> SummaryResult
}
```

Concrete implementations:

- `OpenAICompatibleSummaryProvider`
- `AnthropicSummaryProvider`
- `OllamaSummaryProvider`

### Prompting Strategy

The app should have one default summary template and one shorter “notes-only” template.

Default template output:

- concise title
- short overview
- key points
- decisions
- action items with owner if inferable
- open questions
- notable quotes

Prompt requirements:

- preserve uncertainty
- do not invent action owners
- keep references grounded in transcript content
- allow empty sections rather than hallucinated sections

### Failure Modes

If summary generation fails:

- transcript artifacts must still be preserved
- `session.json` should mark summary failure
- menu and notification should offer retry

## Permissions Design

### Microphone

Reuse and clean up the current microphone authorization handling from:

- `/Users/harlow/Code/OpenGranola/OpenGranola/Sources/OpenGranola/Transcription/TranscriptionEngine.swift`

### Screen Capture

The new app must explicitly handle screen capture permission in onboarding and repair UI.

Current repo behavior implicitly relies on ScreenCaptureKit usage for system audio. The new product should be more explicit because call recording reliability depends on it.

### Accessibility

If required by the chosen global shortcut implementation, accessibility permission must be surfaced as a first-class requirement.

Do not bury this behind runtime failure.

## Settings Design

### Required Settings

- Output root directory
- Mic input device
- Transcript locale
- Summary provider
- Summary model
- API key / endpoint
- Global shortcut

### Recommended Settings

- Launch at login
- Open summary when complete
- Open session folder when complete
- Include raw transcript text file
- Include JSONL event log
- File/folder naming format
- Debug logging

### Advanced Settings

- max summary length
- local vs cloud summary warning text
- summarization template choice
- retry count for summary generation

## App Lifecycle

### Startup

1. Launch app
2. Restore settings
3. Initialize status item
4. Check for incomplete sessions
5. If required configuration is missing, open onboarding/settings
6. Otherwise stay quietly in menu bar

### Recording Start

1. User triggers menu action or shortcut
2. App validates permissions
3. App validates output directory and provider config
4. App creates session folder
5. App writes `session.json`
6. App starts capture/transcription
7. App begins rolling transcript writes
8. App updates icon and timer

### Recording Stop

1. User triggers stop
2. App stops capture
3. App flushes utterance buffers
4. App finalizes transcript files
5. App updates `session.json`
6. App starts summary generation
7. App writes `summary.md`
8. App updates menu and notifies user

### Interrupted Session Recovery

On next launch:

1. scan recent session folders
2. find sessions with status `recording`, `finalizingTranscript`, or `summarizing`
3. mark them `interrupted`
4. if transcript exists and summary is missing, offer `Finish Summary`

## Logging And Diagnostics

V1 should include:

- session-local `logs.txt`
- optional app-global debug log
- clear errors surfaced in the menu or settings

Important events to log:

- permission failures
- capture start/stop
- model load start/finish
- utterance writer failures
- summary provider failures
- recovery decisions

## Security And Privacy

- API keys stored in Keychain
- no cloud provider used unless explicitly configured
- transcript files are plain local files in a user-chosen directory
- raw transcript should be easy to delete manually
- summary provider warnings should explain that transcript text may be sent to an external provider when selected

## Implementation Plan

### Phase 0: Repo Setup

Deliverables:

- new repo scaffold
- app target
- package dependencies
- build and sign scripts
- basic README

Tasks:

- create new Swift package or Xcode project structure
- use `Spool` as the working app name
- use a bundle id such as `com.yourname.spool` until a final org/domain is chosen
- add settings persistence foundation
- add status item shell

### Phase 1: Menu Bar Shell

Deliverables:

- status item
- menu actions
- settings window
- onboarding window

Tasks:

- implement `AppShell`
- implement `RecordingController`
- add icon states
- add base settings UI

### Phase 2: Port Capture And Transcription

Deliverables:

- mic capture working
- system audio capture working
- transcription events emitted

Tasks:

- port `MicCapture`
- port `SystemAudioCapture`
- port and simplify `StreamingTranscriber`
- port and simplify `TranscriptionEngine`
- validate permissions and device switching

### Phase 3: Session Storage

Deliverables:

- session folder creation
- event log writing
- raw transcript writing
- session metadata persistence

Tasks:

- implement `SessionStorage`
- define schemas
- add crash-safe append logic
- add incomplete-session detection

### Phase 4: Summarization

Deliverables:

- provider abstraction
- settings for providers
- summary prompt templates
- `summary.md`

Tasks:

- implement providers
- wire provider auth to Keychain
- add summary retry behavior
- add summary-ready notifications

### Phase 5: Global Shortcut And Launch Behavior

Deliverables:

- start/stop shortcut
- shortcut settings
- optional launch at login

Tasks:

- implement hotkey service
- handle permission dependencies
- add UX for shortcut capture and validation

### Phase 6: Hardening

Deliverables:

- recovery behavior
- better errors
- smoke tests
- sample outputs

Tasks:

- test on Zoom, Meet, and Teams
- test missing permissions flows
- test long sessions
- test network failure during summary generation

## Testing Strategy

### Manual Test Matrix

- Zoom call with headset mic
- Zoom call with built-in mic
- Google Meet in Chrome
- Slack huddle or Teams call
- start/stop via menu
- start/stop via shortcut
- permissions missing on first launch
- output directory unavailable
- summary provider credentials missing
- app quit during recording
- app relaunch after interrupted session

### Acceptance Criteria

- user can start recording without opening a main window
- transcript files exist before the call ends
- stopping recording always produces final transcript artifacts
- summary failure does not destroy transcript outputs
- output location is predictable and user-controlled

## Risks

### Risk 1: System Audio Capture Reliability

ScreenCaptureKit behavior can vary with permission state and app context.

Mitigation:

- test across Zoom, Meet, Teams
- provide explicit permission repair UX
- preserve mic-only fallback when system audio is unavailable

### Risk 2: Global Shortcut Complexity

Global shortcuts may require additional permission or careful event handling.

Mitigation:

- choose a proven implementation approach early
- make menu action always available as fallback

### Risk 3: Speaker Attribution Limits

System audio is mixed remote audio, not true diarization.

Mitigation:

- use honest labels
- keep the V1 summary prompt compatible with coarse speaker attribution

### Risk 4: Summary Hallucination

LLM summaries can invent details.

Mitigation:

- design grounding prompts carefully
- preserve transcript as the source of truth
- allow users to inspect transcript and summary side by side

### Risk 5: Local Model Cold Start

Local ASR or local summary models may have slow first-run startup.

Mitigation:

- preload models when possible
- expose clear status states
- document first-run download behavior

## Open Questions

- Do we want to support raw audio file recording in V1 or keep V1 transcript-only?
- Do we want one default summary template or multiple?
- Should the app auto-open the summary after completion by default?
- Should the app hide from the Dock entirely or show a Dock icon only while onboarding/settings is open?
- Should we support a transcript preview popover in V1 or keep the app menu-only?

## Final Recommendation

Build a new repo.

Use OpenGranola as a reference implementation and source of selected low-level components, especially:

- `/Users/harlow/Code/OpenGranola/OpenGranola/Sources/OpenGranola/Audio/MicCapture.swift`
- `/Users/harlow/Code/OpenGranola/OpenGranola/Sources/OpenGranola/Audio/SystemAudioCapture.swift`
- `/Users/harlow/Code/OpenGranola/OpenGranola/Sources/OpenGranola/Transcription/StreamingTranscriber.swift`
- `/Users/harlow/Code/OpenGranola/OpenGranola/Sources/OpenGranola/Transcription/TranscriptionEngine.swift`
- `/Users/harlow/Code/OpenGranola/OpenGranola/Sources/OpenGranola/Settings/AppSettings.swift`

Do not reuse the current app shell or the live-copilot product logic.

The shortest path is:

1. New repo
2. Port capture/transcription core
3. Build menu bar shell
4. Add session storage
5. Add post-call summary pipeline
6. Harden permissions, recovery, and UX
