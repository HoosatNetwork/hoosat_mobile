#!/usr/bin/env bash
set -euo pipefail

# Create (if missing) and start an Android emulator (AVD).
#
# Usage:
#   tools/android_emulator.sh [--name <avdName>] [--image <sdkPackage>] [--device <deviceId>]
#                            [--serial <adbSerial>] [--wipe-data] [--no-wait] [--] [extra emulator args...]
#
# Examples:
#   tools/android_emulator.sh
#   tools/android_emulator.sh --name hoosat_api36
#   tools/android_emulator.sh --name my_avd --image "system-images;android-36;google_apis;x86_64"
#   tools/android_emulator.sh --wipe-data -- -memory 4096

DEFAULT_AVD_NAME="hoosat_api36"
DEFAULT_IMAGE="system-images;android-36;google_apis;x86_64"

avd_name="$DEFAULT_AVD_NAME"
image_pkg="$DEFAULT_IMAGE"
device_id=""
adb_serial=""
wipe_data="0"
wait_for_boot="1"
extra_emulator_args=()

usage() {
  sed -n '1,120p' "$0" | sed -n '1,50p' >&2
}

die() {
  echo "Error: $*" >&2
  exit 1
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      avd_name="${2:-}"; shift 2;;
    --image)
      image_pkg="${2:-}"; shift 2;;
    --device)
      device_id="${2:-}"; shift 2;;
    --serial)
      adb_serial="${2:-}"; shift 2;;
    --wipe-data)
      wipe_data="1"; shift 1;;
    --no-wait)
      wait_for_boot="0"; shift 1;;
    --help|-h)
      usage; exit 0;;
    --)
      shift
      extra_emulator_args+=("$@")
      break;;
    *)
      extra_emulator_args+=("$1")
      shift 1;;
  esac
done

[[ -n "$avd_name" ]] || die "--name requires a value"
[[ -n "$image_pkg" ]] || die "--image requires a value"

# Resolve SDK root
sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$sdk_root" ]]; then
  if [[ -d "$HOME/Android/Sdk" ]]; then
    sdk_root="$HOME/Android/Sdk"
  elif [[ -d "/opt/android-sdk" ]]; then
    sdk_root="/opt/android-sdk"
  else
    die "ANDROID_SDK_ROOT/ANDROID_HOME not set and no SDK found at ~/Android/Sdk or /opt/android-sdk"
  fi
fi

# Resolve tools
adb_bin="${sdk_root}/platform-tools/adb"
[[ -x "$adb_bin" ]] || adb_bin="$(command -v adb || true)"
[[ -n "$adb_bin" && -x "$adb_bin" ]] || die "adb not found (expected at $sdk_root/platform-tools/adb)"

emulator_bin=""
if [[ -x "${sdk_root}/emulator/emulator" ]]; then
  emulator_bin="${sdk_root}/emulator/emulator"
elif [[ -x "${sdk_root}/tools/emulator" ]]; then
  emulator_bin="${sdk_root}/tools/emulator"
else
  emulator_bin="$(command -v emulator || true)"
fi
[[ -n "$emulator_bin" && -x "$emulator_bin" ]] || die "emulator binary not found"

# avdmanager/sdkmanager live in different places depending on SDK layout
avdmanager_bin=""
for candidate in \
  "${sdk_root}/cmdline-tools/latest/bin/avdmanager" \
  "${sdk_root}/cmdline-tools/bin/avdmanager" \
  "${sdk_root}/tools/bin/avdmanager"; do
  if [[ -x "$candidate" ]]; then avdmanager_bin="$candidate"; break; fi
done
[[ -n "$avdmanager_bin" ]] || avdmanager_bin="$(command -v avdmanager || true)"

sdkmanager_bin=""
for candidate in \
  "${sdk_root}/cmdline-tools/latest/bin/sdkmanager" \
  "${sdk_root}/cmdline-tools/bin/sdkmanager" \
  "${sdk_root}/tools/bin/sdkmanager"; do
  if [[ -x "$candidate" ]]; then sdkmanager_bin="$candidate"; break; fi
done
[[ -n "$sdkmanager_bin" ]] || sdkmanager_bin="$(command -v sdkmanager || true)"

