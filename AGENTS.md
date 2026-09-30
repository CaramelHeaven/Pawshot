# Pawshot

A native **macOS-only** Swift app — a screenshot utility. A background program with no Dock icon
(`LSUIElement`): it lives in the menu bar and waits for a hotkey.

What it can do today: **⇧⌘2** → the screen dims, the cursor turns into a gapped crosshair with a
glass badge trailing behind it (the size in pixels of the file, the position in points) → drag a
rectangle → release → the captured region opens in the editor. The selection wears the frame
corners of the app icon. **M** toggles an 8× loupe with the pixel's HEX; for the first five
captures a hint strip lists the keys. (The orange guides across the screen are gone — the owner
found them in the way, in shots and in videos alike.) Esc and a
right click cancel the capture.

**Space switches the overlay to window mode** — the same gesture the system tool has behind ⇧⌘4:
the cursor becomes a camera, the window under it is highlighted, a click takes it whole. The window
list is taken *before* the overlay is up — otherwise the window under the cursor would be our own
overlay. **⇧⌘1 captures the whole screen** with no overlay at
all: the display frame is already there, so the shot is just its full crop.

**⇧⌘3 records a region, ⇧⌘4 records the whole screen** — the owner's choice, knowing macOS takes
both for its screenshots until they are unticked in Keyboard Shortcuts. The same key again stops.
While a region records, everything around it stays dimmed and the region sits clear inside the
red corners, the way macOS shows it; the dimming lets clicks through and never reaches the video.
A recording is a `SCStream` feeding an `AVAssetWriter` (not `SCRecordingOutput`: no pause, and a
broken file with the microphone on). A glass pill by the recorded area holds the time, pause, zoom,
pen, restart and stop; on a screen with a camera notch it becomes a black band around the notch
that drops its buttons down on hover. The menu bar shows the time instead of the paw. While a take
runs, **⇧⌘6** marks a zoom — an orange outline shows for 2.5 s exactly the part the export will
zoom to — **⇧⌘7** switches the pen (the mouse draws on the screen, into the video, every stroke
fades after four seconds, Esc gives the mouse back), **⇧⌘5** restarts, and the shortcut that
started the take (⇧⌘3 or ⇧⌘4) stops it — there is no separate stop. ⌃⌥ + letter was tried first
and dropped as awkward mid-take. The
pill writes each shortcut under its button. These four are registered only during a recording —
not ⌘R/⌘D, which a global hotkey would take away from the app being recorded — and like the rest
they are set in Settings → Shortcuts. No Pawshot window is ever in the video — the filter leaves
the whole app out.

**The welcome window opens by itself at launch until "Get Started" is pressed** (`app.welcomeCompleted`;
closing it any other way is not an answer, so it comes back next launch), and after that from the
paw's "Open Pawshot". The owner picked its layout, W-C, on 2026-09-28 from four mockups: on the left
the four main shortcuts as they are set right now, on the right every access Pawshot can use — Screen
Recording (the one that is required, and the only one "Get Started" waits for), the microphone, Input
Monitoring, whether macOS still keeps any of our shortcuts, launch at login — each read once a second
with a button to it — and under them the "Collect Logs" switch (below, `### Logs`). It asks for nothing by itself: every system prompt comes from a button press.
The shortcuts used only during a take (zoom, pen, restart) are not on it; the pill and Settings show
them. It replaced the old "Open Pawshot" window rather than sitting next to it. To see it again:
`defaults delete com.caramelheaven.pawshot app.welcomeCompleted`.

**After an update, a "What's New" window says what changed since the version the person had —
once.** Its first look, N-A, told only about the latest version; the owner then picked W-C on
2026-09-28 from four mockups, so a jump from 0.4.6 to 0.4.9 hears about 0.4.7, 0.4.8 and 0.4.9: a
header with the icon in its corner brackets on the left, "What's New" and `0.4.7 → 0.4.9`, then a
timeline — a paw-coloured dot per version, the current one filled and marked "now", the text beside
it — ending in a grey "0.4.7 — your version before the update", and "Got It". Many skipped
versions scroll inside a list of bounded height rather than growing the window. It opens by itself
at the first launch of a new version (`WhatsNew.showsAtLaunch`) and never on a fresh install:
"Get Started" records the version it was pressed in. The window reads the version it came from once
(`@State`): showing it records the new version as seen, and a list re-read after that would be
empty. A launch that opens no window — a release with nothing to tell — records the version too,
so "your version before the update" stays true. Shown means seen, however it is closed. It and the welcome window put
themselves above every other app (`ComesForward`): Sparkle relaunches Pawshot from a background
helper, as a login item does, macOS doesn't activate it, and SwiftUI then orders a window front
among Pawshot's own only — 0.4.7's What's New opened behind the app in front. An update from
0.4.6 or older, which stored no version, hears everything there is and shows "Version 0.4.9" with
no bottom line. The words are `WhatsNew.history`, newest first, one entry per version since 0.4.7
(see Releasing, under `### Updates`); an entry with an empty text is left out, and with nothing
left there is no window. To see it again from a given version:
`defaults write com.caramelheaven.pawshot app.lastSeenVersion 0.4.7`.

**Settings → Statistics counts what the person does, on this Mac only** — the owner picked the
numbers and the look (L-B) on 2026-09-28 from a page of 28 candidates and four layouts. The count
of shots sits big on a paw-coloured card with the date counting started; under it tiles of three:
screenshots (favourite mode, cancelled, text read with ⌘D, fixed by the window edge), drawing (each
tool, ⌘Z, favourite colour and tool), video (recorded time, restarts, pauses) and the rest (⌘Q let go
on the toast, the peak hour, days in a row). A tile at zero is muted and says how to get it going,
with the shortcuts as they are set. Everything started at zero with the build that brought it;
"Reset Statistics…" starts it again and never touches `captureCount`, which the hints and About
read. Each count is one line at its choke point (`Stats.shared.add` / `noteShot` / `noteDrawn` /
`noteRecording`). `Stats` lives apart from `Settings`, so a count doesn't redraw every settings view,
and in the test host it writes to a suite of its own: the host is the app, and tests that draw
or capture would otherwise count into the owner's numbers.

**Stop opens the video editor**: the player, a film strip, and a footer with the format, the
length that comes out and an estimated size. On the strip every kept piece sits inside a pair of
orange corner brackets — the owner's choice among three designs, "mark what to keep". Dragging over
the grey keeps another piece; the pieces go out butted together and the grey is cut. Their edges
are dragged like the single trim was, a click selects a piece, and every change is a step of ⌘Z.
Playback skips the grey. Several pieces are always re-encoded — a passthrough seam off a key frame
needs an edit list that not every player honours. For the first five openings a line of key hints
sits under the strip. The rules are the
screenshot's: `⌘C`, `⇧⌘C` and `⌘S` hand the video off and the window dissolves, any other way of
closing it throws the recording away — `⌘W`, or a tap of `⌘Q` after a question; Esc only lets go
of the selected piece. An export shows its progress in the window and keeps running
if the window is closed, then delivers anyway.

| Key | In the video editor |
|---|---|
| `Space` | play / pause, jumping over the grey |
| drag over the grey | keep another piece there |
| `⌫` | remove the selected piece (never the last) |
| `⌘Z` / `⇧⌘Z` | undo / redo a change to the pieces |
| `P` | format: Original (HEVC) → 1080p (H.264) → GIF 720p 15 fps; remembered |
| `⌘C` | the file, in the chosen format, onto the clipboard |
| `⇧⌘C` | a GIF onto the clipboard, whatever the format |
| `⌘S` | to the save folder (Settings → Screenshots → Saving), in the chosen format |
| `Esc` | let go of the selected piece — never closes |
| `⌘W` | close and throw the recording away |
| `⌘Q` tapped / held | ask, then close and throw the recording away / quit Pawshot |

