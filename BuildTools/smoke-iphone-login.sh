#!/bin/bash
set -euo pipefail

device_id=$1
app_path=$2
bundle_id=$3
mkdir -p build/validation/crashes
# A fresh CI simulator otherwise presents the swipe-typing tutorial instead of
# the keyboard, blocking the search focus / dock restoration regression check.
for preference in DidShowContinuousPathIntroduction KeyboardDidShowProductivityTutorial DidShowGestureKeyboardIntroduction UIKeyboardDidShowInternationalInfoIntroduction; do
  xcrun simctl spawn "$device_id" defaults write com.apple.keyboard.preferences "$preference" -bool true
done
python3 -u BuildTools/subsonic-smoke-server.py > build/validation/server.log 2>&1 &
server_pid=$!
cleanup() {
  kill "$server_pid" 2>/dev/null || true
  if [[ -n "${motion_pid:-}" ]]; then
    kill -INT "$motion_pid" 2>/dev/null || true
    wait "$motion_pid" || true
  fi
  # Preserve intermediate frames and the exact failing step even on a smoke failure.
  if [[ -n "${container:-}" ]]; then
    find "$container/Documents" -name 'player-*.png' -exec cp {} build/validation/ \; 2>/dev/null || true
  fi
  find "$HOME/Library/Logs/DiagnosticReports" -name 'Amperfy*.ips' -exec cp {} build/validation/crashes/ \; 2>/dev/null || true
  xcrun simctl spawn "$device_id" log show --last 5m --style compact --predicate 'process == "Amperfy"' > build/validation/simulator.log 2>&1 || true
}
trap cleanup EXIT
sleep 1

for language in zh-Hans en; do
  # Only the throwaway CI simulator is reset; each language must complete a fresh login.
  xcrun simctl terminate "$device_id" "$bundle_id" || true
  xcrun simctl uninstall "$device_id" "$bundle_id" || true
  xcrun simctl install "$device_id" "$app_path"
  container=$(xcrun simctl get_app_container "$device_id" "$bundle_id" data)
  if [[ "$language" == zh-Hans ]]; then
    xcrun simctl launch "$device_id" "$bundle_id" --smoke-launch-screen
    for attempt in {1..20}; do
      [[ -f "$container/Documents/launch-screen.png" ]] && break
      sleep 1
    done
    cp "$container/Documents/launch-screen.png" build/validation/launch-screen.png
    xcrun simctl terminate "$device_id" "$bundle_id"
  fi
  xcrun simctl launch --terminate-running-process \
    --stdout="$PWD/build/validation/login-$language.stdout.log" \
    --stderr="$PWD/build/validation/login-$language.stderr.log" \
    "$device_id" "$bundle_id" -AppleLanguages "($language)" --smoke-login
  ready=false
  for attempt in {1..60}; do
    if [[ -f "$container/Documents/login-smoke-ready" ]]; then
      ready=true
      break
    fi
    sleep 2
  done
  xcrun simctl io "$device_id" screenshot "build/validation/home-$language.png"
  if [[ "$ready" != true ]]; then
    echo "Login/sync/home smoke test failed for $language"
    cat "build/validation/login-$language.stderr.log"
    exit 1
  fi
  echo "Login/sync/home smoke test passed for $language"

  # Reopening a signed-in app must also load the persisted library successfully.
  rm "$container/Documents/login-smoke-ready"
  xcrun simctl terminate "$device_id" "$bundle_id"
  xcrun simctl launch \
    --stdout="$PWD/build/validation/reopen-$language.stdout.log" \
    --stderr="$PWD/build/validation/reopen-$language.stderr.log" \
    "$device_id" "$bundle_id" -AppleLanguages "($language)" --smoke-login
  ready=false
  for attempt in {1..30}; do
    if [[ -f "$container/Documents/login-smoke-ready" ]]; then
      ready=true
      break
    fi
    sleep 2
  done
  xcrun simctl io "$device_id" screenshot "build/validation/reopen-$language.png"
  if [[ "$ready" != true ]]; then
    echo "Signed-in cold launch failed for $language"
    cat "build/validation/reopen-$language.stderr.log"
    exit 1
  fi
  echo "Signed-in cold launch passed for $language"
done