adb_cmd=("$adb_bin")
if [[ -n "$adb_serial" ]]; then
  adb_cmd+=("-s" "$adb_serial")
fi

avd_exists() {
  "$emulator_bin" -list-avds 2>/dev/null | tr -d '\r' | grep -qx "$avd_name"
}

image_installed() {
  # Derive a likely filesystem path: system-images;android-36;google_apis;x86_64
  IFS=';' read -r _ kind api tag abi <<<"$image_pkg" || true
  [[ -n "${kind:-}" && -n "${api:-}" && -n "${tag:-}" && -n "${abi:-}" ]] || return 1
  [[ -d "${sdk_root}/system-images/${api}/${tag}/${abi}" ]]
}

choose_default_device() {
  [[ -n "$device_id" ]] && return 0
  if [[ -n "$avdmanager_bin" && -x "$avdmanager_bin" ]]; then
    if "$avdmanager_bin" list device 2>/dev/null | grep -q "id: pixel_7"; then
      device_id="pixel_7"
      return 0
    fi
    if "$avdmanager_bin" list device 2>/dev/null | grep -q "id: pixel"; then
      device_id="pixel"
      return 0
    fi
    # Fall back to the first listed id
    device_id="$($avdmanager_bin list device 2>/dev/null | awk '/^id: /{print $2; exit}')"
  fi
  [[ -n "$device_id" ]] || device_id="pixel"
}

install_image_if_needed() {
  if image_installed; then
    return 0
  fi
  if [[ -z "$sdkmanager_bin" || ! -x "$sdkmanager_bin" ]]; then
    die "System image not installed and sdkmanager not found. Install '$image_pkg' via Android SDK Manager."
  fi

  echo "Installing Android SDK packages (this can take a while)..." >&2
  yes | "$sdkmanager_bin" --licenses >/dev/null || true
  "$sdkmanager_bin" --install "platform-tools" "emulator" "$image_pkg"
}

create_avd_if_needed() {
  if avd_exists; then
    return 0
  fi
  [[ -n "$avdmanager_bin" && -x "$avdmanager_bin" ]] || die "avdmanager not found; cannot create AVD"

  choose_default_device
  install_image_if_needed

  echo "Creating AVD '$avd_name' ($image_pkg, device=$device_id)..." >&2
  # avdmanager may prompt about custom hardware profile; 'no' keeps defaults.
  echo "no" | "$avdmanager_bin" create avd --force -n "$avd_name" -k "$image_pkg" --device "$device_id"
}

start_emulator() {
  local args=("-avd" "$avd_name" "-netdelay" "none" "-netspeed" "full" "-no-audio" "-no-boot-anim" "-no-snapshot")
  if [[ "$wipe_data" == "1" ]]; then
    args+=("-wipe-data")
  fi
  # Try to keep GPU stable across Linux hosts
  args+=("-gpu" "swiftshader_indirect")
  args+=("${extra_emulator_args[@]}")

  # Launch in background; emulator writes logs to stderr.
  echo "Starting emulator '$avd_name'..." >&2
  nohup "$emulator_bin" "${args[@]}" >/tmp/"${avd_name}".out 2>/tmp/"${avd_name}".err &
}

wait_boot_completed() {
  if [[ "$wait_for_boot" != "1" ]]; then
    return 0
  fi

  echo "Waiting for device via adb..." >&2
  "${adb_cmd[@]}" wait-for-device

  echo "Waiting for Android boot to complete..." >&2
  local boot=""
  for _ in $(seq 1 180); do
    boot="$("${adb_cmd[@]}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    if [[ "$boot" == "1" ]]; then
      echo "Boot completed." >&2
      return 0
    fi
    sleep 1
  done

  die "Timed out waiting for sys.boot_completed=1 (check /tmp/${avd_name}.err)"
}

main() {
  create_avd_if_needed

  # If a device is already connected, don’t start a second one unless wipe-data was requested.
  if "${adb_cmd[@]}" devices | awk 'NR>1 && $1 ~ /^emulator-/ {print $1}' | grep -q .; then
    echo "An emulator is already connected via adb." >&2
  else
    start_emulator
  fi

  wait_boot_completed

  echo "Connected devices:" >&2
  "${adb_cmd[@]}" devices -l >&2
}

main
