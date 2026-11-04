# Reference images: implementation plan

Status: implemented and verified locally; verification notes and remaining
platform checks are recorded below.

## Goal

Let a prompt carry up to 16 reference images, the way the OpenAI image
family supports them: send them to `POST /v1/images/edits` and keep the
current text-only path (`/v1/images/generations`) when nothing is attached.

Sources for a reference:

1. the native file picker (primary on Windows, where nanoui does not yet
   deliver OS drops),
2. drag and drop onto the composer (works where nanoui delivers drops,
   macOS today),
3. "Use as reference" on the selected result, so iterating is one click,
4. `REMBRANDT_REFERENCES` for snapshots and end-to-end checks.

Not in scope for v1: masks/markup painting, reference URLs typed by hand,
persisting references across launches, multi-select in nanoui's Windows
file dialog.

## Baseline before implementation

- `src/backend.zig:163` `buildBody` emits `{"model"?, "prompt", "n", "size"}`.
- `src/app.zig:433` always POSTs to `{base}/images/generations`.
- `src/backend.zig:157` `normalize` only strips a pasted `/images/generations`.
- The composer (`src/app.zig:140`) has prompt, model chip, size chip, a fixed
  "1 image" label, and Generate. There is no attach affordance anywhere.
- `src/app.zig` is 503 lines; `AGENTS.md` asks for files under 600, so the
  new work goes into `src/references.zig` and `src/controls.zig`. Submission
  and saving now live in `src/generation.zig` to keep the view below 600 lines.

## API contract

