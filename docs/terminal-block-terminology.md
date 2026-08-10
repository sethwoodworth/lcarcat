# Terminal Block Terminology
<!-- Read this doc when: naming shell/terminal concepts (block, frame, stem, rail,
     header, footer, gap, command, output, scrollback), designing or discussing
     the nvim-native terminal frame, writing OSC 133 integration code, or any
     time terminology for "what goes around a command's output" comes up. -->

Canonical terms for shell output structure and LCARS visual chrome.
Use these names consistently across zsh, Lua, docs, and beads issues.

---

## Shell structure (OSC 133 anchors)

The [OSC 133 shell integration spec][osc133] defines four marks per command cycle.
These are the authoritative anchors for block boundaries:

| Mark | Event                                              |
|------|----------------------------------------------------|
| `A`  | Prompt start — PS1 begins rendering                |
| `B`  | Command start — cursor after PS1, user types here  |
| `C`  | Command executed — Enter pressed, output begins    |
| `D`  | Command done — output ends, next prompt cycle      |

---

## Logical units

**block** — one complete A→D cycle: prompt + command + output, treated as an
atomic visual unit. The thing LCARS frames are drawn around. Each block is
independent; stems do not continue across block boundaries.

**live block** — the currently active, unsubmitted block (cursor is between
marks B and C). Everything else is a **history block**.

**prompt** — the rendered PS1 output (the LCARS bar + chips). Covers marks A→B.
The visual header of a block. *Not* the full block — just the decoration rows.

**command** — the text the user submitted. Covers marks B→C. Avoid "input"
(ambiguous with stdin) and "query".

**output** — stdout + stderr from one command execution. Covers marks C→D.
Qualify as "command output" only when disambiguation from nvim output is needed.

**scrollback** — the terminal buffer above the current viewport. Contains
history blocks. The live block always lives in the **viewport**.

**viewport** — the visible terminal rows (not scrollback).

---

## LCARS visual chrome (per block)

**header** — the LCARS swoop bar at the top of a block. Spans marks A→B
visually. Contains the elbow image, chip pills, and path notch. In the
zsh-native design the prompt *is* the header; in the nvim-native design
Lua renders it independently of the shell.

**stem** — the 1-column periwinkle stripe running vertically alongside a
block's output region, from the bottom of the header to the top of the
footer. Scoped to one block — does not continue past the footer into the
gap before the next block.

**footer** — a closing 1-row hcap image at the bottom of a block's output
region, terminating the stem. Symmetric complement to the header cap.
Currently absent from the design; proposed as the natural close of a frame.

**frame** — the full LCARS chrome around one block: header + stem + footer.
The unit being built in the nvim-native terminal work.

**gap** — the empty rows between a block's footer and the next block's
header. No stem, no chrome — black background. Visually separates frames.

---

## Column geometry

**rail** — the vertical screen column (or narrow column band) that stems
occupy across multiple stacked frames. The rail is a spatial concept (a
column position), not a visual element — individual stems occupy it within
their own frame, with gaps between them. Useful when specifying "left rail"
vs "right rail" for stem placement.

---

## Terms to avoid

| Avoid              | Use instead                          |
|--------------------|--------------------------------------|
| "old prompts"      | history blocks                       |
| "chunk"            | block                                |
| "input"            | command (when referring to submitted text) |
| "pre-exec line"    | start-of-output marker (the `[🔵] STARDATE` line) |
| "swoop" (logical)  | header — "swoop" is fine for the PNG asset name |

[osc133]: https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md
