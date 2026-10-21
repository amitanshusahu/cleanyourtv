#!/usr/bin/env bash
# Build the launcher and try it on a connected emulator or USB device (chosen by serial, not TV_HOST).
# Everything build-and-install.sh does to a TV is done here too, but the setup that was there before is
# recorded first: a failure rolls it back automatically, and `./test-launcher.sh --restore` puts it back
# whenever you are done trying the launcher.
#
#   ./test-launcher.sh                          pick the only device, or ask when there are several
#   ./test-launcher.sh emulator-5554            use a serial directly
#   DEVICE=emulator-5554 ./test-launcher.sh     same, via the environment
#   STOCK_LAUNCHER=<package> ./test-launcher.sh disable that package instead of the detected Home owner
#   ./test-launcher.sh --restore                undo the last test on that device
#   ./test-launcher.sh --force                  start anyway if an earlier test was not restored
set -euo pipefail
cd "$(dirname "$0")"

OURS=com.gathin.tvhome
OURS_ACTIVITY=$OURS/.MainActivity
HOME_QUERY=(cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME)
# Launchers this script is willing to disable without being told. Anything else (a setup wizard, another
# third-party Home) is left enabled: on a test device the goal is to try the launcher, not to fight the ROM.
KNOWN_STOCK_LAUNCHERS="com.google.android.tvlauncher com.google.android.apps.tv.launcherx com.google.android.leanbacklauncher com.mitv.tvhome com.android.tvlauncher com.android.launcher3 com.google.android.apps.nexuslauncher"

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

RESTORE_ONLY=0
BUILD=1
FORCE=0
DEVICE_ARG=""
for arg in "$@"; do
  case "$arg" in
    --restore) RESTORE_ONLY=1 ;;
    --no-build) BUILD=0 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; usage >&2; exit 2 ;;
    *) DEVICE_ARG=$arg ;;
  esac
done

find_adb() {
  if [ -n "${ADB:-}" ]; then echo "$ADB"; return 0; fi
  if command -v adb >/dev/null 2>&1; then command -v adb; return 0; fi
  for d in "${ANDROID_HOME:-}" "$HOME/Android/Sdk" "$HOME/Library/Android/sdk" \
           /opt/homebrew/share/android-commandlinetools; do
    if [ -n "$d" ] && [ -x "$d/platform-tools/adb" ]; then echo "$d/platform-tools/adb"; return 0; fi
  done
  return 1
}
ADB=$(find_adb) || {
  echo "ERROR: adb was not found. Install Android platform-tools, or set ADB=/path/to/adb." >&2
  exit 1
}
"$ADB" start-server >/dev/null 2>&1 || true

# Connected devices that are ready, one serial per line.
available_devices() {
  "$ADB" devices | awk 'NR > 1 && $2 == "device" { print $1 }'
}

SERIAL="${DEVICE:-${DEVICE_ARG:-}}"
if [ -z "$SERIAL" ]; then
  AVAILABLE=$(available_devices)
  COUNT=$(printf '%s\n' "$AVAILABLE" | grep -c . || true)
  case "$COUNT" in
    0)
      echo "ERROR: no device is connected. Start an emulator or plug the device in, then check 'adb devices'." >&2
      exit 1 ;;
    1)
      SERIAL=$(printf '%s\n' "$AVAILABLE" | head -n 1)
      echo "Using the only connected device: $SERIAL" ;;
    *)
      echo "Several devices are connected:"
      i=0
      while IFS= read -r d; do
        [ -n "$d" ] || continue
        i=$((i + 1))
        printf '  %d) %s\n' "$i" "$d"
      done <<< "$AVAILABLE"
      if [ ! -t 0 ]; then
        echo "ERROR: pass the serial, e.g. ./test-launcher.sh emulator-5554" >&2
        exit 1
      fi
      printf 'Which one? [1-%d] ' "$i"
      read -r choice
      SERIAL=$(printf '%s\n' "$AVAILABLE" | sed -n "${choice}p")
      [ -n "$SERIAL" ] || { echo "ERROR: not a valid choice." >&2; exit 1; } ;;
  esac
fi

# An IP:port serial is a TV on the network: `adb -s` alone does not connect to it.
case "$SERIAL" in
  *:*) "$ADB" connect "$SERIAL" >/dev/null 2>&1 || true ;;
esac
if ! "$ADB" -s "$SERIAL" get-state >/dev/null 2>&1; then
  echo "ERROR: device '$SERIAL' is not available; check 'adb devices'." >&2
  exit 1
fi

SAFE_SERIAL=$(printf '%s' "$SERIAL" | tr -c 'A-Za-z0-9._-' '_')
STATE=$PWD/.test-launcher-${SAFE_SERIAL}.state

adb_cmd() { "$ADB" -s "$SERIAL" "$@"; }
shell_cmd() { adb_cmd shell "$@" 2>&1 | tr -d '\r'; }
query_home() { shell_cmd "${HOME_QUERY[@]}" | tail -n 1 || true; }