Verified during review against OpenAI's
[Create image edit reference](https://developers.openai.com/api/reference/resources/images/methods/edit).

`POST /v1/images/edits`, `application/json`:

```json
{
  "model": "gpt-image-2.5-sunburst",
  "prompt": "Put this pendant on warm paper",
  "images": [
    { "image_url": "data:image/png;base64,…" },
    { "image_url": "data:image/jpeg;base64,…" }
  ],
  "n": 1,
  "size": "1536x1024"
}
```

- Each `images` entry takes exactly one of `file_id` (an uploaded file ID)
  or `image_url` (a fully qualified URL or base64 data URL).
- Up to 16 images per request for GPT Image models; PNG, JPEG or WebP.
- Each `image_url` is limited to 20,971,520 characters, including the data
  URL prefix and base64 payload. This is an encoded limit, not a source-file
  byte limit.
- The response is the same `data[0].b64_json` we already parse, so
  `backend.parse` and `backend.decodePng` need no changes.
- `model` is optional in our body, exactly as today: omit it for the
  server's default.
- Multipart is also supported (`image[]` binary fields). It is a fallback,
  not the default; see step 7 under Order of work.

A probe before building anything (Python 3 standard library, using a real
1×1 PNG). Save as `probe.py` and run with the platform's Python 3 command
(`python`, `python3`, or `py -3`); no shell-specific syntax is required:

```python
import json
import os
import urllib.error
import urllib.request

png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
body = {
    "prompt": "Turn this into a red dot on white paper",
    "images": [{"image_url": "data:image/png;base64," + png}],
    "size": "1024x1024",
    "n": 1,
}
if os.environ.get("REMBRANDT_MODEL"):
    body["model"] = os.environ["REMBRANDT_MODEL"]
headers = {"Content-Type": "application/json"}
if os.environ.get("REMBRANDT_API_KEY"):
    headers["Authorization"] = "Bearer " + os.environ["REMBRANDT_API_KEY"]
url = os.environ["REMBRANDT_BASE_URL"].rstrip("/") + "/images/edits"
request = urllib.request.Request(url, json.dumps(body).encode(), headers)
try:
    response = urllib.request.urlopen(request, timeout=240)
except urllib.error.HTTPError as error:
    response = error  # Preserve status and body for HTTP failures too.
except (urllib.error.URLError, TimeoutError) as error:
    raise SystemExit(f"Probe transport failed: {error}")
with response:
    status = response.code
    text = response.read().decode("utf-8", errors="replace")
print(f"HTTP {status}")
if status != 200:
    print(text)
    raise SystemExit(1)
result = json.loads(text)
image = result.get("data", [{}])[0].get("b64_json") if result.get("data") else None
if not image:
    raise SystemExit("Missing generated image.")
print(f"Received image: {len(image)} base64 characters")
```

Set `REMBRANDT_BASE_URL` to the intended normalized base ending in `/v1`;
this probe uses environment values, not persisted app settings. A successful
call generates an image and may incur cost. Inspect the status and error
body locally; record the outcome without credentials or image payloads.

- 401/403: resolve authentication/access before judging the wire format.
- 404: inspect whether the route or model is missing. Multipart uses the
  same route, so 404 alone does not justify switching formats.
- 400/415/422: inspect the error for unsupported JSON, `images`, or data URLs;
  distinguish those from a bad model, invalid image, or other parameter.
- When the error identifies a format mismatch, compare with a multipart
  probe using the same decoded PNG, prompt, model, and size. Move step 7
  into the backend step only if multipart succeeds. Otherwise resolve the
  backend gap before UI work. Never retry automatically in the app.

## Decisions

| Question | Decision | Why |
| --- | --- | --- |
| Wire format | JSON + `data:` URLs | Documented; no multipart encoder; no file-upload round trip |
| Endpoint choice | `/edits` iff at least one reference | `/generations` ignores `images`; keeps the old path untouched |
| Limits | 16 files, 14 MiB each, 40 MiB total; data URL ≤20,971,520 characters | 14 MiB leaves room for base64 expansion and prefix; 40 MiB source ≈53.3 MiB base64, plus a fetch copy; measure total memory separately |
| Formats | PNG, JPEG, WebP, sniffed from bytes | The API's set; trust the bytes, not the extension |
| Thumbnails | Guard PNG dimensions before `ui.image`; use a MIME tile when too large or unsupported | Portable nanoui fully decodes PNGs before shrinking; a 40×40 display size does not bound decode memory |
| After Generate | Keep references | Iterating on the same subject is the point; Clear is one click |
| During generation | Allow reference changes; apply them to the next request | `http.fetch` copies the submitted body; show this rule beside the strip |
| Persistence | None | Matches history; refs are working state, not settings |
| Duplicates | Allowed | Same file twice is occasionally deliberate; ids keep widget keys unique |

## Data model

New file `src/references.zig` (~190 lines):

```zig
pub const Limits = struct {
    max_refs: usize = 16,
    max_file_bytes: usize = 14 * 1024 * 1024,
    max_total_bytes: usize = 40 * 1024 * 1024,
};

pub const Mime = enum { png, jpeg, webp };

pub const Ref = struct {
    id: u64,          // stable widget key, unique even for identical files
    bytes: []u8,      // owned
    name: []u8,       // owned, display only (basename)
    mime: Mime,
    width: u32 = 0,   // from the PNG header when it is a PNG
    height: u32 = 0,
};

pub const List = struct {
    items: std.ArrayList(Ref) = .empty,
    total: usize = 0,
    next_id: u64 = 1,
    limits: Limits = .{},

    pub fn deinit(l: *List, gpa: std.mem.Allocator) void;
    pub fn addPath(l: *List, gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void;
    pub fn addBytes(l: *List, gpa: std.mem.Allocator, name: []const u8, bytes: []const u8) !void;
    pub fn remove(l: *List, gpa: std.mem.Allocator, i: usize) void;
    pub fn clear(l: *List, gpa: std.mem.Allocator) void;
};

pub fn sniff(bytes: []const u8) ?Mime;
pub fn reason(e: anyerror) []const u8;      // one line of user-facing copy
pub fn pathFromUrl(gpa: std.mem.Allocator, url: []const u8) !?[]u8;
```

Notes:

- The `List` does **not** store `gpa`: the app already hands the allocator to
  `config`, `prompt`, and `history`, and `initDefault` can then return a plain
  struct literal. This matches `history`, which owns nothing at construction.
- References own a copy of their bytes. History items are evicted (8 slots)
  and their bytes freed, so a reference may not alias `history[i]`.
- `addPath` reads with `readFileAlloc(..., .limited(limit + 1))`: Zig's read
  limit is exclusive, so this accepts a file exactly at the cap. Huge files
  fail before being fully read; map `error.StreamTooLong` to "larger than 14 MiB".
- `addBytes` duplicates the name and copies the bytes; check the same limits.
- After sniffing MIME, require `data:` prefix length plus
  `std.base64.standard.Encoder.calcSize(bytes.len)` ≤20,971,520 before
  accepting bytes. Share this check with the edit builder, which must also
  enforce it for callers that bypass `List`. Use `error.EncodedTooLarge`.
- `pathFromUrl` handles `file:///C:/x.png`, `file://server/share/x.png`,
  percent-escapes (`%20`), and leaves plain paths alone. It returns an owned
  string; `null` for non-file schemes, an error for malformed or NUL escapes.
- MIME sniffing: PNG signature, `FF D8 FF` for JPEG, `RIFF....WEBP` for WebP.
  Never trust the extension; an unknown file is `error.NotAnImage`.
- `reason` keeps the copy in one place:
  - TooMany → "Up to 16 reference images."
  - TooLarge → "That image is larger than 14 MiB."
  - EncodedTooLarge → "That image exceeds the encoded reference limit."
  - TotalTooLarge → "References would exceed 40 MiB in total."
  - NotAnImage → "References must be PNG, JPEG or WebP."
  - EmptyFile → "That file is empty."
  - else → "Could not read that file."

## Request building

`src/backend.zig` (+~70 lines):

```zig
pub const RefInput = struct { bytes: []const u8, mime: []const u8 };

pub fn endpointFor(has_refs: bool) []const u8 {
    return if (has_refs) "/images/edits" else "/images/generations";
}

pub fn buildEditBody(
    gpa: std.mem.Allocator,
    cfg: *const Config,
    prompt: []const u8,
    refs: []const RefInput,
) ![]u8;
```

Implementation details that matter:

- Build with `std.ArrayList(u8)` and encode directly into it to avoid a
  separate base64 allocation for every reference.
- Reserve capacity up front: the small base object length plus
  `16 + Σ(MIME + 40 + Encoder.calcSize(ref.len))`.
- Base64 straight into the builder's spare capacity (`addManyAsSlice`, then
  `std.base64.standard.Encoder.encode`; `ensureUnusedCapacity` + a slice write
  if that 0.17 name differs) — do not allocate a per-image string.
