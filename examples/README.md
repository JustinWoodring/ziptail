# Examples

Set `ZIPTAIL_BIN` when running from a checkout; otherwise each script uses `ziptail` from `PATH`.

```sh
ZIPTAIL_BIN=./zig-out/bin/ziptail ./examples/setup-wizard.sh
ZIPTAIL_BIN=./zig-out/bin/ziptail ./examples/progress.sh
ZIPTAIL_BIN=./zig-out/bin/ziptail ./examples/installer-flow.sh sh -c 'echo install log; exit 1'
```

- `setup-wizard.sh`: message, yes/no, input, multi-field form, checklist, password, gauge, then a linked presentation.
- `progress.sh`: streaming gauge updates using the whiptail `XXX` protocol.
- `installer-flow.sh` and `installer-result.zdeck`: run a command, capture its output and status, then branch to success or failure screens.
- `presentation-tour.zdeck`: named screens linked with `next`/`previous`, large text, and fade/slide transitions.

## Presentation deck format

A `.zdeck` file has a `[deck]` section and named `[screen ID]` sections. Screen metadata appears before `---`; all following lines until the next section are that screen's body.

```ini
[deck]
title = Release walkthrough
start = result
result_env = BUILD_STATUS
success_start = done
failure_start = failed

[screen result]
title = Build output
body_env = BUILD_LOG
transition = fade
---
The build log appears here.

[screen done]
title = Build succeeded
scale = large
transition = slide_left
---
Press Enter to close.

[screen failed]
title = Build failed
scale = large
transition = slide_right
---
Review the log and retry.
```

Deck-level `result_env` selects `success_start` when its value is `0`, `success`, `ok`, or `true`; other values select `failure_start` before the first screen appears. A screen-level `result_env` with `success` and `failure` links waits for Enter/Right before branching. `body_env` displays a captured environment value. `transition` accepts `cut`, `fade`, `slide_left`, or `slide_right`; `scale` accepts `normal` or `large`. Large text uses terminal scaling when reported and falls back to a bold headline otherwise.

Deck bodies from environment variables are sanitized before rendering. Decks never execute commands; run external work in a shell script, capture its result/output, and export those values before starting ziptail.
