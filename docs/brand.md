# AgentMenu brand

Small app, small brand: one mark, one accent, one type stack. Everything here
is rendered from code or drawn with system primitives — there is no asset
pipeline and no Xcode asset catalogue.

## The mark

A prompt caret, a command line under it, and a dot.

```
>_ ·
```

It says what the app does in three strokes: a shell command is about to run, and
it carries a setting the user chose. The dot is the preset — the thing that
makes this a launcher rather than a terminal opener.

- `assets/brand/icon.svg` and `assets/brand/mark.svg` are the readable copies.
- `packaging/icon/make-icons.swift` is the **source of truth** and renders both:
  `make icons` writes `dist/icon/AgentMenu.icns` plus the menu-bar template at
  1x/2x/3x. SVG rasterisers available without extra tooling silently drop
  gradients and strokes, so the shapes are drawn in CoreGraphics instead.
- The app icon body is a **superellipse**, not a circular-cornered rectangle —
  at 1024px the difference between the two is visible against every other icon
  in the Dock.
- The menu-bar image is a **template**: alpha only. macOS tints it for the light
  menu bar, the dark menu bar and the highlighted state, so any colour baked in
  would be discarded.

## Colour

| Role | Light | Dark |
|---|---|---|
| Accent (Launch, usage bars, the mark) | `#D6336C` | `#FF6B9D` |
| Icon gradient | `#FF7EB6` → `#D6336C` → `#5E102E` | same |
| Bypass warning (R37) | `#A15C07` | `#F5B301` |

Rose, not blue. A launcher's primary action should read as this app's own rather
than as the system's, and in a menu bar full of monochrome glyphs and blue
system chrome, this one is findable.

The bypass warning moved with it. Against a teal accent an orange amber was
clearly separate; against rose it is a hue away, and this is the one marking in
the app that has to be unmistakable — it says a click will start an agent that
never asks. So it is pushed towards yellow (`#A15C07` / `#F5B301`), which
separates cleanly from both the accent and the error red macOS uses.

**Standard controls keep the user's system accent.** Only AgentMenu's own chrome
— the mark, the primary Launch button, the usage bars — uses the brand accent. A
checkbox that ignores the accent colour a user chose in System Settings looks
broken, not branded.

Everything else is system colour: `NSColor.labelColor`, `secondaryLabelColor`,
`separatorColor`, the popover's own material. That is what makes the app look
native in both appearances without maintaining two palettes.

## Type

The system stack, at system sizes: SF Pro Text via `-apple-system`. 13px body,
11px secondary, 590 weight where a label needs to carry. No webfont, no custom
face — a 340pt popover is the wrong place to introduce one, and SF is what every
other menu-bar item is set in.

## Where the personality lives

The popover is AgentMenu's own surface: the mark, the accent, the cards, the
rate-limit bars. The **settings window is deliberately plain** — a grouped
`Form`, a `Table`, standard `Picker`s and buttons, laid out the way macOS lays
out settings. A settings window that expresses a brand is a settings window
people have to learn.
