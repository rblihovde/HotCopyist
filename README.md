# CopyWiz ✦

A retro-future clipboard scope for macOS. Always on top, always dark, always watching.

CopyWiz sits in a floating panel above every window and captures **everything** you copy —
not just the text, but every raw representation an app puts on the pasteboard. Click any
past item and your very next **⌘V** pastes it, byte-for-byte identical to the original copy.

```
┌──────────────────────────────────┐
│ ● COPYWIZ · LIVE          ⏸ ⋯   │
│ [ 🔍 search history…          ]  │
│ ┌────┐┌────┐┌────┐┌────┐┌────┐  │
│ │¹ ≡ ││² 🖼 ││³ ⟨⟩││ 4  ││ 5  │  │
│ └────┘└────┘└────┘└────┘└────┘  │
│ ──────────────────────────────── │
│ PINNED ────────────────────────  │
│ 📌 meeting notes template        │
│ HISTORY ───────────────────────  │
│ ⟨com.makemusic.notation⟩         │
│    FINALE · 2 MIN AGO · 4 TYPES  │
│ Hello from Safari                │
│    SAFARI · 5 MIN AGO · 2 TYPES  │
│ 🖼  Image · 640×480              │
│    PREVIEW · 12 MIN AGO          │
│ ──────────────────────────────── │
│ 42 ITEMS · CAPTURING   ⌃⌘V      │
└──────────────────────────────────┘
```

## Features

- **Always-on-top panel** — floats above every app on every Space, and it's
  *non-activating*: clicking it never steals focus from the app you're working in.
- **Full-fidelity capture** — stores every pasteboard representation (plain text, RTF,
  HTML, images, file URLs, *and* app-private binary payloads). Re-copying restores all
  of them, so pasting back into the source app works exactly like the original copy.
- **Click → ⌘V** — click an item and it's "on deck": your next ⌘V pastes it.
  **⌘-click** (or ⌘-Return) pastes it immediately into the frontmost app.
- **5 Hot Slots** — a strip of always-ready sockets at the top of the panel. Save
  anything to a slot (right-click a history item, or click an empty slot to capture
  your latest copy) and it stays there until you replace it — surviving restarts and
  history clears. Click a slot to arm it, ⌘-click to paste it, or hit **⌃⌘1–⌃⌘5
  from any app** to fire a slot without even opening the panel.
- **Payload Inspector** — the "behind the hood" view. See every type identifier on an
  item, decoded as text, XML-ified binary plist, or image where possible — hex + ASCII
  dump otherwise. Export any representation as a raw `.bin` file.
- **Search** — by content, source app, or type identifier (try searching `finale`).
- **Pins** — keep favorites above the fray, immune to history clearing.
- **Retro-future-minimal, permanently dark** — phosphor-mint on near-black glass,
  monospaced readouts, hairline rules. CRT soul, Apple manners.
- **Menu bar resident** — no Dock icon, no clutter.

## Keys & clicks

| Action | Gesture |
| --- | --- |
| Toggle panel | **⌃⌘V** (global) or menu bar wand |
| Arm an item for pasting | click it, then ⌘V wherever you are |
| Paste immediately | **⌘-click** an item *(needs Accessibility)* |
| Fire hot slot 1–5 from anywhere | **⌃⌘1 … ⌃⌘5** (global; auto-pastes with Accessibility, otherwise arms for ⌘V) |
| Save to a hot slot | right-click item → *Save to Hot Slot*, or click an empty slot to grab the latest copy |
| Navigate / arm from keyboard | type in search, **↑ ↓** then **Return** (⌘Return pastes) |
| Hide panel | **Esc** |
| Plain-text copy, pin, inspect, delete | right-click an item |

## Building

Requires macOS 14+ and Xcode 15+ command line tools.

```sh
make app        # builds dist/CopyWiz.app
make install    # → /Applications/CopyWiz.app
```

`make run` (`swift run`) works for a quick dev loop, but permission grants are tied to
the binary's path — use the installed .app for daily use.

### Permissions

- **None needed** for the core loop (capture, history, click-to-arm, ⌘V yourself).
- **Accessibility** (System Settings → Privacy & Security → Accessibility) is only
  needed for the optional *paste immediately* feature, which synthesizes a ⌘V keystroke.
  CopyWiz will prompt the first time you ⌘-click an item.

## Peeking behind the hood (the Finale experiment)

Curious what actually lands on the clipboard when you copy a measure of music in
Finale — or a layer in Sketch, a region in Logic, a slide in Keynote?

1. Copy the thing in the source app.
2. It appears in CopyWiz as an amber `⟨com.vendor.something⟩` entry if it has no
   text/image form (or as a normal entry with extra hidden types if it does).
3. Right-click → **Inspect Payload**.
4. The chip row shows *every* type identifier the app published — apps typically
   publish several representations of the same copy, from private binary formats
   down to plain text.
5. Click through the chips. **AUTO** decodes what it can (UTF-8 text, XML, binary
   plists → readable XML, images); **HEX** shows the honest bytes with an ASCII
   column; **TEXT** forces a UTF-8 reading.
6. **EXPORT .BIN** saves the raw bytes for deeper spelunking (`xxd`, a hex editor,
   or a Python script).

Nothing about this is music-specific — CopyWiz is a general-purpose tool. Exotic
payloads just get the amber treatment so you know something interesting is inside.

## Storage

History (up to 300 unpinned items, plus all pins) and hot slots persist across
launches in `~/Library/Application Support/CopyWiz/`. Individual representations
larger than 8 MB are skipped to keep the app light. Everything stays on your Mac —
CopyWiz has no network code at all.

## License

MIT — see [LICENSE](LICENSE).
