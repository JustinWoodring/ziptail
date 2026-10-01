#!/bin/sh
set -u
ziptail=${ZIPTAIL_BIN:-./zig-out/bin/ziptail}

{
  printf 'XXX\nConnecting to the package registry...\nXXX\n8\n'
  sleep 1
  printf '24\n'
  sleep 1
  printf 'XXX\nResolving dependencies...\nXXX\n53\n'
  sleep 1
  printf '78\n'
  sleep 1
  printf 'XXX\nFinalizing installation...\nXXX\n94\n'
  sleep 1
  printf '100\n'
} | "$ziptail" --title "Package installation" --gauge "Please wait" 9 64 0
