#!/bin/sh
set -u

if [ "$#" -eq 0 ]; then
  printf 'usage: %s INSTALLER [ARG ...]\n' "$0" >&2
  exit 2
fi

ziptail=${ZIPTAIL_BIN:-./zig-out/bin/ziptail}
script_dir=$(dirname "$0")
log=$(mktemp "${TMPDIR:-/tmp}/ziptail-installer.XXXXXX") || exit 1
trap 'rm -f "$log"' EXIT HUP INT TERM

if "$@" >"$log" 2>&1; then
  installer_status=0
  result=success
else
  installer_status=$?
  result=failure
fi

output=$(tail -n 24 "$log")
ZIPTAIL_INSTALL_STATUS=$result ZIPTAIL_INSTALL_OUTPUT="$output" \
  "$ziptail" --presentation "$script_dir/installer-result.zdeck" 20 96
ui_status=$?
if [ "$ui_status" -ne 0 ]; then
  exit "$ui_status"
fi
exit "$installer_status"
