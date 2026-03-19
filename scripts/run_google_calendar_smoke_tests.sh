#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR=".build/google-calendar-smoke-tests"
mkdir -p "$OUT_DIR"

swiftc \
  -package-name Spool \
  -parse-as-library \
  Sources/Spool/Models/AppSettings.swift \
  Sources/Spool/Models/CalendarModels.swift \
  Sources/Spool/Services/GoogleCalendarService.swift \
  scripts/google_calendar_smoke_tests_main.swift \
  -o "$OUT_DIR/run"

"$OUT_DIR/run"