**Effects are added at export, from a timeline recorded alongside the video**
(`<raw>.events.json`): orange rings on clicks, a caption for shortcuts with ⌘, ⌥ or ⌃ (`⌘Z ×3`),
and a 2× zoom wherever ⇧⌘6 or the pill's magnifier marked one. Across a cut they follow their
piece: an event in the grey is dropped, a zoom or caption over a seam stops at the piece's edge.
The editor previews them live — the same layer tree as the export, run by an
`AVSynchronizedLayer` — and has a switch for each one the take actually has. What it starts with is
set in **Settings → Recording**, which gathers everything about a recording with a line of plain
words under each group: the sound (and the microphone's access), what is drawn into the video
(clicks, pressed shortcuts — these need Input Monitoring — and zooms), and the resolution and
format. The gradient backdrop that used to be here was removed at the owner's request.

**The recording overlay is the screenshot overlay with `purpose = .recording`.** The brackets are
red, and mouse up does not end it: the region stays, to be moved by its middle and resized by its
edges and corners, and ↩ (or R, or the Record button) starts. It behaves the way the system's
⇧⌘5 does — the owner's picks of 2026-09-30 from a page of live mockups (О-C, О-D, П-B, И-A):

- **The last region on each display comes back alive**, with its corners, not as a dashed ghost:
  it moves, resizes and records with ↩ as it stands. The ghost only answered ↩, and a press
  inside it drew a new region — which read as "I can't move it".
- **A press beside the region is a new region only once the mouse has moved** 3 pt; a plain
  click leaves the region alone. It used to be wiped on the press itself.
- **Grip pills** on the middles of the edges show while the cursor is within 44 pt; the pill and
  the corner under the cursor turn red and grow, the middle gets a light veil. All CoreGraphics,
  redrawn when the zone under the cursor changes, not on every move.
- **The magnet**: a dragged region or edge sticks, within 6 pt, to the visible edges of windows,
  the edges of the screen and its middle. An orange line shows what it stuck to — only during
  the drag, so none of the guides the owner once removed stay on screen — and the size in pixels
  of the file is written beside a dragged edge.
- **The drop onto a window**: while the region is dragged by its middle and that middle comes to
  the middle of a window — within 15% of the window's shorter side, the window on top there —
  the window is outlined in the paw colour, and dropped there the region takes its frame. Moved
  again, it is the size it had before. Off the middle it is simply laid on top. It stays a
  region (no window id goes to the recorder, the pen works, the frame can be widened), unlike
  Space, which records the window itself. Resizing, drawing or typing a size forgets the old one.
- **The toolbar** sits at the bottom of the screen the cursor is on and never moves: region /
  window / whole screen, Options, Record. "Screen" records what ⇧⌘4 does. Options is a panel of
  the same SwiftUI view, not a menu — the microphone (none, or one of the Mac's inputs, with the
  live level), the system sound, clicks, pressed shortcuts, the scale. The glass bar that hung
  under the region and hid on every drag is gone.

| Key | On the recording overlay |
|---|---|
| `↩` / `R` | start (with a size being typed: apply the size) |
| `A` | proportions: free → 16:9 → 9:16 → 1:1 → 4:3 |
| digits, `x`, digits | an exact size in pixels of the file, `1920x1080`, then `↩` |
| `X` | 2x (the display's pixels) ↔ 1x (one pixel per point) |
| `M` / `S` | microphone / system audio on or off |
| arrows | move the region 1 pt; `⇧` — 10 pt; `⌥` — move the right and bottom edges instead |
| `⇧` dragging a corner | keep the region's proportions |
| `⌥` dragging an edge or a corner | grow from the middle |
| `⌘` dragging | no magnet and no drop onto a window |
| `Space` | window mode |
| `Esc` | a half-typed size first, then the open Options, then cancel |

All four shortcuts are editable in **Settings** (`⌘,`). Its tabs are the owner's О-C, Г-A, З-C
and Ш-C of 2026-09-29, picked from a page of mockups: General (launch at login, ⌘Q, the language,
the log), Screenshots (saving and the editor), Recording, Shortcuts and Statistics; About is not a
tab, it has its window. The Recording rows name the key that changes each one for a single take
(M, S, X on the overlay, P in the editor), their long explanations in tooltips. Shortcuts is a
cheat sheet: each shortcut a card with big caps — `HotKeyRecorderView` with `style = .card` —
recorded by a click on the card. macOS takes a screenshot combination — and "Move
focus to next window", with ⇧ for its other direction — before Carbon ever hands it to us, so the
settings window reads the real state of the system shortcuts (`SystemScreenshotShortcuts`) and
warns on the card of one of ours still taken — a red outline, "macOS takes it · Fix…", the item
named as System Settings does in its tooltip ("Keyboard → Move focus to next window") — instead
of silently doing nothing. The × in the card's corner takes the shortcut away: the action then has none — the field reads "Record Shortcut",
the menu item shows no keys, and the action is reached from the paw's menu or the pill. A cleared
one is stored as `none`, apart from a missing key (the default), so Restore Defaults brings every
one back.

Everything that draws lives in **two glass capsules at the bottom**, the owner's pick: one with
the tools and their letters, one with the style — four colours always on show (red, green,
white, black), a fifth of one's own with a picker behind it, and then only what the current tool
or selected object has: widths, the four shapes, the fill and its **always visible opacity
slider** for a shape, widths and the ends for a line, the look, one "Аа" button per weight of the family
and the plate's slider for a label. Side by side when they fit; narrower, one capsule of the
tools and a chip — the current colour and width — that opens the whole style in a popover, a row
each for the colours, the widths and the rest (the owner's A of 2026-09-29; stacking the two
capsules, folding the colours and scrolling sideways, what came before, is gone). Settings →
Screenshots → Editor puts them in a strip of their own under the shot (the default; the window's
chrome is measured, so growing the shot by its edge accounts for the strip) or floating over the
shot's bottom edge; the switch applies at once, and open windows refit. Over the shot, the panel
has a visible grip at each end — a pill that lights up in the paw colour on a 16 pt strip: drag it
out or in to scale the panel between 75% (smaller cells can't be hit) and 150% (bigger covers too
much of the shot), never wider than the window (`SelectionGeometry.toolsScale`); a double click
puts it back at 100%, and the size is remembered.

**SwiftUI drawn over the canvas is invisible to AppKit.** The canvas sets the cursor itself from
its tracking area, which fires by geometry — under the floating panel too — so the grips' resize
cursor never showed. `hitTest` can't tell the panel is there: over a representable view SwiftUI
content is not a view, and the canvas answers (`testHitTestSeesTheCanvasUnderASwiftUIPanel`). So
the panel reports its frame, and the shot's, in SwiftUI's global space; the controller maps it onto
the window through the shot (`SelectionGeometry.windowRect`, since where SwiftUI's global space
starts under the title bar and toolbar is not to be assumed), and the canvas leaves the cursor
alone inside it (`cursorExclusion`). The SwiftUI toolbar on top (the owner's T2 of 2026-09-29)
splits the way Preview does: what changes the shot on the left — undo and redo, then the two turns
and Clear All — the size in pixels in the middle, and the ways out on the right — Save, Copy Text,
and Copy as the one orange primary action. The window's own title is hidden, since the middle
says it; it stays for Mission Control and the Window menu. Save As… is `⇧⌘S` and the File menu. The shot sits between them as a sheet of paper. Annotations are
**objects**: they can be moved, recoloured and deleted one by one, and all of it is undoable with
`⌘Z`. The toolbar shows the selected object's style, and a change to it — a colour, the fill, a
line's ends — goes to that object alone: a blue double arrow made single stays blue.

**The line is one tool with three looks** — a plain stroke, an arrow, a double arrow — picked by
three buttons in the toolbar, or by pressing `A` again with the line already on. A drawn line can
become any of them later. **The shape tool has four** — a rectangle, a circle, a triangle, a
diamond — the owner's Ф-A of 2026-09-28, chosen the line's way: four buttons after the widths, or
`R` again with the tool on, and a drawn shape switches with its colour, fill and turn kept. The
kind is `AnnotationStyle.shapeKind` on the one `RectangleAnnotation` class. A circle is always
round: drawn from where the drag began, it lies in the middle square of its box, so a rectangle
made a circle and back is the same rectangle. `⇧` while drawing makes any of them even — a
square, an equilateral triangle. A circle, a triangle and a diamond are hit by their own outline,
not by their box. **The fill has an opacity**: `F` walks none → 30% → 60% → solid, the slider
next to it gives anything in between, and a text plate takes the same value. The fill follows the
slider while it moves (`EditorDocument.previewStyle`, no undo per tick), and letting go is one
step of ⌘Z back to where the drag began; until 0.4.9 it changed only on letting go. **The fifth
colour** is picked in a popover — saturation and brightness, hue, the hex, the last eight colours,
and an eyedropper (`NSColorSampler`) that takes a colour straight off the shot; it is remembered
between launches.

**Labels are set in any font family installed on the Mac**, the system font by default, picked
in Settings → Screenshots → Editor from a searchable list, opened from a button, where each family
is written in itself, with a live label on a strip of shot under the button. The family is one for all labels
(`LabelFont.family`) and applies at once: every open editor re-measures the labels already drawn
(`EditorDocument.labelFontDidChange`) — the owner's call, and not a step of ⌘Z, since it is a
setting. A family no longer installed falls back to the system font. Each label keeps its own
**size** and **weight**: the weight buttons are the family's upright faces, as many as it has
(SF: nine), `⇧[` / `⇧]` step through them, `[` / `]` step the size, and a selected label has
**handles on its four corners** — drag one and the text grows about the opposite corner, one
step of ⌘Z. A bundled Formular was tried and removed.

**A selected object has handles under `V`** — the owner picked them on 2026-09-28 from a page of
variants (the codes Л-A, Л-C, Н-A, П-C, П-D, Б-A, Т-C, Э-1, Э-4 on it). One step of ⌘Z per drag
or click, and a chip by the cursor says the number while dragging — pixels of the file, degrees,
points for a label's size. What each object has lives in `Editor/CanvasHandles.swift`, the
arithmetic in `SelectionGeometry`, and the cursor is decided by one function there:

- **A line** has no frame: a circle on each end drags that end (`⇧` — the direction on 15°
  steps), a diamond halfway bends the line into an arc through the mouse (dropped back on the
  straight line, it is straight again; moving an end carries the bend along), and a small round
  button beside it walks the heads *at the end → at the start → at both → at the end*, showing the
  next stop. The start stop is `pointsBack` on the object, not a fourth `LineEnds`, so the toolbar's
  three looks stay as they were; the button changes that line only, never the style new lines
  take. A plain line's click gives a head at the end.
- **A rectangle** has squares on its corners and grabbable sides that are not drawn (the cursor
  shows them, as on the recording region); `⇧` keeps a corner's proportions, `⌥` grows it from
  the middle. Just outside a corner it **turns** about its middle (`⇧` — 15°), Figma's way,
  with nothing drawn there — the owner asked for the turning to stay quiet. The angle is stored
  on the rectangle; the frame, the hit test and the export all turn with it. A triangle and a
  diamond do the same; **a circle** has only its corners, which always keep it round, and no
  turning.
- **A blur** resizes like a rectangle and never turns: it hides a line of text, and a turned
  pixelation reads as a glitch.
- **A label**: the corners set the size, the left and right sides the width its text wraps
  inside, and it turns from outside a corner like a rectangle. `quarterTurns` became a free
  `angle`; the text field follows it through `frameCenterRotation`.
- The pencil and the step numbers keep the plain frame (the owner's call). A frame under 24 pt
  carries its handles on a frame grown to 24, so the object's middle can still be grabbed.

**`⌘L` / `⌘R` turn the selected object a quarter about its own centre; with nothing selected,
they turn the shot**, as in Preview, with everything drawn on it — labels and
step numbers included, as if they had been drawn before the turn. The whole captured frame turns,
not just the crop, so every coordinate stays "a point of the frame": the canvas, the export and
growing the shot by the window's edge needed no change, and the latter keeps working after a turn.

**Missed the region by a few pixels? Drag the window by its edge.** Resizing the editor window
resizes the shot itself: pulling an edge outwards makes neighbouring pixels of the screen stick to
it, pulling it inwards crops. Nothing is captured again — the whole display was already frozen at
hotkey time and is kept alive for as long as the window is open, so the extra pixels come from the
very same moment. The captured display is the hard limit; the window simply stops at its edge.
Annotations don't move, an annotation left outside the crop stays alive and only gets clipped, one
drag is one `⌘Z`, and the whole thing switches itself off once the shot no longer fits in the
window — there dragging the window means "show more", not "capture more". The shot is always
displayed at its own size; there is no zoom in the editor. That switch reads the window as it is
at the start of the drag, so the window refits whenever the shot stops fitting outside a resize,
not only once after it opens: on a tester's M1 (8 GB, 60 Hz) the toolbar landed after that one
refit, ate the bottom of the shot, and every drag grew grey around it. Each drag logs
`resize begins: edges …, follows …` — an `.error` when the shot will not follow.

The finished result leaves the app in four ways: `⌘C` to the clipboard, `⌘S` as a file
`pawshot-<date>-<time>-<UUID tail>.png` (or `.jpg`, `.heic`) in the save folder — the Desktop until
Settings → Screenshots → Saving names another, in the format picked there — `⇧⌘S` through the
system's save sheet with a name, folder and format for this once, and `⌘D` as the **text** read
off the shot, with what any QR code or barcode on it holds first.
All three hand the result off first and then **dissolve the window in 150 ms** (plain alpha) — the
window going away is the confirmation. No banners, no thumbnail in a corner, no waiting: the fade
starts after the clipboard or the file is already written, and the window stops taking clicks the
moment it starts fading. Dragging the picture out with the mouse is not built: it came with the
shot chip of T1, which the owner swapped for T2.

`⌘D` reads the flattened picture and not the bare frame, so a blurred password is gone from the
clipboard too. Picking text with the mouse, the way Preview does, is deliberately not built: it
would have to share the canvas with every drawing tool, and `⌘D` covers the need without touching
a single existing gesture.

### Editor keys

| Key | Tool | Key | Action |
|---|---|---|---|
| `V` | select and move | `⌘Z` / `⌘⇧Z` | undo / redo |
| `A` | line; again: arrow → double → plain | `⌫` | delete the selection |
| `R` | shape; again: circle → triangle → diamond → rectangle | `[` / `]` | width − / +; on a label: size − / + (`⇧` — weight) |
| `D` | pencil | `1`…`4` / `5` | red, green, white, black / your own colour |
| `T` | text | `F` | fill none → 30% → 60% → solid; with `T` or a label: plain → outline → plate |
| `B` | blur | `C` | clear all (no confirmation, `⌘Z` brings it back) |
| `N` | step counter | drag a window edge | grow or crop the shot |
| | | `⌘C` | copy the result to the clipboard, the window closes |
| | | `⌘D` | copy the QR codes' payloads and the text read off the shot, the window closes |
| | | `⌘S` | save to the save folder in the save format, the window closes |
| | | `⇧⌘S` | save as — name, folder, format — the window closes |
| | | hold `⌘` | move whatever is under the cursor, without leaving the tool |
| | | `⇧` dragging a handle | a line's end or a turn on 15° steps; a corner keeps proportions |
| | | `⌥` dragging a handle | a rectangle or a blur grows from its middle |
| | | double click / `↩` | edit a label (`↩` on a selected one) |
| | | `⌘L` / `⌘R` | turn the selection, or the whole shot, a quarter left / right |
| | | `⌘W` | close the window |
| | | `Esc` | typing → tool → selection, then nothing |
| | | `⌘Q` tapped / held | close the window (asking if there is work) / quit Pawshot |

`Esc` cascades and then stops: it never closes the window — the owner's call on 2026-09-28, after
losing shots to it. While text is being typed, letters land in the text instead of switching
tools, and `⌘Z` takes back the typing rather than the last object.

**⌘Q is Chrome's "Warn Before Quitting"** (`App/QuitKey.swift`, `App/QuitToast.swift`; Settings →
General, on by default; off, ⌘Q quits at once). A tap — let go within 0.3 s — closes the window
in front, with no toast. Held longer, a glass "Hold ⌘Q to Quit" toast comes up in the middle of
the screen with a bar filling in the paw colour; at 1.3 s from the press the windows fade and
Pawshot quits without asking, and let go before that the toast melts away and nothing else
happens. The press starts a check that polls the key state, since a held key sends only repeats.
Once the hold has run out, further presses are ignored: a key repeat during the 150 ms fade used
to start a new timing, and let go then, read as a tap that closed a window mid-quit.
A tap on a shot with something drawn on it asks first in a sheet; any other shot closes at once —
a crop, a grown edge or a turn alone is no reason to ask (the owner's call, 2026-09-29; it used
to ask for anything undo remembered). The video editor always asks, its
recording being thrown away, unless an export is running. Settings and the other small windows
just close; the capture overlay ignores a tap. The paw menu's "Quit Pawshot" quits at once as it
always did.

**Closing the last editor gives the focus back** to the app that was in front when it opened
(`App/FocusHandBack.swift`), however it closes — a ⌘Q tap, ⌘W, ⌘C/⌘S/⌘D, the red button. Before,
Pawshot stayed the active app with no window, and typing went nowhere (the owner, 2026-09-29).
Another Pawshot window still open — Settings, a second editor — keeps the focus. Activation is
cooperative since macOS 14, so whether it went through is logged half a second later
(`focus not handed back … still active` is an `.error`).

**The editor opens in the middle of the screen the shot was taken on**, and a shot bigger than the
window (a full-screen capture) opens scrolled to its middle, still at 1:1.

**Every key in this table is read off the physical key, not off the character the layout printed.**
On ЙЦУКЕН `V` prints `м` and `B` prints `и`, and reading the character meant not one tool key
worked there. `KeyboardLayout` translates a key code through the current ASCII-capable layout; a
character that is already ASCII is passed through untouched, so Dvorak keeps the letter that is
actually on its keys.

**A drawing tool always draws, and what it draws is not selected.** D, a stroke, another stroke
straight away — on top of the first one too. Moving is `V`, or **holding `⌘`**, which turns any
drawing tool into a temporary move tool (the way Photoshop springs to Move); when the ⌘-drag ends,
nothing stays selected and the tool draws again. It used to be the other way — every new object came
out selected and a selected object moved under any tool — so a second pencil stroke started inside
the first one's frame moved the first instead of drawing. No app surveyed combines "the tool stays"
with "the new object is selected and a drag moves it"; the rule lives in
`Editor/CanvasInteraction.swift` and is covered by tests. The owner's system "Three Finger Drag"
arrives as ordinary mouse events: under `V` it moves, under a drawing tool it draws. Don't try to
catch touches through `NSTouch`.

**Except the line, the rectangle and the label: those hand what they drew over to `V`.** Released
after `A` or `R`, or finished typing after `T` (Esc, ⌘↩, a click elsewhere), the editor switches to
`V` with the new object selected — the owner's call on 2026-09-26, since a line or a box is nearly
always nudged or restyled right after, and the line's ends are picked on a selected line. Two
arrows in a row therefore take `A` twice. The pencil, the blur and the step numbers keep the rule
above: strokes and numbers come in runs. Which tool does what is `AnnotationTool.selectsWhatItDraws`.
Only the user's own ways of finishing a label switch to `V`; `finishTextEditing()` also runs when a
tool is picked in the toolbar, and must not override that pick.

**With `V`, a selected object is dragged by any point inside its frame** — the cursor over it turns
into a hand. The grab area comes from `Annotation.selectionFrame` and not from `hitTest`: for an
unfilled shape `hitTest` only catches the outline, and a drag would never start in the middle of a
square. Picking an object by clicking still goes through `hitTest`, otherwise among overlapping
shapes the one with the wider frame would win.

**Text works like Figma's.** A click with `T` places a label as wide as what is typed (lines break
only on Return); a drag sets the width of a box it wraps inside. What is typed shows in its final
look straight away: the text field on top is invisible except for its caret, and the canvas draws
the label from the typed string. A double click on a label (any tool), a click on one with `T`, or
`↩` on a selected one edits it. `Esc`, `⌘↩` or a click elsewhere finish; an empty label leaves no
trace, an edit is one step of `⌘Z`, and the tool stays `T`. `F` walks three label styles: plain with
a soft shadow, outlined in a contrasting colour, and a pill plate of the colour with black or white
letters picked by luminance.

The project is generated by **Tuist**: the structure is described in `Project.swift`, and the
`.xcodeproj` is an artifact, not the source of truth.

## Reference points

We measure ourselves against two products — when it is unclear how a feature should behave, look at
them first instead of inventing our own UX.

**The stock macOS Screenshot** (⌘⇧5 / ⌘⇧3 / ⌘⇧4, `Screenshot.app`) is the baseline for behaviour:
"full screen / region / window" modes, the floating thumbnail in the corner after a capture, the
timer, the choice of save folder, copying to the clipboard. All of that has to feel familiar, with
no surprises.

**Shottr** — <https://shottr.cc/>, what we want beyond the stock tool:

- capture: region, window, full screen, repeat the last region, delay,
  **scrolling capture** (long pages and chat threads);
- an editor on top of the shot: arrows (including curved ones), frames, ovals, text, a marker,
  a step counter, spotlight with a dimmed background, pixelation and object erasure,
  a backdrop (gradient, shadow, rounded corners);
- analysis: OCR and QR, a colour picker, an on-screen ruler with measurements.

From Shottr's technical claims we take the performance bar: a native app for Apple Silicon, a
capture in tens of milliseconds, a distribution of a few megabytes. That is the argument for
AppKit + ScreenCaptureKit and against heavy dependencies.

The full Shottr feature list is not Pawshot's roadmap but a reference for what users expect. What we
build out of it, and in what order, is up to the project owner.

```
Makefile                     every project command, including install into /Applications
Tools/GenerateAppIcon.swift  draws the app icon's layers in code (`make icon`)
Tools/make-dmg.sh            packs a built app into the DMG (`make dist`); its background is
                             drawn by Tools/GenerateDMGBackground.swift
docs/                        demo.gif, the README's demo (2× speed)
mise.toml                    pins for this folder: tuist 4.203.4, swiftformat 0.62.1
Config/Signing.xcconfig      signing, ad hoc by default; your identity goes into the git-ignored
                             Signing.local.xcconfig (copy the .example)
.swiftformat                 formatter config (default rules, swiftversion set)
Tuist.swift                  Tuist config
Tuist/Package.swift          third-party packages (Sparkle only), fetched by `tuist install`
Project.swift                the Pawshot (.app) and PawshotTests (.unitTests) targets, Swift 6
Pawshot/Resources/           Assets.xcassets (MenuBarIcon), AppIcon.icon and AppIcon-Debug.icon,
                             Localizable.xcstrings and InfoPlist.xcstrings (English and Russian)
Tests/PawshotTests/          unit tests

Pawshot/Sources/
  App/                       the SwiftUI App (scenes, main menu commands), AppDelegate,
                             stored settings, app state, layout-independent key translation
  App/Design/                shared tokens (the paw colour, radii, motion), key caps,
                             the icon's corner brackets as a Shape
  MenuBar/                   the menu under the paw and the paw's three states
  Settings/                  the settings window and the shortcut recorder
  Welcome/                   the welcome window ("Open Pawshot"): shortcuts, every access, login item
  About/                     the About window
  Onboarding/                the screen recording permission window
  HotKey/                    global hotkeys on top of Carbon + the binding model
  Overlay/                   full-screen region selection + all the geometry
  Capture/                   ScreenCaptureKit and screen recording access
  Editor/                    the editor window, the canvas, the document with undo
  Editor/Model/              annotations: arrow, rectangle, pencil, text,
                             blur, counter + style and palette
  Editor/Tools/              the list of tools and their hotkeys
  Editor/TextRecognition/    reading the text off the shot: Vision, and the pure
                             assembly of lines back into text
  Recording/                 screen recording: the engine (SCStream → AVAssetWriter),
                             the pause clock, the controller, the pill
  VideoEditor/               the window a recording opens in: pieces, formats, export, GIF
```

## Hard rules

- **The chrome is SwiftUI on Liquid Glass; AppKit stays only where SwiftUI can't do the job.**
  Menus, settings, small windows, toolbars and panels are SwiftUI views (`.glassEffect`,
  `.buttonStyle(.glass)`, `GlassEffectContainer`). AppKit remains for exactly four things, each
  for a reason the platform imposes: the annotation canvas (`AnnotationCanvasView`, embedded via
  `NSViewRepresentable` — SwiftUI `Canvas` has no per-object hit-testing, text input or cursor
  rects), the capture overlay (a borderless full-screen `NSWindow` drawn in CoreGraphics, for the
  4–13 ms budget), the global hotkeys (Carbon) and owning the editor's `NSWindow` (the "resize the
  window = crop the shot" logic lives in its delegate). Don't move any of the four into SwiftUI,
  and don't build new chrome in AppKit.
- **The UI is built in code.** No storyboards, no xibs.
- **The entry point is `@main struct PawshotApp: App`** with `@NSApplicationDelegateAdaptor`. The
  main menu comes from SwiftUI plus `.commands` in `PawshotApp.swift`: ⌘S, ⌘D and Clear All live
  there, and remove them and the editor loses those shortcuts — including on a Cyrillic layout,
  where the canvas re-dispatches ⌘-keys through `NSApp.mainMenu`.
- **Deployment target is macOS 26.** Liquid Glass exists only from Tahoe, so there is no
  `#available` scaffolding and no fallback UI.
- **macOS only.** No iOS / Mac Catalyst / visionOS targets and no `macWithiPadDesign` in
  `destinations` — it is exactly `.macOS`, i.e. `[.mac]`.
- **The project structure lives in `Project.swift`.** New files reach the target through
  `sources: ["Pawshot/Sources/**"]`, which means `tuist generate` is required after adding a file.
  The `.xcodeproj` is neither edited by hand nor committed.
- **Annotations are drawn as objects, not into pixels.** Every arrow is a model in
  `EditorDocument.annotations` that the canvas redraws. Drawing straight into a bitmap breaks
  moving, `⌘Z` and recolouring after the fact.
- **Annotation coordinates are in the captured frame's system**, not the window's and not the
  crop's. The canvas shifts the input by `document.cropRect.origin` itself, and the renderer
  applies the same shift on export. This is what lets the shot be resized
  without touching a single annotation — store points in view coordinates, or relative to the
  crop, and everything moves the moment the shot grows to the left.
- **Wrote Swift — run SwiftFormat.** Every created or modified `.swift` goes through the formatter
  before the work is declared finished: `mise exec -- swiftformat <file>` or all at once
  `mise exec -- swiftformat Pawshot/Sources Tests`. The rules are the defaults, the config is
  `.swiftformat`. There is no point arguing with the style: whatever the formatter decided is
  correct.
- **Coordinate arithmetic lives in `SelectionGeometry`, and only there.** Converting between AppKit
  (origin at the bottom left) and CoreGraphics (origin at the top left) is the source of the most
  infuriating bugs: the shot turns out to be of "the wrong part of the screen" — one that looks a
  lot like the right one. Everything that computes rectangles is written as a separate function and
  covered by a test instead of spreading across views.
- **`TextRecognitionService` is the only file that imports Vision, and `TextLayout` is where the
  thinking happens.** The service asks for the lines and converts their boxes into pixels; deciding
  where a blank line was, where a column ended and how deep a line was indented is a pure function
  over those boxes, and its fixtures are boxes measured off real screenshots. Put any of that
  reasoning next to the framework call and it stops being testable at the moment it starts being
  worth testing.
- **Keys are read off the physical key, never off the character.** Anything matching a letter goes
  through `KeyboardLayout`; `event.charactersIgnoringModifiers` on its own is how every tool
  shortcut came to be dead on a Russian layout. A window with a first responder of its own
  overrides `performKeyEquivalent` with `KeyboardLayout.performMenuEquivalent`, as the canvas and
  the video editor do — otherwise ⌘S there is dead on ЙЦУКЕН.
- **Every user-visible string goes through `Localizable.xcstrings`.** SwiftUI literals
  (`Text("…")`, `Button("…")`, `.help("…")`) are picked up by themselves; a helper that passes
  text along takes `LocalizedStringKey`, and text that travels as a `String` (models, errors,
  alerts, window titles) is `String(localized:)` where it is written. Stored values — the
  `"Space"` label of a `HotKeyBinding` — stay English and are translated only when shown.

## Commands

The entry point is `make`, which also inserts `mise exec --` so the pins from `mise.toml` are used
instead of the global tuist 4.7.0, under which the manifests don't work.

```
make            # list the targets
make build      # Debug build
make test       # run PawshotTests, minus the ones that take the screen or the focus
make test-ui    # every test, windows and overlays included — the Mac is busy meanwhile
make lint       # SwiftFormat, changing nothing
make format     # format the sources
make icon       # redraw the icon from Tools/GenerateAppIcon.swift
make install    # Release → /Applications, launch (launch at login works after this)
make dist       # Release → build/Pawshot-<version>.dmg to hand over, nothing installed
make release    # dist + a Sparkle-signed appcast.xml in build/release
make publish    # build/release → GitHub release v<version> (gh), which is what updates read
make uninstall  # remove from /Applications
make run        # build Debug and launch it
make clean      # wipe build/, Derived/ and the generated project
```

Under the hood it is still `tuist generate` / `tuist xcodebuild build|test`; `tuist edit` for
manifests with autocompletion is launched by hand.

Formatting runs on its own: the `Pawshot` target has a pre-phase `SwiftFormat` that fixes the
sources before compilation. The rules are the defaults, the config is in `.swiftformat`.

## Map: I want X → edit Y

Paths are given relative to `Pawshot/Sources/`.

| I want                                                | File                                    |
| ------------------------------------------------------ | --------------------------------------- |
| Change targets, bundle id, deployment target          | `Project.swift`                         |
| Signing: ad hoc by default, your Team ID locally      | `Config/Signing.xcconfig`, `Config/Signing.local.xcconfig` |
| The app version                                       | `MARKETING_VERSION` in `Project.swift`  |
| Add an Info.plist key (including `LSUIElement`)       | `Project.swift`, the `.dictionary` block |
| The entry point, scenes, main menu commands           | `App/PawshotApp.swift`                  |
| The "hotkey → selection → capture → preview" chain    | `App/AppDelegate.swift`                 |
| The menu under the paw                                | `MenuBar/CaptureMenu.swift`             |
| The paw's states (capturing, text copied)             | `MenuBar/MenuBarIcon.swift`             |
| The paw colour, radii, durations                      | `App/Design/Tokens.swift`               |
| **The icon image itself** (a paw inside frame corners) | `Resources/Assets.xcassets/MenuBarIcon.imageset/` |
| The app icon (Finder, Spotlight, Dock), Debug variant | `Tools/GenerateAppIcon.swift` + `make icon` |
| Launch at login                                       | `App/LoginItem.swift`                   |
| What is remembered between launches                   | `App/Settings.swift`                    |
| The settings window and the shortcut recorder         | `Settings/`                             |
| A shortcut field: ×, "Didn't reach Pawshot", its log   | `Settings/HotKeyRecorderView.swift`     |
| A key combination: storage, Carbon mask, `⇧⌘2` label  | `HotKey/HotKeyBinding.swift`            |
| Whether macOS still holds ⇧⌘3/⇧⌘4 for itself          | `HotKey/SystemScreenshotShortcuts.swift` |
| Recording: stream, writer, codecs, sound tracks       | `Recording/RecordingEngine.swift`       |
| Pause and the timestamps in the recorded file         | `Recording/RecordingClock.swift`        |
| Starting, pausing, restarting, stopping a recording   | `Recording/RecordingController.swift`   |
| The pill shown while recording, and its notch look    | `Recording/RecordingPill.swift`         |
| The pen: its panel, strokes and fading                | `Recording/InkPanel.swift`              |
| The dimming and frame around a region being recorded  | `Recording/RecordingFrame.swift`        |
| The outline shown for a zoom mark while recording     | `Recording/ZoomMarkIndicator.swift`     |
| The microphone permission                             | `Recording/MicrophonePermission.swift`  |
| The Input Monitoring permission                       | `Recording/InputMonitoringPermission.swift` |
| The mic level on the overlay, "no signal"             | `Recording/MicrophoneLevelMeter.swift`  |
| Recording overlay: keys, proportions, typed size      | `Overlay/RecordingOverlayOptions.swift` |
| Recording overlay: region handles, grips, magnet, toolbar | `Overlay/SelectionView.swift` + `OverlayHUD.swift` |
| Hover and press on the toolbar's and the pill's buttons | `App/Design/ChromeButtonStyle.swift`     |
| The microphones a take can record from                | `Recording/MicrophoneDevices.swift`     |
| The video editor window, its keys, hand-off, closing  | `VideoEditor/VideoEditorWindowController.swift` |
| Player, film strip, piece brackets, hints, footer     | `VideoEditor/VideoEditorView.swift`     |
| The kept pieces' rules, formats, size and time texts  | `VideoEditor/VideoEditing.swift`        |
| Everything about recording in Settings                | `Settings/SettingsView.swift`, `RecordingSettings` |
| Export presets, audio mixing, GIF, clipboard files    | `VideoEditor/VideoExporter.swift`       |
| What is recorded for effects: cursor, clicks, keys    | `Recording/EventRecorder.swift`         |
| The timeline file, shortcut labels                    | `Recording/EventTimeline.swift`         |
| Zoom segments, shortcut captions                      | `VideoEditor/EffectsPlanner.swift`      |
| The effects' layer tree (export and preview)          | `VideoEditor/EffectsLayerBuilder.swift` |
| Which window the cursor is over                       | `Overlay/WindowPicker.swift`            |
| The About window / the version it shows               | `About/AboutView.swift` / `App/AboutPanel.swift` |
| Updates: Sparkle, "Check for Updates…"                | `App/Updater.swift`, `SU…` keys in `Project.swift` |
| The shortcut itself and the Carbon plumbing           | `HotKey/GlobalHotKey.swift`             |
| Overlay looks: dimming, border, coordinates badge     | `Overlay/SelectionView.swift`           |
| Overlay windows, multi-monitor, app activation        | `Overlay/SelectionOverlayController.swift` |
| **Any coordinate or size arithmetic**                 | `Overlay/SelectionGeometry.swift`       |
| Capture parameters (scale, cursor, window filter)     | `Capture/ScreenCaptureService.swift`    |
| The screen recording permission request               | `Capture/ScreenRecordingPermission.swift` |
| The permission window (checklist, drag card)          | `Onboarding/PermissionView.swift`       |
| The editor window, the toolbar, resizing the shot     | `Editor/EditorWindowController.swift`   |
| The editor toolbar: tools, colours, widths, fill      | `Editor/EditorView.swift`               |
| What the toolbar shows and calls back into            | `Editor/EditorChromeModel.swift`        |
| The glass badge and key hints over the overlay        | `Overlay/OverlayHUD.swift`              |
| Flattening the shot with annotations into a picture   | `Editor/AnnotationRenderer.swift`       |
| The saved file name                                   | `Editor/Export/ExportNaming.swift`      |
| The clipboard, file formats, the save folder          | `Editor/Export/ExportService.swift`     |
| Save As…'s format picker                              | `Editor/Export/SaveFormatPicker.swift`  |
| The save folder and format settings                   | `App/Settings.swift` (`saveFolder`, `imageFormat`) |
| Drawing, mouse, hotkeys, text input                   | `Editor/AnnotationCanvasView.swift`     |
| The "drag an object or draw a new one" rule           | `Editor/CanvasInteraction.swift`        |
| ⌘Q: tap closes the window, hold quits                  | `App/QuitKey.swift`                     |
| The focus going back to the app in front on close     | `App/FocusHandBack.swift`               |
| The "Hold ⌘Q to Quit" toast                           | `App/QuitToast.swift`                   |
| The annotation list, selection, undo, turning the shot | `Editor/EditorDocument.swift`          |
| The colour picker behind the fifth swatch, hex        | `Editor/ColorPickerPopover.swift`       |
| The bottom capsule, the style chip, the top toolbar   | `Editor/EditorView.swift`               |
| The labels' family, its weights, the nearest face     | `Editor/Model/LabelFont.swift`          |
| A label's corner handles, the size drag               | `Editor/AnnotationCanvasView.swift`, `TextAnnotation.resize` |
| Which handles an object has, where, the cursor        | `Editor/CanvasHandles.swift`            |
| Dragging a handle: resize, turn, bend, the chip        | `Editor/AnnotationCanvasView.swift` (`beginReshaping`) |
| Turned boxes, bends, snapping to 15°                  | `Overlay/SelectionGeometry.swift`       |
| A new tool: letter, icon, object creation             | `Editor/Tools/AnnotationTool.swift`     |
| How a specific annotation looks and is hit by a mouse | `Editor/Model/*Annotation.swift`        |
| **Line breaks, blank lines, indent in the read text** | `Editor/TextRecognition/TextLayout.swift` |
| Talking to Vision, recognition languages, QR codes    | `Editor/TextRecognition/TextRecognitionService.swift` |
| A key that must work on any keyboard layout           | `App/KeyboardLayout.swift`              |
| A translation, a new language                         | `Resources/Localizable.xcstrings`, `defaultKnownRegions` in `Project.swift` |
| The language picker and how it is applied             | `App/Settings.swift` (`language`), `Settings/SettingsView.swift` |
| The welcome window, when it opens by itself           | `Welcome/WelcomeView.swift`, `PawshotApp.swift` |
| A window opened at launch coming above other apps     | `App/ComesForward.swift`                |
| "What's New" after an update: its text, when it shows | `App/WhatsNew.swift`                    |
| The "What's New" window itself                        | `About/WhatsNewView.swift`              |
| "Collect Logs": the gate every logger goes through    | `App/Log.swift`                         |
| Statistics: what is counted, favourites, the streak   | `App/Stats.swift`                       |
| The Statistics tab, its tiles and hints at zero       | `Settings/StatsView.swift`              |
| Save Logs, Send by Email, what the file holds         | `App/LogExport.swift`                   |

## Working notes

Everything above is what the project is. What follows is what the code doesn't show.

### Don't commit and don't push

The owner reviews and accepts the changes himself. Leave finished work in the working tree: no
`git commit`, no `git add` "just to stage it", no `git push`, no branches, no tags, no `--amend`,
no rebases — nothing that moves the repository forward.

This holds even when the work is finished, tests are green and a commit looks like the obvious next
step. Report what changed and stop there. The only exception is a direct, explicit instruction in
that very message ("commit this", "push it") — an approval given for an earlier commit doesn't
carry over to the next one.

### Tests must not get in the owner's way

He works at this Mac while an agent runs the tests, and some of them put windows up, activate the
app or dim every screen for seconds. `make test` skips those (`UI_TESTS` in the `Makefile`) and
is what an agent runs; `make test-ui` runs everything and only on the owner's word. A new test
that shows, activates or covers anything goes into `UI_TESTS`. The test host also registers no
global hotkeys (`AppDelegate.registerHotKeys`): it ran next to his own copy, and his ⇧⌘2 then put
up two overlays.

### Where the capture delay actually comes from

Measured, not assumed — the log line `content … ms, shot … ms` in `ScreenCaptureService` exists for
exactly this:

- enumerating shareable content: **8–12 ms**;
- `SCScreenshotManager.captureImage`: **~79 ms cold, ~24 ms warm** — the same call, three times
  cheaper when it follows another one closely.

What helps is `ScreenCaptureService.warmUp()` — a throwaway shot at launch that pays the cold-start
price while nobody is waiting. It must be **full-size**, going through the same `capture(_:)` a
real capture uses: a 1×1 warm-up was tried and measured, and the first real capture still cost
125–142 ms, because the buffers are size-specific. It stays silent without the screen recording
permission — the app must not ask for anything before the user has asked for it: a capture, or a
button in the welcome window.

Measured on the owner's machine in Release, hotkey to crosshair (`ready … ms after the hotkey`):

| | before | after the warm-ups |
|---|---|---|
| first capture of a session | 125–142 ms | 91 ms |
| the ones after it | 47–73 ms | 66 ms |
| showing the overlay | 65–72 ms first, 5–9 after | 4–13 ms |

The overlay part came from `SelectionView.prepareCursors()`: the camera cursor renders an SF Symbol
lazily, and that used to land on the first press of space.

The 66 ms that remained were the capture itself: `SCShareableContent` 17–26 ms plus the screenshot
38–52 ms. That enumeration number is a lesson in measuring the right build — in Debug on an idle
machine it was 8–12 ms, and caching it was dismissed as "worth ten milliseconds"; in Release under
real use it turned out to be a third of the whole wait. It is cached now, and a cache hit logs
`content 0 ms` — on the ⇧⌘1 path only. Since 0.4.2 the overlay path needs a list taken after the
overlay went up and asks `SCShareableContent.currentProcess` every time (9–17 ms); it costs
nothing visible, the dimming is already on screen, and only `frames delivered` waits for it.

The cache holds only the display list, and it is dropped on
`NSApplication.didChangeScreenParametersNotification` plus whenever a requested display isn't in
it — a cache that outlived its monitors would otherwise turn into `displayNotFound` on a perfectly
good screen. The stale window list inside it is never read: window mode takes its own through
`onScreenWindows()`.

Open question worth measuring on a real day of use: how long the "warm" state lasts. If a capture
hours after launch is slow again, the answer is warming up after each capture too, not a timer —
a background utility has no business waking the GPU on a schedule.

Capturing displays stays sequential: `SCDisplay` isn't `Sendable`, so a task group would need an
unsafe wrapper, and it buys nothing on a single monitor.

### Reading the text: why Vision and not VisionKit

VisionKit's `ImageAnalyzer` is the obvious choice — it is what Apple's own Live Text runs on, and
`ImageAnalysis.transcript` hands the whole text over in one property. It was tried first and
dropped. Measured on rendered screenshots with a known original:

- it scans the shot **line by line across the full width**, so a sidebar next to a body of text
  comes back as `Файлы / Привет… / Настройки / And this line…` — every other line alternating;
- neighbouring lines get glued into one (`… : index return corrected`);
- every indent is stripped;
- and spaces are invented — `dropTarget(from` becomes `dropTarget (from`.

Vision's `RecognizeTextRequest` (the Swift API, macOS 15+, so no `#available` at this deployment
target) gives one observation per line, **already grouped by column**, with a box each. That last
one is doing all the work: `TextLayout` rebuilds the blank lines from the vertical gaps and the
indentation from the left edges, and both were checked against the source of the screenshot they
came from. `usesLanguageCorrection = false` is what stops the invented spaces.

Three defects survive everything and belong to Apple's recogniser, not to the choice of framework —
both engines produce them, `usesLanguageCorrection` does not touch them, `minimumTextHeightFraction
= 0` does not either, and there is no second candidate to fall back on (confidence 1.00 on the
broken reading):

- `->` loses its dash and comes back as `>`;
- `<=` comes back as `‹=`, U+2039 — the one worth undoing blindly, and `TextLayout` does;
- a lone `}` on its own line is not seen at all.

#### The cold start, and why it is not what it looks like

A warm recognition is **70–250 ms**. The first one is **32 seconds**, and the obvious conclusion —
that the system unloads the model after an idle spell — is wrong. Believing it cost an hour.

What actually happens is in the system log: `ANECompilerService` runs `Start of compilation of
network from file`, and `aned` just above it reads the caller's `SecTaskCopySigningIdentifier()`
and `SecTaskCopyTeamIdentifier()` before deriving a `cacheURLIdentifier`. **The compiled model is
cached against the signing identity of whoever asked for it.** A new identity buys a fresh
compilation.

| what ran | first recognition |
|---|---|
| a binary signed `Apple Development`, first run | **31 962 ms** |
| the same binary rebuilt from changed sources, same certificate | **252 ms** |
| a differently named binary, ad-hoc signed | **32 462 ms** |

So Pawshot pays those 32 seconds **once, ever**, when signed with a real certificate (the local
signing file): the identity survives rebuilds — the same property that keeps the screen recording
permission from resetting, see `### Signing and screen recording access`. `make install` does not
bring it back.

Two traps follow:

- **Measuring with throwaway binaries lies.** Every fresh `swiftc` output is ad-hoc signed under
  its own identity and honestly pays its own 32 seconds, which reads exactly like "the model
  decays". Build the scratch binary once and re-run *that* one, or sign it with the same
  certificate.
- **The one time it is paid is the first ⌘D of a freshly installed build**, and it is silent. That
  is what the warm-up in `EditorWindowController` is for — it starts the compilation while the
  window opens rather than when the key is pressed. It does not cover pressing ⌘D in the first
  seconds after an install, which is exactly how this was found.

Rejected on measurements, so nobody tries them again: `.fast` has no compilation at all (43 ms) but
reads `Файлы` as `a)aMllbl` and `{` as `I`; `setComputeDevice(.gpu)` and `(.cpu)` change nothing,
a fresh process still pays 31 926 ms, because the compilation is of the one shared model.

#### The trap inside the blank-line heuristic

The threshold for "there was an empty line here" is measured against the **line pitch** — the
median distance between neighbouring lines — and not against a line's box height. Vision's boxes
hug the glyphs, so a line with no descenders is visibly shorter than its neighbours; a first
version compared the gap to the box height and invented a blank line between `let corrected` and
`return corrected`. `TextLayoutTests` pins that exact pair.

Column zero is measured **per column**, not across the shot. Against the leftmost line of the whole
picture, the right-hand column of a two-column screenshot comes out indented by some forty spaces.

### Hotkeys: what can't be seen from the code

`RegisterEventHotKey` will happily accept `⇧⌘3`…`⇧⌘6` and report success — but the event never
arrives, because the system takes its screenshot shortcuts before Carbon hands anything to us.
Taking those shortcuts by force is possible only through a private SkyLight call
(`CGSSetSymbolicHotKeyEnabled`, what CleanShot X does); the owner decided against it — and then
chose ⇧⌘3/⇧⌘4 for recording anyway, freeing them in System Settings by hand.

So the warning can't be a pattern match: an early `isReservedBySystemScreenshots` flagged ⇧⌘3…⇧⌘6
forever, which would have kept warning after the owner unticked the system items. The real state
lives in `com.apple.symbolichotkeys` → `AppleSymbolicHotKeys`, one entry per id with `enabled` and
`value.parameters = (character, key code, modifier flags)`. Checked on the owner's machine: 28 is
⇧⌘3, 29 ⌃⇧⌘3, 30 ⇧⌘4, 31 ⌃⇧⌘4, 184 ⇧⌘5. A missing entry means the factory default, i.e. on — so a
Mac nobody touched gets the warning, and an unreadable preferences file fails towards warning too.
Another app's domain is cached per process: `CFPreferencesAppSynchronize` before every read, or an
unticked item keeps reading as enabled until restart.

The Touch Bar's own ⇧⌘6 and ⌃⇧⌘6 (ids 181 and 182) are in the table as **off** by default, unlike
the rest: the system holds them only on a Mac with a Touch Bar, there is no public way to tell,
and the owner's Mac has none — an "on" default warned about a zoom key that works. Only an explicit
enabled entry warns. The ids are Apple's usual ones, not checked on a Touch Bar Mac.

Second thing the code doesn't show: while the settings window records a new combination, the app's
own hotkeys are **unregistered** (`Settings.onHotKeyRecordingChange` → `AppDelegate`). Without it,
pressing the current shortcut to replace it would fire a capture instead. The flip side: whatever
ends a recording must say so. Closing the window or switching the Settings tab with a field still
recording sent nothing — measured — and every hotkey stayed unregistered until a relaunch, so the
recorder also ends on `NSWindow.willCloseNotification`, on leaving its window and on
`NSWindow.didResignKeyNotification` (`HotKeyRecorderViewTests` post the notification; a test host
has no key windows of its own). The last one came from a tester's log: the field kept recording
while she was in other apps, and all four hotkeys were gone for 35 s.

Third: **a combination macOS or another app takes first never reaches Pawshot at all** — not the
recorder, not Carbon. The same tester had macOS's own "Move focus to next window" (item 27) moved
from ⌘` to ⌘1, and ⇧⌘1 — its other direction — left not one key press in the log across six tries, while ⇧⌘1 registered as the
full-screen shortcut for three days fired zero times. Nothing takes such a key back (short of the
private SkyLight call, which the owner refused), so the recorder says it instead: modifiers with
⌘, ⌥ or ⌃ held and let go with no key in between, or the window losing focus mid-chord, show
"Didn't reach Pawshot" with the reason in a tooltip. While a field records, a local
`NSEvent` monitor logs every key event the app receives — only watching, it hands each one on —
which is what tells "never arrived" from "arrived and a menu item took it", and a key up with no
key down names the key that was taken. Item 27 is now in `SystemScreenshotShortcuts` with
`reversesWithShift`, so Settings turns ⇧⌘1 red and names it; that macOS takes the ⇧ direction of a
moved item is read off her log, not tried on a Mac. The saved log lists every macOS shortcut that
is switched on (`item 27: ⌘1`) and the keyboard layout, so the next such item shows there.

Logging a registration uses `privacy: .public` on purpose — the default redacts interpolated
strings to `<private>`, and this log line is exactly how a hotkey is verified from the outside.

### Recording: what can't be seen from the code

- **The engine must not be created on the main thread.** `AVAssetWriter` + `SCStream` built there
  make the test log `This method should not be called on the main thread as it may lead to UI
  unresponsiveness`. Moving just the creation into a detached task silenced it.
  `RecordingController.makeEngine` is nonisolated for this, and it is also where every
  non-`Sendable` ScreenCaptureKit object lives and dies, so nothing has to cross actors.
- **Keeping our windows out of the video** is `SCContentFilter(display:excludingApplications:…)`
  with our own `SCRunningApplication`. `NSWindow.sharingType = .none` looks like the tool, and
  since macOS 15.4 ScreenCaptureKit ignores it.
- **`SCStreamConfiguration.width/height` default to 1920×1080**, whatever the source — always set
  them. And even: 4:2:0 video is coded in 2×2 blocks (`recordingPixelSize`).
- **A still screen sends no frames.** Only `SCFrameStatus.complete` carries a picture. That is why
  the last frame is repeated at the moment of stop — otherwise a take ending on a static screen is
  shorter than its sound — and why "frames stopped arriving" can't be a watchdog:
  `didStopWithError` is the only honest signal.
- **The pill panel ignores the mouse once it shrinks to a dot**, otherwise its invisible body
  swallows clicks meant for the app under it.
- **The overlay never asks for the microphone.** It sits at `.screenSaver` level, and the system
  prompt would open underneath it. Pressing M there only flips the setting; the level meter runs
  only with access already granted, and the prompt comes from `RecordingController.start`, after
  the overlay is gone.
- **"No signal" means digital silence, not a quiet room.** A working microphone in a silent room
  still reads about −60…−70 dBFS; a muted or vanished one delivers zeros. The threshold is 1e-5
  RMS, far under any real room, so a pause in speech never passes for a dead mic.
- **`AVAudioEngine` with no input device reports a 0 Hz format**, and installing a tap on it
  crashes. The meter checks the format first and shows "no signal" instead.
- **Two sound tracks don't mix by themselves.** With the microphone on, the file has system audio
  and the voice as separate tracks, and most players play only the first. Measured on a synthetic
  file: `AVAssetExportPresetHEVCHighestQuality` and `HighestQuality` keep both tracks, `1920x1080`
  happens to mix them — and an explicit `audioMix` listing every track makes any preset mix. So
  the exporter always sets one when there is more than one track, and the original stops being
  passthrough in that case. `VideoExporterTests.testTwoSoundTracksComeOutMixedIntoOne` went red
  before the fix.
- **A video on the clipboard is a file, and the file has to outlive the paste**, so clips are
  written to Caches (`com.caramelheaven.pawshot/Clips`), not the temporary folder, and anything
  older than a day is swept on the next export.
- **The effects' time zero is the start of the first piece only because the composition is
  spliced.** The export lays the kept pieces end to end in an `AVMutableComposition` starting at
  zero, instead of setting `timeRange` on the session — with the latter it is not obvious which
  clock the animations run on, and a ring would land seconds off. Every event goes through
  `KeepRanges.outputTime(forSource:)`; `EffectsRenderTests` looks at the pixels of a spliced file.
- **A test for a minimum length must respect the minimum.** `KeepRanges` refuses pieces under
  0.5 s — silently, by clamping or returning `nil` — and a first version of the splice tests asked
  for 0.4-second pieces and quietly tested something else. Assert what the model gave back
  (`XCTAssertNotNil(keep.add(...))`, `outputTime` of the event) before relying on it.
- **`AVAssetImageGenerator` can't run a Core Animation tool**, so a GIF with effects is two
  passes: an effects movie into the temporary folder, then the GIF from it.
- **`AVMutableVideoComposition` and its instructions are deprecated in macOS 26** — at this
  deployment target that is a warning. The replacement is the `Configuration` structs
  (`AVVideoComposition.Configuration` and friends). `AVVideoCompositionCoreAnimationTool`'s own
  `Configuration` only arrives in 27, so its old initialiser stays.
- **Clicks need no permission, keys do.** `NSEvent.addGlobalMonitorForEvents` for mouse-downs
  works as it is; reading keys takes a listen-only `CGEventTap` and Input Monitoring. The system
  switches a tap off after a slow callback (`tapDisabledByTimeout`) and it must be switched back
  on, or the captions stop halfway through a take.
- **The pen panel has to be on screen before the filter is built — and "ordered front" is not on
  screen yet.** It is the one Pawshot window let into the video (`exceptingWindows`), and the
  exception is fixed when the stream starts. Measured: straight after `orderFrontRegardless`,
  ScreenCaptureKit lists the window with a zero frame and `isOnScreen == false`; 0.3 s later it is
  there. `InkPanelController.waitUntilOnScreen()` polls `CGWindowList` and yields the run loop —
  12–49 ms on the owner's machine. `InkPanelCaptureTests` went red without it.
- **The zoom outline follows the export's merge, not the cursor.** `EffectsPlanner.zoomSegments`
  folds a mark within `zoomMergeGap` of the previous zoom into it, centred on the first mark, so a
  second ⇧⌘6 close behind only extends the outline where it already is. A mark while paused is
  not recorded, and nothing lights up for it.
- **The editor plays the export's own splice, not the recording.** Jumping over the grey from a
  periodic observer let up to ~33 ms of cut footage through at every seam, and the effects, built
  on the whole recording, ran on past seams the export cuts them at. So there are two players:
  the splice (`VideoExporter.previewItem`, the export's tree on top) plays; the recording shows
  paused and while editing, because an edge dragged into the grey has to show that frame. The
  layers switch only after the other player's seek has finished, or the switch flashes.
- **A window recording has no pen**: its filter (`desktopIndependentWindow`) sees that one window
  and nothing else, so there is nothing to let the pen's panel into.
- **The notch geometry uses only the widths of `auxiliaryTopLeftArea`/`auxiliaryTopRightArea`.**
  Which coordinate space those rectangles come in is not obvious from the docs; the widths are the
  same in any of them.
- **A window opened after a recording turns up behind other apps' windows.** Another app is in
  front by then, and macOS 14+ activation is cooperative: `NSApp.activate()` from a background
  utility may simply not be granted, and `makeKeyAndOrderFront` then only raises the window among
  Pawshot's own. `orderFrontRegardless()` puts it above everyone either way.
  `VideoEditorOrderingTests` reproduces it — the test host is a background app under xcodebuild —
  and was red without the call.
- **A SwiftUI view built ahead of time must not capture its actions.** The toolbar on the
  recording overlay is prebuilt at launch (`OverlayHUD.prepare()`), and its actions are filled in
  per capture on `@ObservationIgnored` properties. `Button(action: model.start)` captured the empty
  default when the body was first built, and since changing an ignored property never rebuilds
  the body, every button stayed dead — ↩ worked only because it goes through `keyDown`. The call
  has to go through the model at tap time: `Button(action: { model.start() })`.
  `RecordingBarTests` clicks the real button with synthetic events and was red before.
- **Dropping a `GlobalHotKey` must unregister it — and for a long time it didn't.** The registry
  that maps Carbon's ids back to objects held them *strongly*, so `hotKey = nil` never ran the
  `deinit` with `UnregisterEventHotKey`. Nothing was ever given back: after the first recording
  its shortcuts stayed taken system-wide, every later recording logged `RegisterEventHotKey
  failed with status -9878` for them, and a shortcut replaced in Settings kept firing. Found in the
  owner's log, not in tests. The registry is weak now; `GlobalHotKeyTests` was red before.
- **Carbon refuses a combination the app still holds** (-9878, `alreadyTaken`). So re-registering
  means dropping the old hotkey *first*: assigning a new `GlobalHotKey` over the old one registers
  the new one while the old is alive, and an unchanged shortcut fails against itself.
  `AppDelegate.registerHotKeys()` and `RecordingController` both unregister before registering.
  (An earlier note here blamed restarts alone; the leak above was the bigger half of it.)
- **The recording bar's hosting view needs a real frame.** All three glass pieces over the overlay
  used `sizingOptions = []`, which makes `fittingSize` 0×0. SwiftUI still draws the content past
  the empty frame, so the bar looked right while every click went through it to the overlay —
  which took it for the start of a new region. The bar measures itself now
  (`.intrinsicContentSize`); the badge and the hints keep their zero frames on purpose, so they
  never catch a click. `RecordingBarInOverlayTests` clicks Record through the real overlay window;
  the earlier `RecordingBarTests`, with the bar in a plain window, could not have caught it.
- **`print` from tests never reaches the log** — `tuist xcodebuild` pipes it through a formatter
  that drops it. A probe test that needs to report writes to a file in the scratchpad instead.
- **X is both the 1x/2x key and the separator in `1920x1080`.** It separates only once digits are
  typed; before that it switches the scale. `RecordingSelectionViewTests` pins both.

### Two languages: what can't be seen from the code

- **The language is `AppleLanguages` in the app's own defaults, and it is read once, at launch.**
  Menus, alerts and the system's own Edit items would not follow a live switch — only SwiftUI
  `Text` would, through `\.locale` — so Settings → General offers a Relaunch button instead of
  pretending. The choice is also kept under `app.language`: read back through `UserDefaults`,
  `AppleLanguages` falls through to the system's list whenever the app has none, and "System"
  could never be told apart from "Russian".
- **The tests run in English.** The test host is the app itself, with the same defaults, so after a
  switch to Russian `"Space"` would come back as `"Пробел"` under them. `make test` passes
  `-testLanguage en`, and the project's automatic schemes carry `testLanguage: "en"` for Xcode.
- **The catalog is filled by a build.** `SWIFT_EMIT_LOC_STRINGS` makes the compiler write
  `.stringsdata` per file; Xcode merges them into `Localizable.xcstrings` on a build in the IDE,
  and from the command line it is `xcrun xcstringstool sync Pawshot/Resources/Localizable.xcstrings
  --stringsdata <each file>` from `DerivedData/…/Pawshot.build/Objects-normal/arm64/`. A string
  with no Russian falls back to its English key, silently.
- **The names of System Settings are Apple's own**, copied out of the system's tables
  (`KeyboardSettings.appex/…/DefaultShortcutsTable.loctable` and friends), so "untick «Сохранить
  изображение экрана как файл»" matches what is on the screen word for word.
- **The language picker writes `AppleLocale` too** (`ru_GB`: the language with the Mac's own
  region). The strings follow `AppleLanguages`, but numbers, dates and durations follow the
  locale. Measured with a script on the owner's Mac: under `-AppleLanguages (ru)` alone
  `Locale.current` stayed `en_US@rg=gbzzzz` and printed "41 days", "2 hr, 14 min", "21 September"
  — the Statistics tab in a Russian interface; with `-AppleLocale ru_GB` it printed «41 день»,
  «2 ч 14 мин», «21 сентября». A script, not the bundle, so whether the app alone would have
  done better is not known; the key is harmless either way. It is written only when the language
  is picked: a Mac that picked Russian before 0.4.7 picks it once more.
- **The log stays English whatever the interface speaks.** Shortcuts go in as
  `HotKeyBinding.logString` (the stored `Space`, never «Пробел»), errors as
  `String(describing:)`, a system shortcut the Save Logs header finds taken as its id
  (`item 30`), and the header's numbers in `en_US_POSIX`.

### The recording region's handles

- **One answer for the cursor.** The overlay used to hang a crosshair cursor rect over the whole
  view and set the resize arrows by hand; the HUD's subviews move on every redraw, AppKit
  rebuilds cursor rects each time, and the crosshair kept coming back over the arrow — an edge
  was a lottery to catch. Now `SelectionView.cursorKind` decides for every path: the cursor
  rect (built with the cursor for where the mouse is), `mouseMoved`, `cursorUpdate`, the press,
  each drag step and the release. The key overlay also hears the mouse on other screens and
  leaves the cursor alone there.
- **Zones match the drawing.** Corners reach 16 pt each way — the brackets' arms — and edges
  10 pt either side of the line; on a small region both shrink to a quarter of the side so the
  middle stays grabbable. A grabbed edge follows the mouse by how far it moved
  (`SelectionGeometry.handleTarget`) instead of snapping to the pointer.
- **No region of nothing.** An edge dragged onto its opposite would leave a region too small to
  grab; on release it goes back to what it was before that drag.
- **An edge hidden under another window is no line to stick to.** `SelectionGeometry.snapLines`
  takes a window's edge only if that window is the one on top right beside the edge, at the
  height nearest to the region's middle; the list comes front to back from before the overlay.
- **The buttons' hover is not SwiftUI's.** The overlay never activates Pawshot and the pill
  floats over the app being recorded, so both live in a panel of an app that isn't active, and
  `onHover` there is not something to lean on. The owner of each piece knows where the mouse is —
  the overlay's tracking area hears every move, toolbar included; the pill's hosting view has an
  always-active one — and puts the point into the environment (`chromeHoverPoint`); each button
  checks it against its own frame in the piece's named coordinate space. Whether plain `onHover`
  would have worked was not measured.
- **A system menu or a tooltip opens under the overlay**, which is at the screen saver's window
  level — the same reason the microphone prompt is never asked for there. So Options is a panel
  drawn by the toolbar itself, and its buttons draw their own tooltips. The Options panel changes
  the toolbar's size while its frame is set by hand: toggling it asks the overlay to lay the
  toolbar out again on the next turn of the run loop.
- **The microphones are listed when Options open, not when the overlay does.** Asking the
  system for devices is not for the 4–13 ms between the hotkey and the dimming. Until then the
  meter and the take use the stored device id; a device that is gone falls back to the system's
  (`MicrophoneDevices.resolved`), with an `.error` in the log.

### SwiftUI and Liquid Glass, and the four places that stay AppKit

On 2026-09-26 the owner moved the app from pure AppKit to SwiftUI + Liquid Glass (macOS 26
target). The chrome is SwiftUI now; what stayed AppKit stayed for a platform reason, not out of
habit, and each one is worth knowing before "just porting it":

- **The annotation canvas.** SwiftUI `Canvas` draws, but offers no per-object hit-testing, no text
  input and no cursor rects, and the whole ⌘-key re-dispatch for non-Latin layouts
  (`performKeyEquivalent` → `KeyboardLayout`) lives in the canvas's responder chain.
- **The capture overlay.** A borderless full-screen window that has to appear 4–13 ms after the
  hotkey; it is drawn in CoreGraphics. Glass pieces on top of it are separate small views.
- **The global hotkeys.** Carbon; SwiftUI has nothing that fires while another app is in front.
- **The editor window.** `EditorWindowController` owns the `NSWindow` because "resize the window =
  crop the shot" is window-delegate logic (`windowWillResize`, live resize, chrome measurement).

Two SwiftUI traps met on the way in:

- The app has its own `Settings` class (the stored preferences). Inside the module it shadows
  SwiftUI's `Settings` scene, so the scene is written `SwiftUI.Settings { … }` in `PawshotApp`.
- A window opened from the menu of an accessory app opens *behind* whatever is in front unless
  `NSApp.activate()` runs first — every "open a window" action in `CaptureMenu` does that.
- **An `NSHostingController` as a window's content swaps the window's undo manager.** After the move
  `window.undoManager` returned one SwiftUI supplies, `windowWillReturnUndoManager` was no longer
  asked, and Edit → Undo — `undo:` down the responder chain, answered by `NSWindow` — undid in an
  empty manager: ⌘Z silently did nothing. Measured with a probe: document manager ≠ window manager.
  The canvas, first in the chain, now answers `undo:`/`redo:` itself;
  `EditorWindowControllerTests.testUndoSentDownTheResponderChainUndoesTheLastChange` pins it.
- **SwiftUI's `.saveItem` command group also holds Close.** Replacing it with only "Save to Desktop"
  took ⌘W away; `PawshotSmokeTests.testMainMenuKeepsTheEditorShortcuts` reads the real main menu of
  the test host and checks ⌘W, ⌘S, ⌘Z, ⌘C and ⌘D.

### Formatting is mandatory, and it is triple

Style in this repository is not up for discussion — it is dictated by SwiftFormat with the default
rule set (config `.swiftformat`, version pinned in `mise.toml`). There are three safety nets, and
they duplicate each other on purpose:

1. **The `PostToolUse` hook** in `.claude/settings.json` — formats every `.swift` right after
   Edit/Write. It doesn't always work: if `.claude/` didn't exist when the session started, the
   settings watcher won't pick it up. Then it's `/hooks` once, or a restart.
2. **The `SwiftFormat` pre-phase** in the `Pawshot` target — fixes the sources on every build.
   Verified: broken indentation is fixed in that same build, not the next one.
3. **The rule in `AGENTS.md`** — by hand, if the first two stay silent.

Hence the practice: finished editing Swift — run `mise exec -- swiftformat <file>` and don't
consider the work done until that has happened. Code reformatted by the agent is not an "extra
diff", it is the norm in this project.

### Environment

- The tuist version is pinned in this folder's `mise.toml` (`4.203.4`). Globally
  `~/.config/mise/config.toml` has **4.7.0** — the manifests won't work under it: that one still
  expects the old `Tuist/Config.swift` format, while here there is a root `Tuist.swift`. Inside the
  folder mise substitutes the right version by itself; if the config isn't trusted — `mise trust`.
- `tuist generate` **opens Xcode by itself**, no separate command is needed. Use `--no-open` when
  only the generation is wanted.
- SourceKit complains about `Project.swift`/`Tuist.swift` ("No such module 'ProjectDescription'")
  and about files in `Pawshot/Sources` before the project is generated — that is editor noise, not
  a build error. What has to be checked is `tuist build`, and manifests are edited through
  `tuist edit`.
- In this shell `tr` is shadowed by an alias to `tuist`, and `ls` doesn't accept a bare path —
  call `/bin/ls`, and don't build pipelines on `tr`.

### Logs: what a shared log has to be

A person with a problem presses **Settings → General → Diagnostics → Save…**, picks where
the file goes, and sends it — or **Send by Email…**, which attaches the same file to a new message
to `AboutPanel.contactEmail` (`NSSharingService(.composeEmail)`; with no mail account the file is
shown in the Finder and a plain `mailto:` opens) (`App/LogExport.swift`). The file is a header — build, macOS, Mac
model, displays, the three permissions, every shortcut and whether macOS still takes it, the main
settings, other running copies — then Pawshot's log for the last three days (`/usr/bin/log show`
from the app: there is no sandbox, so no rights are needed), the last three crash reports, and the
main thread's stack from the last two overlay stalls (see the first ⇧⌘2 below).

Two rules make that file worth reading, and every new log line follows them:

- **Milestones are `.notice`, failures `.error` — never `.info`.** macOS keeps `.info` in memory
  only; an hour later it is gone, and a log saved the next day was empty exactly where it
  mattered.
- **Every interpolated string, error and flag is `privacy: .public`.** The default turns them into
  `<private>`, and a line that says `hotkey <private> not registered: <private>` says nothing.
  Log `String(describing: error)`, not `localizedDescription` — the case name is what tells two
  failures apart.
- Read `self` properties into a local before the log call: SwiftFormat strips `self.` inside the
  message's autoclosure, and the build then fails on implicit self.

**"Collect Logs" is a real switch** (`app.collectsLogs`, on by default, the owner's call on
2026-09-28; in Settings → Diagnostics and in the welcome window). Off, every logger is
`Logger(.disabled)`, no stall is sampled, both buttons hide, and the stall samples and the last
mailed file are deleted. That is why no file declares `static let logger = Logger(…)`: each one is
`static var logger: Logger { .pawshot("category") }` (`App/Log.swift`), made at every use, so the
switch works at once — a stored logger would keep writing until a relaunch. A new logger follows
the same line. What macOS already wrote stays in the system log until it rotates it; removing it
takes root. The test host shares the app's defaults, so with the switch off on the owner's Mac
`testLogShowRunsAndFindsOurLines` skips itself.

What is covered: launch facts, every hotkey registration, unregistration and press (a press with
nobody behind it is an `.error`), every early return of a capture, the overlay's begin, mode,
cancel and selection, the editor's opening, exports and their failures, ⌘Q's every decision, the
shortcut fields (every key event while one records, why it stopped, a refusal naming the action
that holds the combination, a × clearing it, a shortcut changed from what to what), settings
changes, permission prompts, recording and the video editor. A hotkey's lines name its action —
`hotkey fired: ⇧⌘2 (capture a region), Firefox in front`.

### The overlay goes up before the capture, and never activates Pawshot

Until 0.4.2 the hotkey first froze every display and only then showed the overlay. On a MacBook
Air M1 (3008×1692 pt @2x, 20 megapixels) that freeze took 99–140 ms, so the dimming came a
noticeable beat after the key. A log from that Mac also showed the stall below. Now, in this order:

1. The hotkey puts the overlay up at once, over the live screen (`startOverlayCapture` →
   `SelectionOverlayController.begin`). Its windows are **built at launch and reused**
   (`prepareWindows`, rebuilt when the displays change), so no window is created on the hotkey.
2. The frames are captured behind it with **Pawshot left out**
   (`SCContentFilter(display:excludingApplications:exceptingWindows:)`). Our other windows — an
   open editor, the paw — are excepted, so they stay in the frame. `InstantOverlayTests` compares
   the frame with and without the exclusion; it went red when the exclusion was removed.
   **The list the exclusion comes from is `SCShareableContent.currentProcess`, not the on-screen
   one.** ScreenCaptureKit notices a window ordered in a moment ago a beat late, and until it
   does, the on-screen list has no Pawshot in it at all — so there was nothing to leave out, and
   the frame came out with the dimming in it. A tester's 0.4.2 log showed it twice (`Pawshot not
   in the window list`, an `.error` now). Measured straight after `begin`: the on-screen list
   missed Pawshot in 3 of 15 queries; `currentProcess` never did, at the same 9–17 ms (the full
   list with off-screen windows never did either, at 35–51 ms). The first version of the test
   waited 300 ms before capturing and stayed green through all of it; the hotkey captures at
   +16–40 ms, and so does the test now, eight times over — red in the fifth attempt before the fix.
3. `deliver(frames:)` puts each frame under its overlay (`OverlayWindow.frameView`, a layer of its
   own that is drawn once), and a selection made before that — a fast flick — is cut out then.
   A failed capture closes the overlay (`fail()`).

Measured in the test host on a 5K screen: hotkey → first draw 9–52 ms (was 99–187), the frame
catches up at 43–95 ms.

The overlay is a **non-activating `NSPanel`**. It takes Esc, Space, M and ↩ without making
Pawshot the active app. Taking the keyboard may still close what the app in front shows: the
owner's Telegram Desktop photo viewer was gone from the frame (2026-09-29). Making the overlay key
only once the frame was taken was tried and rolled back: the dimming then leaked into the frame in
3 of 10 full test runs (`testTheFrameTakenAtOnceDoesNotContainTheOverlay`). The same change had
also put a `CGWindowListCopyWindowInfo` in `begin`, right before the overlay goes up, and the leak
kept coming with the key back at once (1 of 2) and stopped once that call was gone (7 of 7) — so
the call, not the deferred key, is the likelier cause, and the deferred key was not measured again
without it. **No window-server call belongs between the hotkey and the overlay** beyond the one
list `AppDelegate` already takes. The log compares the front app's ordinary windows from that list
with those at the frame and 500 ms in (`front app windows: … gone: …`, an `.error` when one went):
the next fix waits for that line from a real Telegram. Meanwhile ⇧⌘1 takes the screen with no
overlay at all. `NSApp.activate()` is gone from the overlay, and with it the cooperative
activation of macOS 14+, the Space it may switch to, and the four-second stall in her log. The
other app stays active, so its open menu is still open when the frame is taken — which is what
the old "freeze first" order was protecting. The editor that opens afterwards activates Pawshot
as any window does.

The frame no longer redraws on every mouse move: `FrameView` draws it once, and a move in region
mode with nothing drawn only moves the badge. The overlay log closes with `slowest N ms`, the
longest single draw; a redraw measured through `cacheDisplay` is not the real cost (a bare
full-screen fill measured 25 ms that way), so that number from a real Mac is the one to trust.

### The first ⇧⌘2 that shows nothing until a click — open

Seen by the owner on 2026-09-28: the first region capture after launch showed no dimming at all;
a click anywhere, and the screen went dark. Once per launch; later presses fine. Probably the same
thing as "the first ⇧⌘2 on a new Mac does nothing, the second works".

A log from a MacBook Air (0.4.1) caught it: the overlay drawn at +215 ms, the app active at
+164, and then four seconds with no queued work run and no mouse event, until a click — right
after two Space switches. Which is why 0.4.2 drops the activation (above) and watches the main
thread from another one: `main thread stalled over 250 ms at +N ms, run loop mode …; window
server: …` and `main thread back after N ms`. The run loop mode tells a busy main thread
(default or common mode) from AppKit waiting in a mode of its own.

Before that log: not reproduced. A probe called `beginCapture()` first thing in three fresh test-host processes,
with no user events at all: `begin` reached at +47–163 ms, the overlay drawn at +124–163 ms,
`occlusionState` visible 20–40 ms after that. What the probe did show: the app never became
active within 2 s (the test host is a background process under xcodebuild, where activation is
refused), and the launch warm-up was still running when the capture started. So the production
code is unchanged, and the path is logged instead (`OverlayDiagnostics`, `OverlayTimeline`), every
line `+N ms` from the hotkey:

- `capture task started`, `display … captured in`, `freeze done`, `overlay begin` — the steps up to
  the overlay; a gap here means the capture itself or the task hop stalled;
- `overlay window N … visible, on active space, occlusion-visible, key` per window, and
  `active before / right after` around `NSApp.activate()`;
- `overlay first draw +N ms` — the frame reached the screen;
- `overlay check` at ~100 ms, 500 ms and 2 s — an `.error` `NOT DRAWN YET` if it still hasn't;
- `overlay first event … drawn before it: false` — an `.error`, and exactly the report: the first
  click arrived before anything was drawn;
- `app became active / resigned active / active space changed (+N ms since the hotkey)` — the
  suffix only during a capture;
- `capture asked while the launch warm-up is still running`.

A "Save Logs…" file from a Mac where it happens tells which step never came.

**0.4.2 on the same MacBook Air: shorter, not gone.** The first ⇧⌘2 five seconds after a relaunch
drew at +37 ms, and then the main thread stood 910 ms in the default mode; at +301 ms the window
server had no window 41497 at all (`gone`), so the dimming most likely reached the screen only
after that. Twenty minutes after launch the same first capture was fine. The watchdog says *that*
and *where in the run loop*, not *what*, so on the first stall of an overlay it now runs
`/usr/bin/sample` on Pawshot for a second (`StallSamples`) into
`~/Library/Caches/com.caramelheaven.pawshot/Stalls` (five kept), and Save Logs attaches the last
two — the header with the memory footprint and the main thread's branch of the call graph. The
stall line also carries the memory pressure: the working guess, not proven, is the first
allocation of 6016×3384 surfaces on an 8 GB Mac under pressure. `sample` needs no root for a
process of the same user without hardened runtime; measured, a one-second sample takes 1.4 s and
0.37 s of CPU, and it starts some 250 ms into the stall, so it sees the rest of it.

**0.4.3, the stack: the main thread was asleep.** The first ⇧⌘2 4.5 s after the tester replaced
the app: drawn at +24 ms, the window still `gone` at +286, the main thread silent 947 ms — and in
all 84 samples it sat in `__CFRunLoopServiceMachPort → mach_msg2_trap`, the run loop waiting. No
code of ours ran; the thread was either never woken or woken and given no core. The Mac was
plainly busy: `didFinishLaunching` came 9 s after the process started (System Settings in front —
most likely Gatekeeper's "Open Anyway" for the self-signed build), and the one-second sample took
20 s to write, against 3 s half an hour later. Three guesses, none proven: the Mac checking the
new build right after the replace; App Nap on a menu bar agent with no windows (a 330 ms stall
also came on the first ⇧⌘3 after 35 idle minutes); the window server slow to bring a long-hidden
6016×3384 window back. The log now tells them apart:

- `overlay on screen +N ms (window server)` — watched from the watchdog's thread, so a stalled
  main thread can't delay it: when the dimming was really there, where "first draw" is only
  AppKit's (24–43 ms in the test host); an `.error` if not within 3 s;
- the stall line carries `main thread running|waiting, priority N (base M)` (`thread_info`):
  `running` with a stack asleep in the run loop is a thread starved of a core, a low priority is
  App Nap, `waiting` is a thread nobody woke; the same priority is logged at the hotkey;
- `load N.N` (the one-minute load average) in every `capture on a Mac with …` and stall line;
- `launch: finished N ms after the process started` — how long macOS held the launch.

Disabling App Nap waits for a log that shows the low priority.

The editor that opens after a capture usually finds another app active now (the overlay no longer
activates Pawshot), and activation from a background app can come late or not at all — the video
editor once opened behind other windows that way. In the tester's log it came 150–190 ms later
every time, so it is only watched: `editor after 500 ms: … window key false` is an `.error`, and
the answer to one is `orderFrontRegardless()`, as in the video editor.

### What can't be verified automatically here

Capturing means the mouse and a global hotkey, and synthesising input (`osascript`,
`CGEvent.post`) requires Accessibility, which the agent doesn't have; `screencapture` is off
limits for it too. Which means:

- geometry is verified by the `SelectionGeometryTests` unit tests — that's where all of it lives;
- launching and the absence of a Dock icon are verified through `CGWindowList` and
  `lsappinfo info -only ApplicationType <pid>` (it must be `UIElement`);
- hotkey registration — from the log: `/usr/bin/log show --predicate 'subsystem ==
  "com.caramelheaven.pawshot"' --last 5m`. The app logs at `.notice` and `.error` only (see
  `### Logs` below), so `--info` is no longer needed;
