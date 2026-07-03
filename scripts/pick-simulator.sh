#!/usr/bin/env bash
# Print an xcodebuild `-destination` string for the newest available iPhone
# simulator on this machine. CI uses this instead of hardcoding a device/runtime
# that may not be installed on the runner image.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq not found. Install with 'brew install jq'." >&2; exit 1; }

udid=$(
  xcrun simctl list devices available --json \
  | jq -r '
      [ .devices
        | to_entries[]
        | select(.key | test("SimRuntime\\.iOS-[0-9]+-[0-9]+"))
        | (.key | capture("iOS-(?<maj>[0-9]+)-(?<min>[0-9]+)")) as $v
        | .value[]
        | select(.isAvailable and (.name | test("iPhone")))
        | [ ($v.maj | tonumber), ($v.min | tonumber), .udid ]
      ]
      | sort_by(.[0], .[1])
      | last
      | .[2] // empty
    '
)

if [ -z "$udid" ]; then
  echo "No available iPhone simulator found" >&2
  xcrun simctl list devices available >&2
  exit 1
fi

printf 'platform=iOS Simulator,id=%s\n' "$udid"
