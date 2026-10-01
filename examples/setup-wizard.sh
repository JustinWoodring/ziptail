#!/bin/sh
set -u

ziptail=${ZIPTAIL_BIN:-ziptail}
script_dir=$(dirname "$0")

if "$ziptail" --title "First run" --msgbox "Let's configure your service." 8 48; then
  :
else
  exit $?
fi

if "$ziptail" --title "First run" --yesno "Configure a new service now?" 8 52; then
  :
else
  exit $?
fi

project=$("$ziptail" --output-fd 1 --inputbox "Project name" 8 56 "example-api") || exit $?
connection=$("$ziptail" --output-fd 1 --form "Connection settings" 14 64 \
  "Host" "localhost" \
  "Port" "8080") || exit $?
host=$(printf '%s\n' "$connection" | sed -n '1p')
port=$(printf '%s\n' "$connection" | sed -n '2p')
components=$("$ziptail" --output-fd 1 --separate-output --checklist "Select components" 14 62 5 \
  logs "Structured logging" on \
  metrics "Metrics endpoint" off \
  docs "API documentation" on) || exit $?
secret=$("$ziptail" --output-fd 1 --passwordbox "Deployment token" 8 56) || exit $?

{
  printf 'XXX\nPreparing %s...\nXXX\n10\n' "$project"
  sleep 1
  printf 'XXX\nChecking connection to %s:%s...\nXXX\n45\n' "$host" "$port"
  sleep 1
  printf 'XXX\nWriting configuration...\nXXX\n80\n'
  sleep 1
  printf '100\n'
} | "$ziptail" --gauge "Setup" 8 58 0 || exit $?

summary=$(printf 'Project: %s\nEndpoint: %s:%s\nComponents:\n%s\nToken: configured' \
  "$project" "$host" "$port" "$components")
ZIPTAIL_INSTALL_STATUS=success ZIPTAIL_INSTALL_OUTPUT="$summary" \
  "$ziptail" --presentation "$script_dir/presentation-tour.zdeck" 20 92