- everything else (the crosshair, the dimming, the badge, the capture result) — only with the
  owner's eyes. Writing "checked, works" about any of that is not allowed.

One thing worth knowing is on that list and matters: **whether AppKit matches ⌘-equivalents through
the ASCII-capable layout by itself**. It is understood to, which is why ⌘C works in Cyrillic across
the rest of the Mac, but pressing a key in a non-Latin layout is exactly what cannot be synthesised
here. Measured as far as it goes: an event carrying `в` on the D key, handed to
`NSMenu.performKeyEquivalent`, does **not** fire the ⌘D item — the test for
`KeyboardLayout.performMenuEquivalent` goes red without the rewrite. Whether a real keystroke
takes some other path through AppKit that does match is still unknown. So the canvas and the
video editor both override `performKeyEquivalent` with that function: it rewrites the event
through `KeyboardLayout.latinEquivalent(of:)` and offers it to the main menu. Whichever of the two gets there first answers `true`, so the design does not depend on
the order — and rewriting the whole event instead of keeping a table of shortcuts means ⌘Q and ⌘,
are covered as well, with nothing to keep in sync when a menu item is added.

**A named pasteboard outlives the test process.** `NSPasteboard(name:)` lives in the system
pasteboard server, so yesterday's value is still in it when the suite starts. A test that asserts
"the text arrived" therefore passes while reading the *previous* run's answer — which is how a
regression test for ⌘D was silently neutered here, and only showed up when the fix was removed on
purpose and the test kept passing. Clear it before the act, not after.