- Reuse `buildBody` for the small base object, including its existing
  escaping/model omission, and append `images` before its closing brace.
- Shape: `{"model":"…","prompt":"…","images":[{"image_url":"data:image/png;base64,…"}],"n":1,"size":"…"}`.
  Same omission rule for `model` as `buildBody`.
- Reject zero references with `error.NoReferences` and check the encoded
  URL limit before allocating the large body.
- `endpointFor` keeps the decision in one tested place instead of a ternary
  in `generate` and another in the tests.

`normalize` also strips a pasted `/images/edits`, so a full edits URL pasted
into the Backend sheet becomes `…/v1` like a generations URL does.

## UI

### Composer layout

Left column, top to bottom:

```
PROMPT
[ text area ]
REFERENCES            3 / 16        Clear
[thumb][thumb][thumb][ + ]                 ← one row of up to 8
[thumb][thumb]                             ← second row when >8
─────────────────────────────────────────
[model] [size] [+ Reference] [1 image]
[ Generate ]
RECENT
```

- 40×40 tiles, 8 per row, 6 px gaps; two rows cover the 16-image cap in 420 px
  (8×40 + 7×6 = 362).
- Tile: rounded 8, `theme.thumb` fill, 1 px `theme.border`, clipped, the image
  at `max_width = 40`, `max_height = 40`, `scale = 1`.
- Before passing PNG bytes to `ui.image`, check header dimensions: both
  nonzero, neither edge above 4096, and `@as(u64, width) * height` ≤4,194,304.
  Use a `PNG` tile otherwise; the image can still be sent as a reference.
  Apply this guard on every platform. JPEG/WebP use ImageIO's scaled decode
  on macOS and a MIME tile elsewhere. Tile labels come from sniffed MIME,
  not the filename. Explain skipped large previews with a tooltip.
