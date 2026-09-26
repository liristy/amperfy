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
  find "$HOME/Library/Logs/DiagnosticReports" -name 'Amperfy*.ips' -exec cp {} build/validation/crashes/ \; 2>/dev/null || true
  xcrun simctl spawn "$device_id" log show --last 5m --style compact --predicate 'process == "Amperfy"' > build/validation/simulator.log 2>&1 || true
}
trap cleanup EXIT
sleep 1

for language in zh-Hans en; do
  # Only the throwaway CI simulator is reset; each language must complete a fresh login.
  xcrun simctl terminate "$device_id" "$bundle_id" || true
  xcrun simctl uninstall "$device_id" "$bundle_id"
  xcrun simctl install "$device_id" "$app_path"
  container=$(xcrun simctl get_app_container "$device_id" "$bundle_id" data)
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