That trick is worth keeping in general: after writing a test for a fix, take the fix back out and
watch the test fail. A test that stays green without its fix is testing nothing, and in this
codebase the reason is usually state that survives the process.

A standalone binary is a good way to exercise recognition without the GUI: the three files in
`Editor/TextRecognition/` depend on nothing else in the app, so
`swiftc main.swift TextLayout.swift RecognitionLanguages.swift TextRecognitionService.swift`
runs the shipping code over a PNG and prints what ⌘D would put on the clipboard.

### Two mines already stepped on

Both belong to the "AppKit without a storyboard + Tuist" combination, and both produce an app that
builds green and doesn't work:

1. `infoPlist: .extendingDefault(...)` mixes in `NSMainStoryboardFile = Main`, and on launch you
   get `NSInvalidArgumentException: Could not find a storyboard named 'Main'`. That is why
   `Project.swift` uses `.dictionary(...)` — every key is listed explicitly. A key can't be removed
   from `.extendingDefault`, the API can't do that.
2. `@main` on `AppDelegate` in AppKit ≠ the same thing as in UIKit: it calls `NSApplicationMain`,
   which takes the delegate from the main nib/storyboard. Without a storyboard the process starts,
   stays alive and shows nothing — no window, no menu bar icon — and doesn't crash while doing it.
   *History since the SwiftUI move:* `@main` now sits on `PawshotApp: App`, which is a different
   thing and works; the trap only applies to `@main` on an `NSApplicationDelegate`.

