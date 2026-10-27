#!/usr/bin/env bash
# Small device helper for the Shiying project.
#
# Usage:
#   bash Scripts/device.sh doctor
#   bash Scripts/device.sh bundle
#   bash Scripts/device.sh install [path/to/Shiying.ipa]
#   bash Scripts/device.sh launch [--env KEY=VALUE ...]
#   bash Scripts/device.sh screenshot [out.png]
#   bash Scripts/device.sh logs [out.log]
#   bash Scripts/device.sh logstream
#
# Requirements: xtool, pymobiledevice3, and (on WSL) USBMUXD_SOCKET_ADDRESS.
# The script never writes to the app container; `logs` only pulls a file.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PMD3="${PMD3:-$HOME/.venvs/pmd3/bin/pymobiledevice3}"
IPA="${IPA:-$ROOT/Shiying/xtool/Shiying.ipa}"

if [ -z "${USBMUXD_SOCKET_ADDRESS:-}" ] && command -v ip >/dev/null 2>&1; then
  gateway="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
  if [ -n "${gateway:-}" ]; then
    export USBMUXD_SOCKET_ADDRESS="$gateway:27015"
  fi
fi

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

require_pmd3() {
  if [ ! -x "$PMD3" ]; then
    echo "pymobiledevice3 not found at $PMD3" >&2
    echo "Set PMD3=/path/to/pymobiledevice3 or create ~/.venvs/pmd3." >&2
    exit 1
  fi
}

bundle_id() {
  require_pmd3
  local output bundle
  output="$("$PMD3" apps list 2>/dev/null)" || return 1
  bundle="$(printf '%s' "$output" | python3 -c '
import json, sys
apps = json.load(sys.stdin)
for name in apps:
    low = name.lower()
    if "shiying" in low and not low.endswith(".share"):
        print(name)
        break
' 2>/dev/null)"
  if [ -z "$bundle" ]; then
    bundle="$(printf '%s\n' "$output" | sed -nE 's/^ *"([^"]*shiying[^"]*)": *\{$/\1/p' | grep -v '\.share$' | head -1)"
  fi
  if [ -z "$bundle" ]; then
    echo "Shiying is not installed (or the free-signing prefix changed)" >&2
    return 1
  fi
  echo "$bundle"
}

case "${1:-}" in
  doctor)
    echo "USBMUXD_SOCKET_ADDRESS=${USBMUXD_SOCKET_ADDRESS:-<unset>}"
    if command -v xtool >/dev/null 2>&1; then
      xtool --version
      xtool devices --usb --no-wait 2>&1 | tail -20
    else
      echo "xtool: not found"
    fi
    if command -v swift >/dev/null 2>&1; then
      swift --version | head -1
    else
      echo "swift: not found"
    fi
    require_pmd3
    echo "bundle: $(bundle_id 2>&1)"
    ;;
  bundle)
    bundle_id
    ;;
  install)
    xtool install --usb "${2:-$IPA}"
    ;;
  launch)
    shift
    bundle="$(bundle_id)" || exit 1
    echo "launch $bundle"
    "$PMD3" developer dvt launch "$bundle" --userspace --kill-existing "$@"
    ;;
  screenshot)
    require_pmd3
    out="${2:-/tmp/shiying.png}"
    "$PMD3" developer dvt screenshot "$out" --userspace
    echo "$out"
    ;;
  logs)
    require_pmd3
    bundle="$(bundle_id)" || exit 1
    out="${2:-$ROOT/shiying.log}"
    if "$PMD3" apps pull "$bundle" "ShiyingLogs/shiying.log" "$out" --documents; then
      echo "$out"
    else
      echo "无法通过 USB 读取日志：部分 iOS 26 + 免费签名环境会返回 InstallationLookupFailed。" >&2
      echo "请改用 App 内导出：设置 → 诊断 → 导出运行日志。" >&2
      echo "实时系统日志：bash Scripts/device.sh logstream" >&2
      exit 1
    fi
    ;;
  logstream)
    require_pmd3
    "$PMD3" syslog live -m Shiying
    ;;
  *)
    usage
    exit 1
    ;;
esac
