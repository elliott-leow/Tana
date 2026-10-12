#!/bin/sh
# Login-only startup; reuses the existing, already-authorized yabai helper.
set -eu
umask 077
root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app="$root_dir/build/Tana.app"
wm="$app/Contents/MacOS/tana"
logs="$HOME/Library/Logs/Tana"
mkdir -p "$logs"
if [ ! -x "$wm" ]; then
    printf '%s\n' 'Tana bundle is missing; rebuild and package it.' >&2
    exit 75
fi
if "$wm" -m strip status >/dev/null 2>&1; then exit 0; fi

# A locked login session has no usable AX window list. Wait without prompting.
attempt=0
while :; do
    permission=$("$wm" --check-permissions 2>/dev/null || true)
    if printf '%s' "$permission" | /usr/bin/grep -q '"session_unlocked":true'; then break; fi
    attempt=$((attempt+1))
    if [ "$attempt" -ge 150 ]; then exit 75; fi
    /bin/sleep 2
done
if ! printf '%s' "$permission" | /usr/bin/grep -q '"accessibility":true'; then
    printf '%s\n' 'Tana needs its existing Accessibility grant restored.' >&2
    exit 75
fi
if ! "$wm" --check-backend >/dev/null 2>&1; then
    # This local yabai loader can return nonzero after successful injection.
    /usr/bin/sudo -n /opt/homebrew/bin/yabai --load-sa || true
fi
attempt=0
until "$wm" --check-backend >/dev/null 2>&1; do
    attempt=$((attempt+1))
    if [ "$attempt" -ge 20 ]; then
        printf '%s\n' 'Existing window-control helper did not become ready.' >&2
        exit 75
    fi
    /bin/sleep 1
done
/usr/bin/open -g -n --stdout "$logs/manager.out.log" --stderr "$logs/manager.err.log" "$app"
attempt=0
while :; do
    status=$("$wm" -m strip status 2>/dev/null || true)
    if printf '%s' "$status" | /usr/bin/grep -q '"ready":true,"paused":false,"backend":true'; then
        printf '%s\n' 'Tana login startup verified ready.'
        exit 0
    fi
    attempt=$((attempt+1))
    if [ "$attempt" -ge 60 ]; then exit 75; fi
    /bin/sleep 1
done