3. `generationOptions: .options(defaultSwiftVersion: "6.0")` in `Tuist.swift` **does not affect**
   the targets' `SWIFT_VERSION` — in the generated project it stayed at `5.0`. That's why the
   version is set in `Project.swift` through `settings: .settings(base:)` at the project level.
   This is not cosmetic: strict concurrency is what keeps the AppKit parts and the SwiftUI app
   honest about the main actor.

Hence the verification rule: "it built" says nothing about whether it works. The app has to be
launched and the window has to be there. And `tuist build` (deprecated) turned out to be more
lenient in this project than `tuist xcodebuild build` — it let that very isolation error through as
a success, so the build has to be checked with `tuist xcodebuild build`.

### Export: where it's easy to get it wrong

Annotations are stored in image coordinates with the origin at the **top left** — the same as in
the canvas (`isFlipped = true`). That is why `AnnotationRenderer` flips the Y axis and creates
`NSGraphicsContext(cgContext:flipped: true)`. The flag is mandatory: without it the picture is
built without a single error, but the text ends up upside down and everything else mirrored
vertically. The trap for this is `AnnotationRendererTests.testAnnotationLandsWhereItWasDrawn` — a
red rectangle in the top third of the shot has to end up in the top third of the file.

Rendering happens in the original's pixels (`document.image.width`), not in points: on Retina that
is twice as many, and those pixels must not be lost on export.