- nanoui's `ui.image` reports header availability before the deferred decode;
  its return value does not guarantee successful decoding. Handle known
  unsupported formats before calling it; do not promise detection of every
  corrupt image in the strip.
- Remove affordance: a 14×14 hit box in the tile's top-right, drawn with
  `ui.div(c).absolute().offset(26, 0)`, an `xmark` at 9 px, `c.help(...,
  "Remove reference")`. If absolute positioning fights the layout in the
  snapshot, fall back to making the whole tile the remove target with the
  same tooltip; do not leave an invisible target.
- Add tile: same 40×40 frame, dashed-look border (`theme.border`), a `+` glyph
  at 16 px, tooltip "Add reference images".
- The header row uses `smallLabel` and `link` so it stays consistent with the
  rest of the app. `Clear` only appears when `items.len > 0`.
- Attach error: `error_text: [160]u8` and `error_len` on `State.refs`, shown
  under the strip at 11 px in `theme.danger`, cleared by the next successful
  add/remove/clear. Keeping this error with its reference list owns the copy.
  It must not use `State.error_text`, which replaces the result in `preview`.

The strip itself lives in `src/controls.zig` (+~55 lines) so `app.zig` stays
under 600 lines:

```zig
const refs = @import("references.zig");

pub const RefAction = union(enum) {
    none,
    add,
    remove: usize,
    clear,
};

pub fn referenceStrip(c: *ui.Context, items: []const refs.Ref, max: usize) RefAction;
```

Actions are returned. Remove/Clear are queued and applied at the beginning
of the next view, before drawing: `ui.image` retains source bytes until paint,
so freeing them after the drawing loop in the same frame is still unsafe.
Additions copy bytes and can be applied after drawing; drops request a redraw.

### Wiring

- `State.refs: references.List = .{}`.
- `State.deinit` → `s.refs.deinit(s.gpa)`.
- `State.init`: after `loadDemo`, read `REMBRANDT_REFERENCES`, split on
  `std.fs.path.delimiter`, `addPath` each, log one line with the count only.
- `chooseReferences()`: `nanoui.dialog.open(s.gpa, .{ .title = "Add reference
  images", .button = "Add", .extensions = &.{ "png", "jpg", "jpeg", "webp" },
  .multiple = true })`, `defer nanoui.dialog.freePaths(...)`, add each path,
  `c.changed = true`. Modal dialogs are supported from a view.
- Result reuse calls `s.refs.addBytes(s.gpa, it.name, it.bytes)`; surface
  `reason` in the reference-list error on failure (e.g. an old result over 14 MiB).
- Drop: make the composer column a drop target with
  `c.acceptDrop(col.index)` and handle `c.dropAt(col.index)`; for each URL,
  `pathFromUrl` then `addPath`; ignore text drops in v1.
- Preview meta row: add `if (link(c, "Use as reference")) s.addFromSelected();`
  before `Copy path`. Keep the selected result's meta actions available
  while generating so reuse follows the same rule as picker and drop.
- `generate()`:
  ```zig
  const refs = s.refs.items.items;
  const has_refs = refs.len > 0;
  var inputs: [16]backend.RefInput = undefined;
  for (refs, 0..) |r, i| inputs[i] = .{ .bytes = r.bytes, .mime = r.mime.header() };
  const body = if (has_refs)
      backend.buildEditBody(s.gpa, &s.config, prompt, inputs[0..refs.len])
  else
      backend.buildBody(s.gpa, &s.config, prompt);
  const url = std.fmt.allocPrint(s.gpa, "{s}{s}", .{ s.config.base_url, backend.endpointFor(has_refs) });
  ```
  The URL string and body are freed with the existing `defer`s; the fetch
  copies the body, so references may be edited right after Generate.
- Log, with no names or bytes:
  `generate: model=… refs=3 (4.2 MiB) size=… prompt_chars=…`.
- Clear the reference-list error when generation starts.

