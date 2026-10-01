---
name: ziptail
description: Use ziptail as a whiptail-compatible shell dialog, modern terminal UI, progress gauge, multi-field form, or linked presentation with adaptive color, glyph, mouse, and image support.
---

# ziptail

Use ziptail for interactive script prompts. It opens the controlling TTY for its UI and keeps returned values separate from normal stdout.

## Match whiptail invocation

Put shared options before the dialog. Use `HEIGHT WIDTH`; input/password defaults follow both dimensions.

```sh
ziptail --yesno "Deploy now?" 8 48
ziptail --msgbox "Saved." 8 48
ziptail --infobox "Starting..." 8 48
ziptail --inputbox "Service name" 8 52 "api"
ziptail --passwordbox "Token" 8 52
ziptail --textbox ./CHANGELOG.md 20 76
ziptail --menu "Choose a region" 12 58 4 west "West" east "East"
ziptail --checklist "Features" 12 58 4 logs "Logging" on metrics "Metrics" off
ziptail --radiolist "Environment" 12 58 4 dev "Development" on prod "Production" off
ziptail --form "Connection settings" 14 64 "Host" "localhost" "Port" "8080"
ziptail --presentation examples/presentation-tour.zdeck 20 92
```

For progress, pass the standard gauge stream on stdin: integer lines update percent; `XXX` / message / `XXX` changes the displayed text.

```sh
{
  printf 'XXX\nDownloading...\nXXX\n15\n'
  printf 'XXX\nInstalling...\nXXX\n75\n'
  printf '100\n'
} | ziptail --gauge "Setup" 8 56 0
```

Menu entries are tag/item pairs. Checklist and radiolist entries are tag/item/status triples with `on` or `off` status. `--default-item TAG` sets an initial menu/radiolist choice. `--notags` hides tags; `--noitem` hides descriptions.

## Capture output and statuses

Results default to file descriptor 2. Send them to stdout for command substitution:

```sh
service=$(ziptail --output-fd 1 --inputbox "Service name" 8 52 "api") || exit $?
```

Menus/radiolists return one tag; input/password dialogs return text; forms return one field value per line; checklists return quoted, space-separated tags. Use `--separate-output` for one raw tag per line. Yes/no and message dialogs do not write a value.

- `0`: accepted; Yes for yes/no.
- `1`: No or explicit cancel.
- `255`: Escape or Ctrl+C.

```sh
if ziptail --yesno "Delete the cache?" 8 48; then
  rm -rf "$cache_dir"
fi
```

## Adaptive presentation

- `--theme auto|classic|aurora|sunset|mono`: Auto selects the classic blue console palette for `TERM=linux`, and a richer palette when modern terminal capabilities/environment are detected. `NO_COLOR` always disables color; unsupported truecolor falls back to indexed color.
- `--glyphs auto|rounded|square|nerd|ascii`: Auto selects ASCII on Linux console/`TERM=dumb` and Unicode elsewhere. Nerd Font glyphs are opt-in (`--glyphs nerd` or `ZIPTAIL_GLYPHS=nerd`) because terminal protocols cannot report installed fonts.
- `--image FILE`: the image is loaded only if libvaxis detects Kitty graphics. Unsupported terminals skip the image and keep the dialog usable.
- `--no-animation`: disables entrance/spinner animation.
- `--topleft`, `--backtitle`, `--fullbuttons`, `--scrolltext`, `--clear`: whiptail presentation options.

Navigate lists with arrows or `j`/`k`; Space toggles; Enter accepts; Tab/left/right switches yes/no; Escape cancels. Textboxes scroll with arrows/PgUp/PgDn. Input fields support Left/Right, Home/End, Backspace/Delete, and Ctrl+U. Use `--defaultno` and `--nocancel` for yes/no behavior.

## Linked presentation screens

Use `--presentation FILE HEIGHT WIDTH` to run a `.zdeck` file. It defines named `[screen ID]` sections with explicit `next`/`previous` links, `scale=large`, and `transition=fade|slide_left|slide_right|cut`. On capable terminals Vaxis uses scaled text and animated transitions; otherwise it displays bold text and navigates without animation.

The deck may select its initial screen automatically from an installer result: set `[deck] result_env=STATUS`, `success_start=done`, and `failure_start=failed`. A screen-level `result_env` with `success`/`failure` links instead branches when the user presses Enter/Right. `body_env=LOG_TEXT` displays captured output. Deck files never execute commands; run the installer in a shell script, then export its status/output before launching ziptail. See `examples/installer-flow.sh` and `examples/installer-result.zdeck`.

Modern layouts negotiate mouse support and accept list clicks/wheel scrolling; `--no-mouse` disables it. Direct `TERM=linux` keeps the compact classic layout.

Run `ziptail --help` for the current mode/option list. Build with Zig 0.16.0 using `zig build`; run parser tests with `zig build test`.