Since the shot became resizable, the renderer also shifts the context by `-cropRect.origin`, the
same way the canvas does — annotations count from the captured frame, the bitmap starts at the
crop. An annotation that ended up outside the crop is clipped by the context and stays in the
document; that is deliberate, so shrinking and growing back doesn't lose work.

The price of resizing is memory: `EditorDocument` holds the **whole captured display** for as long
as its window is open — around 60 MB on a 5K screen, per window. That is what makes growing the
shot possible at all, and it is why the frame must not be re-captured instead: by the time the
editor is open, Pawshot is active and every other app's menu has already closed.

`⌘S` writes to the save folder (`Settings.saveFolder`, the Desktop by default; one gone missing
falls back to it), and macOS has a **separate permission** for the Desktop, Documents and
Downloads — the system asks on the first save there. A refusal arrives as a write error: we show an alert and **don't** close
the window, otherwise the work is gone.

### Installation and launch at login

`make install` builds Release and puts a copy into `/Applications` — only from there is the app
visible to Spotlight, and only from there does launch at login make sense.

`SMAppService.mainApp` remembers the **bundle path**. Launch at login enabled for a copy in
`DerivedData` will start exactly that one — that is, an old build, until you notice. That is why
the "Launch at Login" menu item is disabled when the bundle isn't in `/Applications`
(`LoginItem.isInApplicationsFolder`), and the state is re-read every time the menu opens: a person
can turn launch at login off in System Settings, and the checkmark has to show it.

