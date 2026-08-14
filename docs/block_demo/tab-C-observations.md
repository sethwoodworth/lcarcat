# Tab C observations — C-cmd-in-header

> Expected geometry: [docs/block_demo/spec.md#tab-c--c-cmd-in-header](spec.md#tab-c--c-cmd-in-header)

## Observed (2026-08-13, corrected grid)

Grid: 181 cols × 57 rows.

- **Block 1**: header rows 1–3. Content row 4. Footer rows 5–6.
- **Block 2**: header rows 8–10. Content row 11. Footer rows 12–13.
- **Block 3**: header rows 15–17. Content rows 18–21. Footer rows 22–23.
- Chips and command text coexist on h0+2: chips (`main`, `~`, `AWS`) on left, then cmd text (`ls -la /etc/hosts`, `echo $PATH`, `git status`) in a visually distinct highlight.
- The cmd text region is notably darker/different from the periwinkle bar — the black notch (LcarsBlockCmd highlight) is visually present and creates a clear inset against the bar.
- Left elbow at cols 0–4. Structure otherwise identical to Tab A.
- Footer bars and right vcap present.

## Known open issues

- Same chip gap / bar_w / right cap issues as Tab A.
- Notch width correctness (whether the bar highlight correctly stops and restarts around the cmd text) not verifiable from screenshot alone.

## User feedback

_(to be filled in)_

## Fix instructions

_(to be filled in after user feedback)_