restore_state() {
  # Never let the error trap fire while undoing things: a restore that cannot run one command should
  # still try the rest.
  trap - ERR INT TERM
  if [ ! -f "$STATE" ]; then
    echo "No saved state for $SERIAL; nothing to restore."
    return 0
  fi
  # shellcheck source=/dev/null
  . "$STATE"
  local rc=0 now want
  echo "Restoring the setup recorded for $ST_SERIAL before the test..."

  # Re-enable the stock launcher first: Android drops the Home preference whenever the set of HOME
  # apps changes, so the preference has to be set after the package is enabled again.
  if [ "$ST_STOCK_LAUNCHER" != none ] && [ "$ST_STOCK_ENABLED" = 1 ]; then
    shell_cmd pm enable --user 0 "$ST_STOCK_LAUNCHER" >/dev/null 2>&1 || true
  fi
  if [ -n "$ST_PREV_HOME" ] && [ "${ST_PREV_HOME%%/*}" != android ]; then
    shell_cmd cmd package set-home-activity --user 0 "$ST_PREV_HOME" >/dev/null 2>&1 || true
    shell_cmd am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1 || true
  fi

  # The app was not on the device before the test, so an uninstall is what "the same as before" means.
  # A version that was already installed is left alone: its data and grant survive, as they should.
  if [ "$ST_OURS_WAS_INSTALLED" = 0 ] && shell_cmd pm path "$OURS" | grep -q '^package:'; then
    shell_cmd pm uninstall "$OURS" >/dev/null 2>&1 || true
  fi

  if [ "$ST_PREV_ACCESSIBILITY_SERVICES" = null ] || [ -z "$ST_PREV_ACCESSIBILITY_SERVICES" ]; then
    shell_cmd settings delete secure enabled_accessibility_services >/dev/null 2>&1 || true
  else
    shell_cmd settings put secure enabled_accessibility_services "$ST_PREV_ACCESSIBILITY_SERVICES" >/dev/null 2>&1 || true
  fi
  if [ "$ST_PREV_ACCESSIBILITY_ENABLED" = null ] || [ -z "$ST_PREV_ACCESSIBILITY_ENABLED" ]; then
    shell_cmd settings delete secure accessibility_enabled >/dev/null 2>&1 || true
  else
    shell_cmd settings put secure accessibility_enabled "$ST_PREV_ACCESSIBILITY_ENABLED" >/dev/null 2>&1 || true
  fi

  now=$(query_home)
  want=${ST_PREV_HOME%%/*}
  case "$now" in
    "$want"/*) echo "Home is back on $now." ;;
    android|"")
      echo "Home has no default again (there was none before the test)." ;;
    *)
      echo "WARNING: Home still resolves to '$now', not to '${ST_PREV_HOME:-nothing}'." >&2
      echo "The saved state is kept in $STATE; re-run --restore or set it from Settings." >&2
      rc=1 ;;
  esac
  if [ "$rc" = 0 ]; then
    rm -f "$STATE"
  fi
  return "$rc"
}

if [ "$RESTORE_ONLY" = 1 ]; then
  restore_state
  exit $?
fi

if [ -f "$STATE" ] && [ "$FORCE" = 0 ]; then
  echo "ERROR: a previous test on $SERIAL may not have been restored ($STATE)." >&2
  echo "Run './test-launcher.sh --restore' first, or pass --force to overwrite it." >&2
  exit 1
fi

if [ "$BUILD" = 1 ]; then
  ./build-apk.sh
fi
APK=app/build/outputs/apk/release/app-release.apk
[ -f "$APK" ] || { echo "ERROR: $APK is missing; build it with ./build-apk.sh." >&2; exit 1; }

PREV_HOME=$(query_home)
PREV_HOME_PKG=${PREV_HOME%%/*}
if shell_cmd pm path "$OURS" | grep -q '^package:'; then OURS_WAS_INSTALLED=1; else OURS_WAS_INSTALLED=0; fi
PREV_SERVICES=$(shell_cmd settings get secure enabled_accessibility_services | tail -n 1)
PREV_ACC_ENABLED=$(shell_cmd settings get secure accessibility_enabled | tail -n 1)

# The stock launcher is the package that owns Home right now, exactly as build-and-install.sh finds it,
# unless STOCK_LAUNCHER names one. Only a launcher this script recognises is disabled by default.
DISABLE_STOCK=1
if [ -n "${STOCK_LAUNCHER:-}" ]; then
  STOCK=$STOCK_LAUNCHER
  [ "$STOCK" = none ] && DISABLE_STOCK=0
else
  case "$PREV_HOME_PKG" in
    ""|android|"$OURS") STOCK=none; DISABLE_STOCK=0 ;;
    *)
      STOCK=$PREV_HOME_PKG
      case " $KNOWN_STOCK_LAUNCHERS " in
        *" $STOCK "*) ;;
        *)
          DISABLE_STOCK=0
          echo "NOTE: '$STOCK' owns Home but is not a launcher this script disables by default; it will stay" >&2
          echo "      enabled and only the Home preference will change. Pass STOCK_LAUNCHER=$STOCK to disable it." >&2 ;;
      esac ;;
  esac
fi
if [ "$STOCK" != none ] && shell_cmd pm list packages -d | grep -qx "package:$STOCK"; then STOCK_ENABLED=0; else STOCK_ENABLED=1; fi
[ "$STOCK" = none ] && STOCK_ENABLED=0

{
  printf 'ST_SERIAL=%q\n' "$SERIAL"
  printf 'ST_PREV_HOME=%q\n' "$PREV_HOME"
  printf 'ST_STOCK_LAUNCHER=%q\n' "$STOCK"
  printf 'ST_STOCK_ENABLED=%q\n' "$STOCK_ENABLED"
  printf 'ST_OURS_WAS_INSTALLED=%q\n' "$OURS_WAS_INSTALLED"
  printf 'ST_PREV_ACCESSIBILITY_SERVICES=%q\n' "$PREV_SERVICES"
  printf 'ST_PREV_ACCESSIBILITY_ENABLED=%q\n' "$PREV_ACC_ENABLED"
} > "$STATE"
trap 'echo "ERROR: a command failed (line $LINENO); rolling back..." >&2; restore_state || true; exit 1' ERR
trap 'echo; echo "Interrupted; rolling back..." >&2; restore_state || true; exit 130' INT TERM

echo "Device:            $SERIAL"
echo "Home before test:  ${PREV_HOME:-none}"
if [ "$DISABLE_STOCK" = 1 ] && [ "$STOCK" != none ]; then
  echo "Stock launcher:    $STOCK (will be disabled during the test)"
else
  echo "Stock launcher:    $([ "$STOCK" = none ] && echo none || echo "$STOCK") (left enabled)"
fi
echo "State for restore: $STATE"

INSTALL_OUT=$(adb_cmd install -r "$APK" 2>&1) || true
echo "$INSTALL_OUT"
case "$INSTALL_OUT" in
  *Success*) ;;
  *) echo "ERROR: adb install failed." >&2; restore_state || true; exit 1 ;;
esac

# Start the launcher before the stock Home is touched, so a launcher that cannot start leaves the old
# one alone. Both halves matter: some builds answer "Status: ok" for a task merely brought to the front.
START_OUT=$(shell_cmd am start -W -n "$OURS_ACTIVITY") || true
echo "$START_OUT"
if ! printf '%s' "$START_OUT" | grep -qF 'Status: ok' || printf '%s' "$START_OUT" | grep -qi '^Error'; then
  echo "ERROR: the launcher did not start; the previous setup will be restored." >&2
  restore_state || true
  exit 1
fi

shell_cmd pm grant "$OURS" android.permission.ACCESS_FINE_LOCATION >/dev/null 2>&1 || true
shell_cmd cmd package compile -m speed -f "$OURS" >/dev/null 2>&1 || true
shell_cmd pm enable --user 0 "$OURS" >/dev/null 2>&1 || true
if [ "$DISABLE_STOCK" = 1 ] && [ "$STOCK" != none ]; then
  DISABLE_OUT=$(shell_cmd pm disable-user --user 0 "$STOCK") || true
  echo "$DISABLE_OUT"
  case "$DISABLE_OUT" in
    *disabled*) ;;
    *) echo "ERROR: could not disable $STOCK; restoring." >&2; restore_state || true; exit 1 ;;
  esac
fi
HOME_SET_OUT=$(shell_cmd cmd package set-home-activity --user 0 "$OURS_ACTIVITY") || true
echo "$HOME_SET_OUT"

HOME_NOW=$(query_home)
case "$HOME_NOW" in
  "$OURS"/*) echo "Home now resolves to $HOME_NOW" ;;
  *)
    echo "ERROR: Home resolves to '${HOME_NOW:-nothing}', not to the new launcher; restoring." >&2
    restore_state || true
    exit 1 ;;
esac

# Optional accessibility services, same as build-and-install.sh. Android turns them off on every
# reinstall, so pass the flag each run: INPUT_KEY_SERVICE=1 ./test-launcher.sh
enable_service() {
  local svc="$OURS/.$1" current
  current=$(shell_cmd settings get secure enabled_accessibility_services | tail -n 1)
  case "$current" in
    *"$1"*) ;;
    null|"") shell_cmd settings put secure enabled_accessibility_services "$svc" >/dev/null ;;
    *) shell_cmd settings put secure enabled_accessibility_services "$current:$svc" >/dev/null ;;
  esac
  shell_cmd settings put secure accessibility_enabled 1 >/dev/null
  echo "$1 enabled"
}
if [ "${INPUT_KEY_SERVICE:-0}" = 1 ]; then enable_service InputKeyService; fi
if [ "${HOME_KEY_SERVICE:-0}" = 1 ]; then enable_service HomeKeyService; fi

trap - ERR INT TERM
echo
echo "Test launcher installed on $SERIAL, and Home points at it."
echo "When you are done: ./test-launcher.sh --restore $SERIAL"