The app icon is not stored as an editor source file — it is drawn in code
(`Tools/GenerateAppIcon.swift`, `make icon`). You edit the geometry in the script, not the PNGs.
Since macOS 26 the script writes Icon Composer bundles, `AppIcon.icon` and `AppIcon-Debug.icon`:
full-bleed white layers on a transparent 1024 canvas, with the tile colour as `fill` in
`icon.json`. The system draws the squircle, the glass and the dark/clear/tinted variants itself;
an icon that brings its own tile and insets (what the script used to draw) gets shrunk into a
grey plate. Tuist puts a `.icon` into the target as one opaque resource and Xcode compiles it by
extension — checked on a built bundle: `AppIcon.icns`, `AppIcon-Debug.icns` and
`CFBundleIconName` are there. The Debug configuration picks the grey icon through
`ASSETCATALOG_COMPILER_APPICON_NAME` in `Project.swift`.

Two copies of Pawshot must not run at once: Carbon lets both register ⇧⌘2, and one press then puts
up two overlays that fight over the mouse — that is exactly how "the first capture shows nothing"
was reported after the SwiftUI move, with the installed copy still running next to a Debug build.
`AppDelegate.replaceOlderInstances()` asks older copies to quit on launch (not under tests, whose
host is this same app).

### Signing and screen recording access

