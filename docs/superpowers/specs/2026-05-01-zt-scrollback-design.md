# zt scrollback buffer — design

- Date: 2026-05-01
- Status: design (not yet implemented)
- Targets: zt main branch (Zig 0.16+)
- Out of scope for v1: reflow on column resize, selection/copy of scrollback region (deferred to Phase 2)

## 1. Motivation

zt's `README.md` lists "**No scrollback buffer** — only the current viewport" as a known limitation. `src/main.zig:828` already carries a `// TODO: scrollback when implemented` marker on the wheel handler. Users hit this immediately on the HackberryPi (one-shot SSH session, no tmux) and on regular desktops.

The competitive constraints are:

- `Cell` is locked at 8 bytes — SIMD bulk paths (`fastCellFill`, `feedBulk`) depend on this. Comptime asserts in `src/term.zig:45-48` enforce it.
- Scroll is `O(1)` via `row_map` rotation in `src/term.zig:489-527`. Scrollback must NOT regress that fast path.
- Zero overhead when disabled: `-Dscrollback_lines=0` must compile out the entire feature so the existing render/scroll loop is unchanged.
- Must not break alt-screen behaviour for `less`/`vim`/`btop` (history pollution prevention).

## 2. Capacity & memory

| Setting | Default | Override |
|---------|---------|----------|
| `scrollback_lines` | 10000 | `-Dscrollback_lines=N` (0 disables) |

Memory at 80 cols, all dense parallel arrays:

```
per row = 80 * (8B Cell + 8B fg_rgb + 8B bg_rgb + 8B ul_rgb + 2B hyperlink) + ~4B per-row meta
        ≈ 80 * 34B + 4B ≈ 2.7 KB
10000 rows ≈ 27 MB
```

This is acceptable on HackberryPi Zero (512 MB). Sparse side arrays were considered and rejected for v1 — too much complexity for the saving on a system that already runs `cargo`. Stays open for a Phase 2 follow-up.

## 3. Architecture

```
                 ┌───────────────────────────────────────────────────┐
   PTY output → │ vt.zig                                              │
                 └───────────────────────────────────────────────────┘
                                       │
                                       ▼
                 ┌───────────────────────────────────────────────────┐
                 │ Term.scrollUp(n)                                   │
                 │   if (full_screen and !is_alt_screen and           │
                 │       scrollback_lines > 0)                        │
                 │     scrollback.pushRow(evicted_phys_row)           │
                 │   <existing row_map rotate + bceMemset>            │
                 └───────────────────────────────────────────────────┘
                                       │
                                       ▼
                 ┌───────────────────────────────────────────────────┐
                 │ Renderer (render.zig + main.zig render loop)       │
                 │   for y in 0..rows:                                │
                 │     if y < view_offset:                            │
                 │       cells = scrollback.rowAt(view_offset - 1 - y)│
                 │     else:                                          │
                 │       cells = main_grid.row(y - view_offset)       │
                 └───────────────────────────────────────────────────┘
                                       ▲
                                       │
                 ┌───────────────────────────────────────────────────┐
                 │ Input (main.zig + backend wheel events)            │
                 │   wheel ↑↓, Shift+PgUp/PgDn, Shift+Home/End        │
                 │   any key → view_offset = 0 (jump to bottom)       │
                 └───────────────────────────────────────────────────┘
```

Key invariants:

- Scrollback is owned by `Term` and lives across alt-screen switches. Alt screen does NOT push to scrollback.
- `view_offset == 0` ⇒ the renderer takes the existing fast path (no scrollback iteration), keeping zero overhead for the live-tail case.
- `view_offset > 0` is reset to 0 on:
  - any key input that produces PTY bytes
  - PTY-side cursor movement that would be unreachable otherwise — NOT implemented in v1, kept for follow-up
  - terminal resize whose new row count would invalidate `view_offset`

## 4. Data layout

