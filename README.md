# ziptail

ziptail is a Zig/libvaxis dialog program with a whiptail-compatible command line and an adaptive presentation layer. A direct Linux console keeps the compact blue, ASCII-friendly dialog style; capable modern terminals get a full-screen TUI shell with a session rail, responsive cards, pointer interaction, terminal-aware color, transitions, and optional Kitty graphics.

## Build and install

Requires Zig 0.16.0 and an interactive controlling TTY. The pinned libvaxis dependency is fetched on the first build.

```sh
zig build
zig build test
./zig-out/bin/ziptail --help
zig build -p "$HOME/.local"
```

The executable is installed under `bin/ziptail`. The build and package metadata are zest-compatible:

```sh
zest inspect .
zest install github.com/JustinWoodring/ziptail
```

## Whiptail-compatible dialogs

Put shared options before the dialog option. Arguments follow whiptail ordering: dimensions are `HEIGHT WIDTH`, and input/password defaults come after both dimensions.

```sh
ziptail --title "Ready?" --yesno "Deploy the release now?" 8 48
ziptail --msgbox "Configuration saved." 8 48
ziptail --infobox "Preparing deployment..." 8 48
ziptail --inputbox "Service name" 8 52 "api"
ziptail --passwordbox "Access token" 8 52
ziptail --textbox ./CHANGELOG.md 20 76
```

For multiple labeled values, use the additional form dialog. Accepted values are returned one per line:

```sh
ziptail --output-fd 1 --form "Connection settings" 14 64 \
  "Host" "localhost" \
  "Port" "8080"
```


Yes/no exits `0` for Yes, `1` for No, and `255` for Escape. Message and info boxes do not return text. Input/password boxes return the accepted value; password text is masked while typing. `--defaultno` selects No initially.

```sh
ziptail --default-item stable --menu "Choose a release channel" 12 58 4 \
  stable "Stable releases" \
  preview "Preview builds" \
  nightly "Nightly snapshots"

ziptail --checklist "Select components" 14 62 5 \
  core "Core utilities" on \
  docs "Documentation" off

ziptail --radiolist "Choose an environment" 12 58 4 \
  dev "Development" on \
  prod "Production" off
```

Menu entries are `TAG ITEM` pairs; checklist/radiolist entries are `TAG ITEM STATUS` triples (`on` or `off`). Menus and radiolists return the chosen tag. Checklists return quoted tags separated by spaces; `--separate-output` returns one raw tag per line.

Gauge mode reads the standard whiptail stream from stdin. A percent line updates progress; `XXX`, a text line, and another `XXX` replace the message:

```sh
printf 'XXX\nDownloading...\nXXX\n15\nXXX\nInstalling...\nXXX\n70\n100\n' \
  | ziptail --gauge "Setup" 8 56 0
```

## Linked presentations

Use a `.zdeck` file to define named screens and link them with `next` and `previous`. Screens can request `fade`, `slide_left`, or `slide_right` transitions and large headings. Large text uses Vaxis scaled text when the terminal reports support and falls back to a bold normal-size heading otherwise.

```sh
ziptail --presentation examples/presentation-tour.zdeck 20 92
```

Deck-level `result_env`, `success_start`, and `failure_start` automatically choose the initial screen from a command result. A screen can also branch on Enter with `result_env`, `success`, and `failure`; `body_env` displays captured command output. `examples/installer-flow.sh` runs a command, captures its log/status, and opens its success or failure screen. Deck files never execute commands.

## Options

The whiptail option set includes `--title`, `--backtitle`, `--default-item`, `--defaultno`, `--clear`, `--fb`/`--fullbuttons`, `--nocancel`, `--yes-button`, `--no-button`, `--ok-button`, `--cancel-button`, `--noitem`, `--notags`, `--separate-output`, `--output-fd`, `--scrolltext`, and `--topleft`. `--no-mouse` disables pointer support in modern layouts.

Presentation options:

- `--theme auto|classic|aurora|sunset|mono`: `auto` uses the classic palette for `TERM=linux`/`dumb`, selects the richer Aurora palette for recognized modern emulators/capabilities, and otherwise stays conservative. Truecolor is used when reported; indexed color is the fallback. `NO_COLOR` always disables color.
- `--glyphs auto|rounded|square|nerd|ascii`: auto uses ASCII on the Linux console and `TERM=dumb`, rounded Unicode elsewhere. Nerd Font glyphs are opt-in with `--glyphs nerd` or `ZIPTAIL_GLYPHS=nerd`; terminal protocols cannot reliably detect the configured font.
- `--image FILE`: loads and displays an image only after libvaxis reports Kitty graphics support (Kitty and compatible terminals). On unsupported terminals the image is skipped; the dialog and its text/glyph fallback remain usable.
- `--no-animation`: disables the entrance and spinner.

The UI uses the controlling terminal, so command substitution does not capture escape sequences. Results go to file descriptor 2 by default; set `--output-fd 1` to capture them:

```sh
name=$(ziptail --output-fd 1 --inputbox "Your name" 8 52 "Ada") || exit $?
if ziptail --yesno "Remove generated files?" 8 48; then
  rm -rf build-output
fi
```

Keyboard: arrows or `j`/`k` navigate; Space toggles list items; Enter accepts; Tab/left/right changes the yes/no choice; Escape cancels; text fields support Left/Right, Home/End, Backspace/Delete, and Ctrl+U. Textboxes scroll with arrows or PgUp/PgDn.

```sh
zig build -Doptimize=ReleaseSafe
zig build -p dist -Doptimize=ReleaseSafe
zig build test
```
## Examples

Runnable shell examples, linked presentation decks, a full setup wizard, streaming progress, and a conditional installer-result flow are in [`examples/`](examples/README.md). Run scripts from the repository root or set `ZIPTAIL_BIN` to the installed executable.