### Disabled / concurrency states

- Generate still requires a non-empty prompt (`hasPrompt`); references alone
  are not a prompt.
- While `generating`, allow the add tile, attach chip, picker, drops,
  individual removal, Clear, and reuse of the selected result. All changes
  apply only to the next request; show "Reference changes apply to the next
  generation." beside the strip. Generate remains disabled until completion.
- The submitted body owns its encoded bytes before fetch starts. Removing
  or clearing references must not alter that body or the in-flight request.
- No automatic retry: a failed edits call must not silently resend as
  generations (doubles cost and hides a backend gap).

## Tests

Unit/view tests live in `src/tests.zig`; real Generate integration lives in
`src/tests_generation.zig`. Use `std.testing.allocator` so leaks fail the test.

Unit — `buildEditBody`:

1. Three refs: parse the JSON, assert `images.len == 3`, each `image_url`
   starts with `data:image/<mime>;base64,`, decode the payload and compare it
   to the input bytes, `prompt`/`size`/`n` intact.
2. Model empty → no `model` key; model set → exact string.
3. Prompt with quotes/newlines survives escaping while images are present.
4. Zero refs → `error.NoReferences`; an oversized encoded URL →
   `error.EncodedTooLarge` even when input bypasses `List`.
5. `endpointFor(true/false)` returns `/images/edits` / `/images/generations`.
6. `normalize("https://relay/v1/images/edits")` → `https://relay/v1`;
   the existing generations case still passes.

Unit — `references`:

7. `sniff`: PNG, JPEG, WebP, text file → null.
8. Limits with `Limits{ .max_refs = 2, .max_file_bytes = 8, .max_total_bytes = 12 }`:
   third add → `TooMany`, 9-byte file → `TooLarge`, two 7-byte files →
   `TotalTooLarge` on the second, and `total` stays consistent. Use valid
   short JPEG signatures so format rejection does not mask limit checks.
   Also check acceptance at 14 MiB and rejection at 14 MiB + 1 through
   `addBytes` and bounded file reading. For each MIME prefix, independently
   derive the largest source length whose complete data URL fits 20,971,520
   characters; test it and the next byte against the shared encoded check.
9. `remove`/`clear` free bytes; run under the testing allocator.
10. `pathFromUrl`: `file:///C:/x/a%20b.png` → `C:/x/a b.png`;
    `file://server/share/x.png` → `//server/share/x.png`; a plain path is
    returned unchanged; `https://…` → null.

View — `ui.Tester`:

11. State with one reference (1×1 PNG literal added via `addBytes`) renders
    `REFERENCES` and the tile; click `Clear` → `items.len == 0`.
12. `t.drop(x, y, &.{"file:///…/ref.png"}, "")` on the composer adds one ref
    (write the file with `std.testing.tmpDir`); a second drop adds a second.
13. A bad drop (a `.txt`) leaves the refs untouched and sets `attach_error`.
14. "Use as reference" in the preview meta adds a copy of the selected
    result.
15. `Generate` with refs still does nothing without a prompt (reuse the
    existing disabled-button test).
16. While generating, exercise add/drop, remove, Clear, and selected-result
    reuse, asserting the resulting reference list and next-request hint.
    Check the native picker path manually; never open a dialog in tests.
17. Screenshot review, not an assertion: `t.screenshot` with 0, 1, 9, and
    16 refs, the generation-time hint/meta actions, and format/large-PNG tiles.
    Check a PNG at the pixel threshold and one just above it; use a highly
    compressed valid large PNG to validate memory and confirm it stays
    attachable while showing a tile. Measure peak memory during attach,
    rendering, and Generate; do not infer it from source bytes alone.

Integration — actual Generate path, local stub only:

- Start an ephemeral loopback HTTP server and point a `State.initDefault`
  config at it. Drive Generate through `ui.Tester` and pump the real event
  loop for callbacks, using a bounded timeout rather than sleeps.
- Capture method, path, headers, and JSON. With zero refs assert the exact
  existing generations body and `/v1/images/generations`. With 1 and 16 refs
  assert `/v1/images/edits`, JSON content type, prompt/model/size/n, and
  decode every image URL to compare with distinct fixture bytes in order.