Comptime gate via `build_options.scrollback_lines`. When `== 0`, the `Scrollback` type collapses to `void` and all `Term` fields/methods that depend on it disappear via `if (scrollback_lines > 0)` branches that are `comptime` known.

```zig
pub const Scrollback = struct {
    allocator: Allocator,
    cols: u32,
    capacity: u32, // = build_options.scrollback_lines
    head: u32,     // next slot to write
    count: u32,    // valid rows, <= capacity

    // Flat arrays sized capacity * cols (rotated by head)
    cells: []Cell,
    fg_rgb: []?[3]u8,
    bg_rgb: []?[3]u8,
    ul_color_rgb: []?[3]u8,
    hyperlink_ids: []u16,

    // Per-row metadata
    used_cols: []u16,        // capacity, for resize truncate
    has_truecolor: []bool,   // capacity, render hint

    pub fn init(allocator: Allocator, cols: u32) !Scrollback;
    pub fn deinit(self: *Scrollback) void;
    pub fn pushRow(self: *Scrollback, src_cells: []const Cell, src_fg: []const ?[3]u8,
                   src_bg: []const ?[3]u8, src_ul: []const ?[3]u8,
                   src_hl: []const u16) void;
    pub fn rowAt(self: *const Scrollback, age: u32) ScrollbackView; // age 0 = newest
    pub fn resize(self: *Scrollback, new_cols: u32) !void;
};
```

Layout reuses Term's parallel-arrays-per-cell pattern (matches `cells`/`fg_rgb`/`bg_rgb`/`ul_color_rgb`/`hyperlink_ids` in `term.zig:143-181`). `head`/`count` give us the ring; `(head - 1 - age) mod capacity` is the physical slot for a given age.

`Term` gains (all three fields gated on `comptime scrollback_lines > 0` so size delta is exactly 0 when disabled):

```zig
scrollback: if (scrollback_lines > 0) Scrollback else void,
view_offset: if (scrollback_lines > 0) u32 else void, // 0 = live tail
push_to_scrollback_disabled: if (scrollback_lines > 0) bool else void,
```

`push_to_scrollback_disabled` mirrors `is_alt_screen` for normal flow but is kept as its own field so tests can suppress pushes deterministically without faking alt-screen state.

## 5. Push semantics (`Term.scrollUp` integration)

Push happens **only** when ALL of:

1. `comptime scrollback_lines > 0`
2. `!is_alt_screen`
3. The scroll is full-screen — `scroll_top == 0 and scroll_bottom + 1 == rows`. (Partial-region scrolls inside DECSTBM regions never push, matching st/xterm.)
4. `n >= 1` (already guarded by existing `if (n == 0) return`)

For each evicted physical row (1 row in the fast path, `n` rows in the general path) we:

```zig
const phys = self.row_map[top + s];     // already known by existing loop
const start = phys * self.cols;
self.scrollback.pushRow(
    self.cells[start..][0..self.cols],
    self.fg_rgb[start..][0..self.cols],
    self.bg_rgb[start..][0..self.cols],
    self.ul_color_rgb[start..][0..self.cols],
    self.hyperlink_ids[start..][0..self.cols],
);
```

`pushRow` itself does the per-row truecolor scan (one pass over `src_fg`/`src_bg`/`src_ul` looking for non-null) and stores the result into `has_truecolor[slot]`. Cheap (~80 pointer-sized loads per evicted row) and avoids inheriting screen-wide false positives.

