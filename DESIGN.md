# Slate design spec

The source of truth for how Slate looks, for anyone updating graphics or
building the website. Every value here is taken from the Swift on the branch.
The preview page renders all of it at actual size:
https://claude.ai/code/artifact/34f592d8-22d0-4385-84a1-7b196b1cd178

## Principles

1. **One accent.** Emerald means "live" or "done". Nothing else is coloured.
2. **The island is the notch, grown.** Deep black, never decorated, never a card.
3. **Everything else is glass.** Adaptive light or dark with the system.
4. **Ink is the signal.** Three inks in the transcript; no highlights, no pulses
   beyond the live dot.
5. **Plain words.** Sentence case, no exclamation marks, no emoji in the UI.

## Colour

| Token | Value | Used for |
| --- | --- | --- |
| Emerald | `#00BF63` | The accent: waveform, live dot, badges, buttons, the island's bottom hairline, glow |
| Mint | `#34D399` | End of the accent gradient; words Parakeet just corrected |
| Lime | `#C1FF72` | App icon only. Not used in the UI |
| Coral | `#F0592B` | Errors and the Recovered badge only |
| Island black | `#000000` | The island. Same black as the notch |
| Island ink | `#FFFFFF` at 100 / 62 / 45 % | Settled words and labels / secondary text and hints / words just heard |
| Light ground | `#F3F6F4` | Page ground (a green-biased off-white) |
| Light ink | `#101815`, soft `#5B6A62`, faint `#8E9B94` | Text on light |
| Dark ground | `#0F1412` | Page ground in dark mode |
| Dark ink | `#EAF0EC`, soft `#9AA89F`, faint `#6E7C74` | Text on dark |
| Hairline | ink at 9 % | Dividers and card edges |

Accent gradient: emerald → mint, top to bottom.

## Type

System faces only. SF Rounded for labels and controls, SF Pro for running text.

| Role | Face | Size / weight |
| --- | --- | --- |
| Hint | SF Rounded | 10 medium |
| Keycap | SF Rounded | 10 semibold |
| Badge, pill button | SF Rounded | 11 semibold |
| Island label | SF Rounded | 12 semibold |
| Menu item, search field | SF Rounded | 13 regular |
| Card headline | SF Rounded | 14 bold |
| Window title | SF Rounded | 24 bold |
| Transcript | SF Pro | 15 regular, line height 1.35 |
| History row text | SF Pro | 13 regular, line height 1.45 |

Web stacks: `ui-rounded, "SF Pro Rounded", -apple-system, BlinkMacSystemFont,
"Helvetica Neue", sans-serif` for UI; `-apple-system, BlinkMacSystemFont,
"SF Pro Text", "Helvetica Neue", sans-serif` for body. Keep running text
near 65 characters wide.

## The island

**Where it lives.** On a notched Mac the island's window starts at the very
top of the screen, centred on the notch, over the notch and the menu bar
beside it. On any other screen it hangs from the bottom of the menu bar.

**Notch numbers.** 14-inch MacBook Pro: 185 × 32 pt. The app reads the real
values from `NSScreen` (auxiliary top areas for width, top safe-area inset for
height) and adds 4 pt of overlap so no sliver of menu bar shows at the seam.
The ratio is about 12 % of screen width on every notched model.

**Silhouette.** Concave flares at the top corners where it meets the top of
the screen, radius 10 pt, drawn as quadratic corners (the same construction
notch apps use). Round bottom corners, radius 22 pt. Square top corners on
screens without a notch.

**Size.** The body is never narrower than the notch. Padding 18 pt each side,
notch height + 8 pt on top, 14 pt on the bottom. The transcript column is
400 pt wide; the island widens to fit it. Outside the shape, 28 pt of room
each side and 30 pt below for the shadow.

**Fill and edge.** Solid black. A 1 pt hairline that is invisible at the top,
white at 10 % down the sides, and emerald at 45 % along the bottom. Shadow:
black 45 %, blur 18, offset 10 down. Glow: emerald 28 %, blur 26, offset 4.

**Header row** (10 pt gaps): waveform, then either the live dot and a label or
nothing, then the hints.

- Waveform: 44 × 22 pt, 7 capsules 3.5 pt wide with 3 pt gaps, emerald → mint
  gradient, emerald glow at 35 %. Bar heights follow the mic level with a
  centre-weighted falloff. Ease-out, 160 ms.
- Live dot: 7 pt emerald circle, 900 ms ease-in-out pulse (scale 0.82 → 1,
  glow 30 % → 90 %).
- Keycap: 10 semibold at white 78 %, padding 2 × 5, radius 5, fill white 10 %,
  edge emerald 35 %.

**Transcript.** Paragraphs 6 pt apart. Only the last two are shown; a paragraph
longer than 220 characters is trimmed from the front with an ellipsis so the
newest words are always on screen. Three inks:

| Ink | Meaning |
| --- | --- |
| White 100 % | Held steady since the last pass |
| Mint | Parakeet just changed its mind: these replaced words already on screen |
| White 45 % | Only just heard |

**States and strings.**

