# AGENTS.md

Rembrandt is a desktop app made with [nanoui](https://github.com/justrach/nanoui)
in Zig 0.17: native UI drawn by nanoui itself (Metal on macOS, its own CPU
renderer on Linux and Windows), from one codebase.

## Commands

```sh
zig build -Doptimize=ReleaseFast       # optimized app
zig build test -Doptimize=ReleaseFast  # optimized tests
nui build                       # compile (zig build; Debug)
nui test                        # the tests: views rendered offscreen with ui.Tester
nui snapshot --out shot.png     # build, then render the app to a PNG, no window
nui snapshot --out shot.png --script "click:Increment;click:Increment"
nui run                         # open the app's window (for people, not agents)
nui doctor                      # check Zig and the platform
```

Every command takes `--json` for output a program can read.

## Backend

Rembrandt posts to an OpenAI-compatible `POST /v1/images/generations`, or
`POST /v1/images/edits` with JSON data URLs when reference images are attached,
and reads `data[0].b64_json`. Any compatible service works. The in-app Backend
sheet changes the base URL, model and API key; environment values are the
defaults. Its Quality and Complexity chips set the Images 2.6 `quality` and
`complexity` request fields; both are omitted while `auto`, so older or local
backends receive exactly the request they did before.

| Variable | Default |
| --- | --- |
| `REMBRANDT_BASE_URL` | `http://127.0.0.1:3425/v1` |
| `REMBRANDT_API_KEY` | empty (no Authorization header) |
| `REMBRANDT_MODEL` | empty (server default) |
| `REMBRANDT_SIZE` | `1536x1024` |
| `REMBRANDT_QUALITY` | `auto`; `low`, `medium` or `high` is sent as `quality` |
| `REMBRANDT_COMPLEXITY` | `auto`; `low`, `medium` or `high` is sent as `complexity` |
| `REMBRANDT_FORMAT` | `png` (default), `gif` or `svg`; sent as `output_format` |
| `REMBRANDT_FRAMES` | `2`-`16`; sent as `frame_count` for GIFs |
| `REMBRANDT_FRAME_MS` | `20`-`60000`; sent as `frame_duration_ms` for GIFs |
| `REMBRANDT_REFERENCES` | empty; preload paths separated by `;` on Windows or `:` on macOS/Linux |

Base URL, model, size, quality, complexity and the output format (with GIF
frame count and delay) persist in `%APPDATA%\Rembrandt\settings.json` (or the
platform's app-data directory); the API key is memory-only. Results go to
`Documents/Rembrandt/rembrandt-<timestamp>.png`.

`REMBRANDT_PROMPT` prefills the composer, and `REMBRANDT_DEMO_IMAGE` preloads
a PNG into the recent list; both are for snapshots and manual checking.
References accept PNG/JPEG/WebP: 16 files, 14 MiB each, 40 MiB combined.
They are not persisted. Changes during generation apply to the next request;
there is no automatic retry with multipart or generations after an edits error.
Python examples in `docs/reference-images-plan.md` cover portable probes.

The running app writes a synchronous log to
`%LOCALAPPDATA%\Rembrandt\rembrandt.log` (previous run as `.1`), or the path
in `REMBRANDT_LOG`; `REMBRANDT_LOG=off` disables it. The key and prompt text
are never logged. A GUI app's stderr is invisible on Windows, so check this
file when a launch exits unexpectedly.

An end-to-end check against a local backend:

```sh
REMBRANDT_PROMPT="A ripe persimmon on warm paper" \
  nui snapshot --out shot.png --script "click:Generate;live:95"
```

## Window

The Windows header is the title bar. `src/win_frame.zig` removes the system
caption (keeping resize edges, shadow and rounded corners) and sets the icon;
`State.header` draws the draggable header and `State.caption` draws the window
buttons. Do not re-add a native caption or a second title bar. The icon source
is `assets/rembrandt.svg`, rasterized to `assets/rembrandt.ico` and embedded
by `assets/rembrandt.rc`.

## Rules

- **Never open windows while working.** Check what the app looks like with
  `nui snapshot` (open the PNG), and what it does with tests through
  `ui.Tester` (`src/tests.zig`). `nui run` is for people.
- **A view is a function of the state.** `State.view` in `src/app.zig` draws
  everything each frame; widgets report input as they're drawn
  (`if (ui.button(c, "Save", .{}).clicked) …`). Keep ids stable with
  `ui.key(c, …)` for items in lists.
- **Every behavior gets a test** in `src/tests.zig`: `t.clickText`,
  `t.typeText`, `t.hasText`, `t.screenshot("/tmp/x.png")`.
- Actual Generate tests in `src/tests_generation.zig` use an ephemeral
  loopback server and temporary saves; they never call the real backend.
- GIF and SVG results save as `.gif`/`.svg`. A GIF preview is decoded once
  per selected result into PNG frames (`src/gif.zig`); an unreadable GIF or
  SVG shows a fallback in the preview and still offers Open and Copy path.
- Reference removal/Clear is deferred until the next view, before drawing:
  `ui.image` retains the previous view's source bytes until painting finishes.
  Guard PNG thumbnail dimensions before calling it; a small display size does
  not bound decoding memory.
- **Keep files under 600 lines.** `app.zig` is near the limit; put
  persistence/parsing in `src/settings_store.zig` or `src/backend.zig`.
- Script steps for `--script`: `click:TEXT`, `type:TEXT`, `key:enter`,
  `wait:SECONDS`, `live:SECONDS` (the real event loop), separated by `;`.

## Layout

```text
build.zig            the app, `run` and `test` steps
build.zig.zon        nanoui, pinned
assets/rembrandt.svg the icon source
assets/rembrandt.ico the Windows icon
assets/rembrandt.rc  embeds the icon in the exe
src/main.zig         the window and frame
src/app.zig          the state and its view
src/controls.zig     shared buttons, chips, and press feedback
src/win_frame.zig    Windows caption removal, drag hit testing, icon
src/settings_store.zig persisted base URL/model/size/quality/format/frames
src/gif.zig          GIF frame compositing into preview PNGs
src/playback.zig     the selected GIF's frame clock and preview
src/tests_formats.zig GIF/SVG requests, decoding, saving and controls
src/log.zig          synchronous file log for the running app
src/backend.zig      OpenAI-compatible config, JSON and PNG decoding
src/generation.zig   request submission, callback and saving
src/references.zig   owned reference bytes, input limits and drop paths
src/theme.zig        the paper/pine palette
src/mark.svg         the header mark
src/tests.zig        the view's tests
src/tests_generation.zig real Generate requests against a loopback stub
```

nanoui's README lists the widgets (`ui.div(c).row().gap(8)…`, text,
buttons, inputs, lists), `nanoui.kit` (menus, dialogs, toasts, tabs) and
`ui.motion` (springs, presence, layout animation).