# Exercise real streaming, seeking, the server lyrics response, and the full player.
xcrun simctl terminate "$device_id" "$bundle_id"
# Keep a recording of the real compositor output for transition review.
# It runs independently so frame sampling in the app is never stalled by captures.
xcrun simctl io "$device_id" recordVideo --codec=h264 build/validation/player-motion.mp4 >build/validation/player-motion.log 2>&1 &
motion_pid=$!
xcrun simctl launch \
  --stdout="$PWD/build/validation/player.stdout.log" \
  --stderr="$PWD/build/validation/player.stderr.log" \
  "$device_id" "$bundle_id" -AppleLanguages '(zh-Hans)' --smoke-login --smoke-player
ready=false
# The player suite also checks all statistics panels and native detail returns.
# Bound polling between compositor captures; report an explicit failure immediately.
for attempt in {1..150}; do
  if [[ -f "$container/Documents/player-screenshot-request" ]]; then
    screenshot_name=$(cat "$container/Documents/player-screenshot-request")
    if [[ ! "$screenshot_name" =~ ^player-[a-z0-9-]+\.png$ ]]; then
      echo "Invalid player screenshot request"
      exit 1
    fi
    # Capture the compositor's native glass, which drawHierarchy can omit.
    xcrun simctl io "$device_id" screenshot "$container/Documents/$screenshot_name"
    rm "$container/Documents/player-screenshot-request"
    touch "$container/Documents/player-screenshot-complete"
  fi
  if [[ -f "$container/Documents/player-smoke-ready" ]]; then
    ready=true
    break
  fi
  [[ -f "$container/Documents/player-smoke-failed" ]] && break
  sleep 2
done
kill -INT "$motion_pid" 2>/dev/null || true
wait "$motion_pid" || true
motion_pid=
xcrun simctl io "$device_id" screenshot build/validation/player-dismissed-zh-Hans.png
for screenshot in player-transport-pressed player-transport-playing-transition player-transport-previous-transition player-transport-next-transition player-autoplay-queue player-queue-scroll-history-near-top player-queue-scroll-history-title-edge player-queue-history-reopened player-queue-scroll-history player-queue-scroll-current player-queue-scroll-modes player-queue-scroll-beyond player-queue-empty player-queue-resumed player-opening player-opening-refreshed player-closing-capsule player-next-song player-paused-artwork player-mini-spacing player-native-library player-mini-collapsed player-search-keyboard player-lyrics-controls player-queue-from-lyrics player-queue-multiple player-mini-drag player-mini-drag-previous player-lyrics-reopened player-queue-closed-artwork player-statistics-overview player-statistics-ranking player-statistics-trend player-statistics-top player-statistics-history; do
  source="$container/Documents/$screenshot.png"
  if [[ -f "$source" ]]; then
    sips -s format jpeg -s formatOptions 80 -Z 1000 "$source" --out "build/validation/$screenshot-preview.jpg" >/dev/null
  fi
done
if [[ "$ready" != true ]]; then
  echo "Streaming/seek/lyrics smoke test failed"
  cat build/validation/player.stdout.log
  cat build/validation/player.stderr.log
  exit 1
fi
echo "Original audio streaming, seek and synchronized lyrics smoke test passed"
cat build/validation/player.stdout.log

for screenshot in player-library-defaults player-mini-drag player-mini-drag-previous player-mini-spacing player-native-library player-mini-collapsed player-search-keyboard player-opening player-lyrics-upward player-artwork-landscape player-next-song player-lyrics-controls player-lyrics-immersive player-lyrics-restored player-queue-from-lyrics player-queue-multiple player-lyrics-from-queue; do
  cp "$container/Documents/$screenshot.png" "build/validation/$screenshot.png"
done

python3 - <<'PY'
import json
from pathlib import Path
# Concurrent HTTP request logs may follow the JSON before its newline. Decode
# exactly one JSON value, rather than requiring the whole line to be JSON.
decoder = json.JSONDecoder()
records = [decoder.raw_decode(part)[0] for part in Path('build/validation/server.log').read_text().split('SCROBBLE ')[1:]]
assert any(r['submission'] == ['false'] for r in records), 'Missing now-playing notification'
assert any(r['id'] == ['song-scrobble'] and r['submission'] == ['true'] and int(r['time'][0]) > 0 for r in records), f'Missing completed short listen with play timestamp: {records}'
print('Subsonic now-playing and timestamped listening-history submission passed')
PY