- Hold an edits response until the test clears/replaces references; assert
  the captured request retains the original bytes, then submit again and
  verify the new reference state reaches the wire.
- Return a fixture PNG response; keep saves and settings inside temporary
  directories (provide an explicit test output directory if needed). Assert
  generation completes and the expected PNG is saved. Also return an edits
  error and assert no second request is made. Close the server and clean up.
- Pure builder/endpoint tests remain useful, but cannot replace this check:
  they would pass if `generate()` chose the wrong endpoint or omitted refs.

End to end (manual, no window; Python 3 on Windows, macOS, or Linux):

```python
import os
from pathlib import Path
import shutil
import subprocess

env = os.environ.copy()
env["REMBRANDT_PROMPT"] = "A ripe persimmon on warm paper"
env["REMBRANDT_REFERENCES"] = os.pathsep.join(
    str(Path("pictures", name).resolve()) for name in ("persimmon.png", "paper.jpg")
)
subprocess.run(
    [shutil.which("nui") or "nui", "snapshot", "--out", "shot.png",
     "--script", "click:Generate;live:95"],
    env=env, check=True,
)
```

Put the fixtures in `pictures/` first, or adjust the paths. `os.pathsep`
matches Zig's platform delimiter (`;` on Windows, `:` on macOS/Linux).
Then check `shot.png`, the app log for `refs=2`, and the platform's
Documents/Rembrandt directory for the new file. Use `REMBRANDT_LOG` to
choose an explicit log path, or consult `README.md` for platform defaults.
Diagnose failures using the probe rules above; do not infer multipart
support from a 404.

## Docs

- `AGENTS.md`:
  - Backend: "posts to `/v1/images/generations`, or `/v1/images/edits` when
    reference images are attached".
  - Env table: `REMBRANDT_REFERENCES` — delimiter-separated paths that
    preload the strip, for snapshots and manual checks.
  - Layout: add `src/references.zig`.
- `README.md`:
  - "Make an image": how to add, remove, and reuse a result as a reference.
  - "Connect a backend": either endpoint, and the 16-image / format note.
  - Env table: `REMBRANDT_REFERENCES`.
  - Troubleshooting: "My backend rejects edits" (multipart fallback / backend
    must implement `/images/edits`) and "A reference will not attach"
    (format, size, count).

## Order of work

1. **Probe** the real relay with the Python script above. Record status and
   the diagnosed outcome; resolve route/auth/model issues before UI work.
2. **Backend + tests** (`buildEditBody`, `endpointFor`, `normalize`, unit tests).
   No UI yet; `nui test` green.
3. **References module + State plumbing + tests** (`addPath`, limits, env,
   deinit). Still no visual change; `nui test` green.
4. **Controls strip + composer wiring + view tests**; `nui snapshot` with
   `REMBRANDT_REFERENCES`, open the PNG, fix spacing.
5. **Generate branch + logging + stub-server integration checks**, including
   in-flight reference changes, then the e2e snapshot against the real relay.
6. **Docs**, `zig build -Doptimize=ReleaseFast`, `zig build test
   -Doptimize=ReleaseFast`, final snapshots (0, 1, 9, 16 refs).
7. **Optional: multipart** (`REMBRANDT_EDIT_FORM=multipart`, a tested
   `buildMultipartEditBody`, `Content-Type: multipart/form-data; boundary=…`,
   `image[]` parts). Move into step 2 only when the comparative probe shows
   multipart works and JSON does not; otherwise leave it out of v1.
8. **Optional, separate repo: nanoui's Windows file dialog** ignores
   `multiple` and `extensions` today (`src/windows/dialog.zig`). Adding
   `OFN_ALLOWMULTISELECT` and `lpstrFilter` there would make one picker call
   add several files; do it as its own change, not inside this repo.

## Risks

- **Relay variance** is the big one: "OpenAI-compatible" services differ on
  JSON edits vs multipart, `images` vs `image`, and data URLs. The probe and
  Phase 7 exist for this.