Signing lives in `Config/Signing.xcconfig`, wired into both targets from `Project.swift`. Out of
the box it is ad hoc (`CODE_SIGN_IDENTITY = -`, no team), so a fresh clone builds on any Mac; the
last line `#include? "Signing.local.xcconfig"` pulls in the git-ignored local file, where a
developer names a stable identity (`Signing.local.xcconfig.example` shows both kinds). The owner's
is `Pawshot Self-Signed` — a self-signed certificate made with openssl, `CODE_SIGN_STYLE =
Manual`, no team. Hardened runtime is off. Nothing personal — no Team ID, no certificate name — belongs in a tracked file.

With a self-signed identity the designated requirement is `certificate leaf = H"<hash of the
certificate>"`: it survives every rebuild, and it dies with the certificate. Lose the private key
and every user is asked for Screen Recording again after the next update — keep the exported .p12
somewhere safe. `security find-identity -p codesigning` lists it as `CSSMERR_TP_NOT_TRUSTED`
(so `-v` hides it); codesign signs with it all the same.

Making the `.p12` with OpenSSL 3 (Homebrew's) needs `-keypbe PBE-SHA1-3DES -certpbe
PBE-SHA1-3DES -macalg sha1`: its default AES/SHA-256 container is refused by `security import`
as "MAC verification failed … (wrong password?)", and the password is not the problem.

Tuist's default settings write `CODE_SIGN_IDENTITY = -` into every target, and a target's own
setting beats its xcconfig: the local certificate was silently ignored and the app came out ad
hoc. Hence `DefaultSettings.recommended(excluding: ["CODE_SIGN_IDENTITY"])` in `Project.swift`.
Checked both ways on a built bundle: with the local file `codesign -dvv` shows the chosen
authority (`Pawshot Self-Signed` now, `Apple Development` and the team before); without it,
`Signature=adhoc`.

Why a certificate at all: with an ad-hoc signature the designated requirement degenerates into
`cdhash H"..."` — the hash of one specific binary. Then every rebuild invalidates the granted
screen recording access and piles up duplicates in System Settings → Privacy & Security → Screen
Recording. With a certificate the requirement goes by the certificate (`certificate
leaf[subject.CN]` for Apple Development, the leaf's hash for a self-signed one) and survives
rebuilds, so the permission is granted once. The same identity keys the Neural Engine's compiled
text model (see the cold start above).

A new bundle id or a new signing identity is a new app to TCC: the permission is asked for again,
and System Settings then lists two identical "Pawshot" entries — switching on the stale one does
nothing. Remove both with "−" and grant it afresh. The permission window offers Relaunch even
while it still reads "not allowed", because a running process may never see the grant.

The certificates on a machine: `security find-identity -v -p codesigning`; the Team ID is the `OU`
of one: `security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject`.
Switching the owner's local signing or team — only on the owner's direct request.

There is no Developer ID and no notarisation. A DMG from GitHub Releases therefore opens only
through Privacy & Security → Open Anyway and an admin password — once; the updates after it come
through Sparkle (below).

### Updates: Sparkle and GitHub Releases

Why it exists: a DMG handed over by hand arrives quarantined, and every new build asked for Open
Anyway and the password again. Sparkle downloads the update itself, strips the quarantine and
swaps the bundle, so Gatekeeper never looks — and since the certificate stays the same, Screen
Recording survives. The owner's call on 2026-09-28: free now, Developer ID maybe later (Sparkle
stays when it comes).

- **The feed is `releases/latest/download/appcast.xml`** — GitHub redirects it to the latest
  release's asset, so there is no separate hosting. A pre-release is not "latest": `make publish`
  never marks one, and a release marked so by hand is invisible to every copy.
- **The build number is the version** (`CURRENT_PROJECT_VERSION = $(MARKETING_VERSION)`). Sparkle
  compares `CFBundleVersion`; it used to be a constant `1`, under which no build is ever newer.
- **The EdDSA private key lives in the owner's login Keychain**, the public half is
  `SUPublicEDKey`. `generate_appcast` signs with it (macOS asks for Keychain access the first
  time). Lose it and every installed copy refuses all updates — the backup, `generate_keys -x`,
  is kept with the signing `.p12`.
- **Releasing:** raise `MARKETING_VERSION`, write its "What's New" (next point), commit, push,
  `make release publish`. The tag goes on the remote's default branch, so push first, or the tag
  lands on the previous commit.
- **Every raised version gets its "What's New" entry — the agent writes it, in the same change
  as the raise.** In `App/WhatsNew.swift` a new `Entry` goes on top of `history` with the new
  `MARKETING_VERSION` and its text in English, and its Russian goes into `Localizable.xcstrings`.
  Older entries stay, with their translations: someone skipping versions reads them all. It is written for the
  person who just updated, not for the log: what they can do now, or what stopped getting in
  their way — a few short paragraphs, the names exactly as on screen (Settings → General →
  Diagnostics / Настройки → Основные → Диагностика), no class names, no measurements, no
  "refactored". Only what changed since the last released version. A release with nothing a
  person would notice gets an empty text, and then no window. `WhatsNewTests` stays red until
  the top entry's `version` matches the bundle's — that is the reminder.
- **Sparkle's tools** (`generate_keys`, `generate_appcast`) come with the package under
  `Tuist/.build/…/Sparkle/bin/`; the Makefile finds them rather than naming the path, which moved
  between SwiftPM versions.
- **Not under tests:** the test host is the app, so `Updater.start()` is skipped there, as
  `replaceOlderInstances()` is (`AppDelegate.isTestHost`).
- **Self-built copies read the owner's feed too** — the key and the URL are in `Project.swift`.
  An update then replaces a self-built copy with the owner's build and its certificate, so Screen
  Recording is asked for again once.
- The helpers inside `Sparkle.framework` (`Autoupdate`, `Updater.app`) come out ad-hoc signed in
  the built bundle while the app is `Pawshot Self-Signed`; `codesign --verify --deep --strict`
  passes. Whether an update installs through them no test can show — only a real update
  (0.4.4 → 0.4.5 is the first one to prove it).

App Sandbox is off and there is no entitlements file — deliberately, so screenshot files can be
written freely later. Once a sandbox appears, questions about folder access appear with it.

### Swift 6

`defaultSwiftVersion: "6.0"` in `Tuist.swift`, i.e. strict concurrency is on. AppKit is almost
entirely `@MainActor`, so the UI layer's classes are isolated to the main actor; in tests, methods
that touch the UI are marked `@MainActor`.