| State | Leading element | Text | Hint | Stays for |
| --- | --- | --- | --- | --- |
| Listening (no words yet) | Waveform + live dot | "Listening" | Hold mode: "release to place" + `esc`. Tap mode: `⌥` "to place" + `esc` | While listening |
| Listening (model loading) | Waveform + live dot | "Getting the speech model ready" | Same | Until ready |
| Listening (words) | Waveform | Transcript below | Same | While listening |
| Placing | Small spinner | "Placing your words" | | Usually under 0.1 s |
| Placed | Emerald `checkmark.circle.fill` | "Placed in {App}" | | 1.2 s |
| Copied | `⌘V` keycap | "Copied. Paste anywhere." | | 3.2 s |
| Cancelled | White 62 % `xmark.circle.fill` | "Cancelled. Kept in History." or "Cancelled" | | 1.5 s / 0.7 s |
| Error | Coral `exclamationmark.triangle.fill` | The error, two lines max | | 2.5 s |

## Glass surfaces

Used by the welcome card and the History window. Not by the island.

- Blur: the system's behind-window blur. Card material `popover`, window
  material `sidebar`. Corners are masked in the blur itself, because a
  behind-window blur ignores layer masks.
- Sheen: white 42 % → 10 % top to bottom (dark mode 12 % → 2 %).
- Cast: emerald 16 % from the top-leading corner to nothing (dark 20 %).
- Light catch: white 55 % radial near the top-left, radius 170 (dark 18 %).
- Thickness: black 7 % over the bottom third (dark 22 %).
- Edge, 1 pt: white 95 % → 40 % → emerald 35 % (dark 40 % → 10 % → emerald 45 %).
- Specular: a 1 pt line just inside the top edge, white 70 % fading out by
  40 % of the height (dark 30 %).
- Shadow: black 22 % blur 18 offset 10 (dark 55 %). Glow: emerald 20 % blur 26
  offset 4 (dark 26 %).

**Welcome card.** Radius 20. 38 pt emerald-gradient tile with a white SF
Symbol (`hand.raised.fill` while Accessibility is needed, `waveform` once
ready), 14 bold headline, 12 regular detail in soft ink, an emerald pill
button. Sits 12 pt below the menu bar, centred. Text column 290 pt.

**History window.** 540 × 640 default, 440 × 380 minimum, transparent title
bar, glass background. Title "History" 24 bold with a quiet "Clear all" pill;
one-line subtitle; a capsule search field. Rows are cards: radius 14, fill ink
4.5 %, edge ink 7 %, padding 14. Row anatomy: outcome badge, relative time,
word count, an emerald "Copy" pill (turns to a "Copied" state for 1.4 s), a
trash icon; then the text, four lines with "Show more".

Badges (11 semibold, capsule, tint at 12 %): Placed in {App} emerald with
`checkmark.circle.fill`; Copied to clipboard soft ink with
`doc.on.clipboard.fill`; Recovered coral with `lifepreserver.fill`.

Pill buttons (11 semibold, capsule, padding 5 × 11): accent = emerald fill,
white text; quiet = ink 6 % fill, soft ink text; done = emerald 14 % fill,
emerald text.

## Menu bar

Template icon: five bars. Native menu. Structure, top to bottom:

1. Status line (disabled text): "Ready. Hold Right Option to talk." /
   "Ready. Tap Right Option to talk, tap again to place." / "Getting the
   speech model ready…" / "Downloading the speech model (first run only)…" /
   "Turn on Accessibility to use the talk key"
2. Divider
3. Radio pair: "Hold to talk, release to place" / "Tap to start, tap to stop"
4. Divider
5. **Recent ›** submenu: "Click one to copy it", divider, the last five, newest
   first, first line only, 64 characters max
6. **History…** ⌘H (opens the window)
7. Divider
8. **Settings ›** submenu: "Space after each dictation", "New paragraph when you
   pause", "Pause music while talking", divider, "Launch at login"
9. Divider
10. "Show me how Slate works", "Open Accessibility settings"
11. Divider
12. "Quit Slate" ⌘Q

Recent and History are deliberately two separate items.

## Motion

| What | Timing |
| --- | --- |
| Waveform bars | ease-out 160 ms on each level change |
| Live dot | 900 ms ease-in-out, repeating, alternating |
| Transcript growth | ease-out 180 ms |
| Copy pill → Copied | 150 ms in, 200 ms out after 1.4 s |
| Show more | 200 ms ease-out |
| Everything else | No animation. Respect reduced motion |

## Icons

SF Symbols only: `waveform`, `hand.raised.fill`, `checkmark.circle.fill`,
`xmark.circle.fill`, `exclamationmark.triangle.fill`, `magnifyingglass`,
`trash`, `lifepreserver.fill`, `doc.on.clipboard.fill` (History badge only).
The island never shows a clipboard icon; the Copied state uses the `⌘V` keycap.

## For the website

- Ground `#F3F6F4` (dark `#0F1412`); text inks as above; emerald as the only
  accent; coral only for errors.
- The hero object is the black island growing out of a notch over a soft
  wallpaper, at actual size. Never show it as a floating card or in glass.
- Cards and panels use the glass recipe. Keep radii at 14 (rows), 20 (cards),
  22 (island bottom).
- Lime is the icon's colour, not a UI colour.
- Copy in sentence case, plain, specific. Say what happens: "Placed in Notes",
  "Copied. Paste anywhere."
