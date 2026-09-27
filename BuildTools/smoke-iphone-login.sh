#!/bin/bash
set -euo pipefail

device_id=$1
app_path=$2
bundle_id=$3
mkdir -p build/validation/crashes
python3 -u BuildTools/subsonic-smoke-server.py > build/validation/server.log 2>&1 &
server_pid=$!
cleanup() {
  kill "$server_pid" 2>/dev/null || true
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
xcrun simctl launch \
  --stdout="$PWD/build/validation/player.stdout.log" \
  --stderr="$PWD/build/validation/player.stderr.log" \
  "$device_id" "$bundle_id" -AppleLanguages '(zh-Hans)' --smoke-login --smoke-player
ready=false
for attempt in {1..45}; do
  if [[ -f "$container/Documents/player-smoke-ready" ]]; then
    ready=true
    break
  fi
  sleep 2
done
xcrun simctl io "$device_id" screenshot build/validation/player-dismissed-zh-Hans.png
if [[ "$ready" != true ]]; then
  echo "Streaming/seek/lyrics smoke test failed"
  cat build/validation/player.stdout.log
  cat build/validation/player.stderr.log
  exit 1
fi
echo "Original audio streaming, seek and synchronized lyrics smoke test passed"
cat build/validation/player.stdout.log

for screenshot in player-mini-spacing player-opening player-lyrics-upward player-artwork-landscape player-next-song player-lyrics-controls player-lyrics-immersive player-lyrics-restored; do
  cp "$container/Documents/$screenshot.png" "build/validation/$screenshot.png"
done