- **Memory**: 40 MiB of source references plus the body and fetch copy is
  roughly 147 MiB before allocator overhead, history, responses, and decoded
  images. Portable nanoui fully decodes PNGs before shrinking; its own
  64-megapixel cap can still allocate 256 MiB of BGRA plus inflate buffers.
  Guard reference thumbnails at 4 megapixels/4096 per edge and measure actual
  peak use with compressed large inputs. Do not claim a 150 MB app-wide cap.
- **Windows picker** is single-select until nanoui changes, so adding five
  files is five dialogs. `REMBRANDT_REFERENCES` and macOS drops are the
  escape hatches; the UI copy should not promise multi-select.
- **Non-PNG thumbnails** off macOS show a MIME tile. Acceptable, but
  verify it does not look broken.
- **Line budget**: `app.zig` gains ~55 lines, `controls.zig` ~55,
  `backend.zig` ~70. Keep the strip out of `app.zig` and the body builder out
  of the view.

## Definition of done

- [x] `nui test` and `zig build test -Doptimize=ReleaseFast` pass.
- [x] `zig build -Doptimize=ReleaseFast` builds.
- [x] No refs → byte-identical generations request to today.
- [x] 1 and 16 refs → edits request; 17 rejected with copy, not a crash.
- [x] 14 MiB source cap and encoded URL boundary checked, including direct
      edit-builder input; failed adds leave list/count/total unchanged.
- [x] Attach from synthetic drops, a result, and env; picker wired.
- [ ] Native picker and actual macOS OS-drop smoke checks on those platforms.
- [x] Remove one, clear all, and restart with no refs behave correctly.
- [x] Reference changes during generation apply only to the next request;
      all entry points remain usable and the hint explains this behavior.
- [x] Stub-server checks exercise actual Generate routing, request contents,
      successful fixture saving, and no retry after an edits failure.
- [x] Snapshots at 0/1/9/16 refs and during generation look right at 1240×820;
      no overflow or clipped strip; large-PNG and unsupported-format tiles
      look intentional. Peak memory checked with a compressed large PNG.
- [x] E2E against the local backend writes an edited PNG.
- [x] Docs updated; no key, prompt text, or reference file name in the log.

## Implementation verification (2026-11-04, Windows)

- Real relay JSON probe: HTTP 200 with 1,326,572 base64 response characters.
  JSON edits work; no multipart implementation was needed.
- Actual headless app with PNG + JPEG references: completed in 44.3 seconds
  and saved a 2,926,741-byte PNG (1553×1013). Loaded it with Pillow and
  inspected the completed-result screenshot. An earlier attempt received a
  backend concurrency-limit 429; one later manual retry succeeded. The app
  itself never retried. Saves/settings were isolated under `.amp/in/`.
- Optimized tests: 20 passed, including source/encoded boundaries, mixed env
  preload failures, the seventeenth reference, UI interactions, and actual
  Generate routing/mutation/save/error behavior against a loopback server.
- Final `nui test` (Debug), optimized Windows build, formatting and diff
  checks passed. The optimized x86_64-linux-gnu cross-build also passed;
  this verifies compilation, not Linux runtime behavior.
- Inspected headless captures: 0/1/9/16 references, format tiles at and above
  the PNG threshold, attachment error, generating hint and result reuse,
  and a 1040×700 minimum-window layout; no visible clipping or overlap.
- Memory: process peak working set sampled via Windows process counters.
  Demo baseline: 50.9 MiB; 16 small references: 51.7 MiB; mixed JPEG/WebP and
  PNGs at/above 4 megapixels: 62.2 MiB. An 8000×8000 solid PNG (about 0.2 MiB
  compressed) showed a PNG tile, reached the stub byte-for-byte, and completed
  Generate/save at a 53.1 MiB peak. These are fixture measurements, not an
  app-wide memory limit or a worst-case 40 MiB request measurement.
- Native dialogs were not opened, per repository rules. Windows/Linux show
  JPEG/WebP tiles; macOS thumbnail/drop behavior still needs a platform smoke
  check. References are intentionally not persisted.