The push runs BEFORE `bceMemset` clears the physical row (otherwise we'd push blanks). Order in current `scrollUp`:

- v1 fast-path edit: `pushRow(recycled_phys)` → existing copyForwards → existing bceMemset.
- v1 general-path edit: split into "for s in 0..shift: pushRow then bceMemset", then unchanged rotate.

Erase paths that are NOT scrolls do NOT push:

- `eraseDisplay 2` (`ED 2`) — clears viewport, scrollback preserved (matches st default).
- `eraseDisplay 3` (`ED 3`) — clears the **active** ring: main ring when on main screen, alt ring when on alt screen. xterm clears unconditionally; we keep the main-ring protection so `clear` issued from inside `less`/`vim` (alt screen) cannot wipe the user's shell history.
- `?1049` enter/exit — alt screen switch; on enter-alt a per-session alt ring is allocated, on leave-alt it is freed. Alt-screen scrolls push into the alt ring (never the main ring).

### 5.1 Scroll-region gating (edge-anchored rule)

`shouldPushScrollback()` pushes when the current DECSTBM scroll region is anchored to **at least one screen edge** — `top == 0 OR bot+1 == rows`. This generalises the original "full-screen only" (`top==0 AND bot+1==rows`) rule to cover ratatui-style TUIs that run on the **main screen** with partial regions:

| Region pattern | Example | top==0 | bot+1==rows | Push? |
|----------------|---------|--------|-------------|-------|
| Full screen | `ESC[1;24r` (rows=24) | ✓ | ✓ | ✓ |
| Header + content | `ESC[8;24r` (codex) | ✗ | ✓ | ✓ |
| Content + footer | `ESC[1;16r` (codex) | ✓ | ✗ | ✓ |
| Floating mid-screen | `ESC[2;23r` (tmux middle pane) | ✗ | ✗ | ✗ |

Excluded: only regions touching **neither** edge (middle pane of a 3+ pane tmux split). 2-pane tmux splits still push (one pane touches each edge), but tmux users rely on copy mode for scrollback, not the outer terminal's ring — the collateral is low-impact. This rule lets `codex-cli` (which runs on the main screen and uses `ESC[1;7r` / `ESC[8;24r` / `ESC[1;16r` / `ESC[17;24r` for header/content/footer) accumulate scrollback without any app-specific detection.

## 6. Render path

`render.zig` `renderCell` is unchanged. The orchestrating loop in `main.zig` (currently iterates `0..rows` reading from `term.cells` via `row_map`) gets a thin wrapper:

```zig
// Pseudocode
for (0..term.rows) |y| {
    const sb_age_opt: ?u32 = if (term.view_offset > y)
        term.view_offset - 1 - y
    else null;

    if (sb_age_opt) |age| {
        const view = term.scrollback.rowAt(age);
        renderRow(view.cells, view.fg_rgb, view.bg_rgb, view.ul_rgb, view.hl);
    } else {
        const live_y = y - term.view_offset;
        const phys = term.row_map[live_y];
        renderRow(/* existing physical addressing */);
    }
}
```

Performance:

- `view_offset == 0` short-circuits to the existing path. Zero overhead.
- `view_offset > 0` flips to the slow path. `all_dirty` is forced for the entire scrolled frame to keep dirty bookkeeping simple. Acceptable: scrollback browsing is interactive, not throughput-bound.
- Cursor render is suppressed when `view_offset > 0` (cursor lives in live grid; drawing it on top of scrollback is misleading). Selection box is also suppressed (v1 deferral).

## 7. Input bindings

Added to `main.zig` key/wheel dispatch. Bindings live in `config.zig` constants for end-user override.

| Action | Binding | Notes |
|--------|---------|-------|
| Scroll up 3 lines | wheel up | Only when `mouse_mode == .none` AND (`!is_alt_screen` OR `alt_screen_wheel_scrollback`). |
| Scroll down 3 lines | wheel down | Same. |
| Scroll up 1 page | Shift+PageUp | Active on both screens; targets the active ring (main or alt). |
| Scroll down 1 page | Shift+PageDown | Same. |
| Jump to scrollback top | Shift+Home | Saturates at `activeRing().count`. |
| Jump to live tail | Shift+End | `view_offset = 0`. |
| Jump to live tail (auto) | any keystroke that writes to PTY | Set `view_offset = 0` BEFORE the keystroke is processed. |

Wheel routing (replaces `main.zig` wheel handler):

| `mouse_mode` | Screen | `alt_screen_wheel_scrollback` | Wheel behaviour |
|--------------|--------|-------------------------------|-----------------|
| `.none` | main | — | Scroll main ring. |
| `.none` | alt | false (default) | Translate to arrow keys (keeps `less`/`man`/`nano`/`vim` working). |
| `.none` | alt | true | Scroll alt ring (opt-in for `codex`-style sessions). |
| non-`.none` | either | — | Forward as VT mouse event to the app. |

Shift+PgUp/PgDn/Home/End navigate the active ring on both screens. In alt
screen they scroll the session-scoped alt ring, which holds the alt-screen
output history — exactly what `codex` users need.

## 8. Alt-screen rules

The alt screen has its own session-scoped scrollback ring (separate from the
main ring). Alt-screen content is captured into the alt ring while the alt
screen is active; the main ring is never polluted by alt-screen output.

- On enter alt: allocate a fresh alt ring sized `scrollback_lines × cols`.
  Reset `view_offset = 0` (force live alt). Main ring contents preserved.
- On leave alt: free the alt ring (`alt_scrollback = null`). Reset
  `view_offset = 0`. This matches the existing "alt screen is ephemeral"
  contract: quitting `less`/`vim`/`codex` drops the alt-screen history, and
  the user returns to a clean main-screen view.
- During alt: `Term.scrollUp` pushes evicted rows into the **alt ring** (not
  the main ring). `shouldPushScrollback()` no longer gates on
  `is_alt_screen`; instead `pushTarget()` routes to the active ring (main or
  alt). `?1049` save/restore is unchanged.
- `ED 3` (`eraseDisplay 3`) clears the **active** ring: the alt ring while
  in alt screen, the main ring while on the main screen. xterm clears
  unconditionally; we keep the main-ring protection so `clear` issued from
  inside `less`/`vim` cannot wipe the user's shell history.

### 8.1 Navigation in alt screen

Shift+PgUp/PgDn/Home/End scroll the **active** ring (alt ring while in alt
screen, main ring otherwise). These shifted keys are not captured by
`codex`, `less`, `nano`, `vim`, or `tig`, so repurposing them for history
browsing is safe in alt screen.

The mouse wheel keeps its existing behaviour by default (translates to
arrow keys when `mouse_mode == .none`), preserving `less`/`nano`/`vim` wheel
compatibility. An opt-in build flag `-Dalt_screen_wheel_scrollback=true`
(config `alt_screen_wheel_scrollback`) makes the wheel scroll the alt ring
while in alt screen — useful for users running `codex` who do not need
`less`/`nano` wheel compatibility in the same session.

| Input | Main screen | Alt screen (default) | Alt screen (`alt_screen_wheel_scrollback=true`) |
|-------|-------------|----------------------|------------------------------------------------|
| Wheel (mouse_mode=.none) | scroll main ring | arrow keys | scroll alt ring |
| Shift+PgUp/PgDn/Home/End | scroll main ring | scroll alt ring | scroll alt ring |
| Wheel (mouse_mode!=.none) | forward to app | forward to app | forward to app |

## 9. Resize

v1 = **truncate / pad only**. No reflow.

On `Term.resize(new_cols, new_rows)`:

1. After main + alt buffers are reallocated (existing logic), call `scrollback.resize(new_cols)`:
   - Allocate a fresh flat blob sized `capacity * new_cols`.
   - For each existing row, copy `min(used_cols, new_cols)` cells; pad remainder with blanks.
   - Drop wide-char left half stranded at the new last column (matches existing `term.zig:633-644` boundary fix).
   - Free the old blob.
2. Clamp `view_offset = min(view_offset, scrollback.count)`. (Max meaningful offset is the row count of available scrollback — anything beyond would render phantom rows.)
3. Force `all_dirty = true` for the next frame.

Capacity (`scrollback_lines`) is comptime and never changes.

## 10. Selection / copy

v1: selection clamped to viewport. Dragging into the scrollback area is allowed but the selection's `y` is clamped to `0`. Copy operations apply to viewport-only.

Phase 2 (separate spec): extend `Selection` to use signed `y` where negative `y` indexes scrollback. This requires touching every `selection.contains` call site in `term.zig` and the render path; intentionally deferred to keep v1 blast radius small.

## 11. Build option

Append to `build.zig` next to the existing `pty_buf_kb` block:

```zig
const scrollback_lines_opt = b.option(u32, "scrollback_lines",
    "Number of scrollback rows (0 disables, default 10000)") orelse 10000;
options.addOption(u32, "scrollback_lines", scrollback_lines_opt);
```

`config.zig` gains a corresponding `pub const scrollback_lines = build_options.scrollback_lines;` alias and the input binding constants:

```zig
pub const scrollback_wheel_lines: u32 = 3;
```

## 12. Tests

Unit tests added to `src/term.zig`:

1. `scrollback: pushRow stores evicted row contents` — write `'A'`/`'B'`/`'C'` to rows 0/1/2, scroll, check `scrollback.rowAt(0..2).char` matches.
2. `scrollback: capacity overflow drops oldest` — push capacity+5 rows, verify oldest 5 are gone, newest survive.
3. `scrollback: alt screen suppresses push` — switch to alt, scroll, switch back, scrollback unchanged.
4. `scrollback: ED 3 clears scrollback` — push some rows, fire `eraseDisplay(3)`, scrollback empty.
5. `scrollback: partial-region scroll does NOT push` — set `scroll_bottom = rows - 2`, scrollUp(1), scrollback unchanged.
6. `scrollback: resize truncates rows wider than new cols` — push wide row, shrink, verify clipped + wide-char boundary fix.
7. `scrollback: resize pads rows narrower than new cols` — push narrow row, grow, verify pad with blanks.
8. `scrollback: view_offset clamps on resize` — set offset, resize smaller scrollback context, verify clamp.
9. Comptime size test: a snapshot test asserts `@sizeOf(Term)` with `scrollback_lines = 0` equals a fixed expected value (recorded once with all scrollback fields gated out). Updating the value requires explicit consent in a follow-up commit. Guards against accidental field bloat creeping into the disabled path.

Manual / smoke tests added to `docs/qa-checklist.md`:

- `seq 1 5000 | cat` then wheel-up to top, wheel-down to bottom (X11/Wayland/fbdev).
- `less /etc/services` — wheel must NOT scroll local scrollback (alt screen). Quit `less` — scrollback intact.
- `vim` — same as `less`.
- `btop` — `mouse_mode != .none`, wheel goes to app, Shift+PgUp scrolls scrollback.
- Resize (mod-key drag) while scrolled to middle of scrollback → no crash, view stays sane.
- Cross-compile aarch64 with `-Dscrollback_lines=0` and `=2000` — both link, binary size delta < 1 KB for `=0`.

## 13. Implementation phases

1. **Phase 1**: `Scrollback` type + `Term.pushRow` integration in `scrollUp` + alt-screen gating + tests 1-5.
2. **Phase 2**: render path branching (`view_offset`) + input bindings (wheel + Shift+PgUp/Dn/Home/End) + tests 8.
3. **Phase 3**: resize handling + tests 6-7 + comptime gate + test 9.
4. **Phase 4**: manual QA pass + docs update (README limitations entry, build flag).

Each phase is a separate commit / PR-ready unit. After Phase 1 the buffer is live but invisible (good intermediate verifier — the unit tests prove correctness before any rendering risk).

## 14. Non-goals (explicit deferrals)

- Reflow on column resize.
- Selection / copy of scrollback rows.
- Search inside scrollback (`Ctrl+R` style).
- Per-row sparse side-array compression.
- Disk-backed history (st-scrollback-style).
- Mouse-button drag-scroll on the scroll bar (no scroll bar exists).
