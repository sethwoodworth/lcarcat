# Measuring an elbow from a reference image

How the corner radii in `docs/lcars-design.md` were measured, what went wrong in
the three earlier attempts, and what to repeat if a new reference turns up.
The per-elbow numbers live in `lcarcat-2cc.7`.

The short version: **measurement was never the hard part — detection was, and so
was assuming an arm width instead of measuring it.**

---

## The method that worked

1. **Crop by hand, one elbow per file.** Do not write a detector. Three attempts
   at automatic elbow-finding all produced confident wrong numbers, and the
   third got as far as a plausible-looking median before it turned out to be
   measuring things that were not elbows. `references/elbows/` holds the crops.
2. **Transform to one canonical orientation.** Every elbow becomes a *top-left*
   elbow: horizontal arm along the top running right, vertical arm down the
   left, outer corner top-left, concave inner corner where the two inner edges
   meet. Rotating or mirroring the array first means one set of formulas.
3. **Name the arms by width, never by direction.** Every elbow has a **thick
   arm** and a **thin arm**; which one is horizontal varies between references,
   and ours is the canon proportions turned sideways.
4. **Take each straight edge from the stable run at its far end.** Walk columns
   inward from the end of the bar (rows inward from the end of the stem) and
   stop at the first value that drifts more than ~0.75px from the running
   median. That stopping point *is* where the fillet begins. Sampling "the
   right-most 25% of columns" instead puts the fillet in the average and the
   edge spread jumps to 10-18px.
5. **Fit each corner with a circle constrained to touch both its edges.** That
   leaves one free parameter, so a one-dimensional scan plus a refine is enough,
   and it cannot wander off into a plausible-looking fit somewhere else. Then
   cross-check with (a) a free circle fit over the middle of the arc, and (b) an
   axis-aligned ellipse. Agreement between the three is the confidence signal:
   four of the five elbows agreed within a pixel; msd-1's outer corner did not,
   which is how we learned it is an ellipse at 1.5 : 1.
6. **Draw the fit on the image and look at it.** Every number in the design doc
   came with an overlay -- detected edges in cyan/yellow, fitted corners in red,
   ellipse in lime -- checked before the number was believed.

Sub-pixel edges come from crossing the 0.5 level of a normalised intensity
image, not from a hard threshold; JPEG references are soft, and a hard threshold
quantises the very curvature being measured.

---

## The traps

**Never infer an arm width from the rule you are testing.** This is what voided
the first study. It measured the Voyager elbow's two arcs correctly -- outer
28.5px, inner 14.9px, centre offsets (44, -4.2), all within a pixel of the
remeasurement -- then took the bar thickness *from* the rule under test
(`dx = stem - bar`, so `59 - 44 = 15`), reported `R_outer = 1.78 x W`, and
concluded our elbow was four times too tight. Measured directly, that bar is
9.9px, the real ratio is 2.9x, and our elbow was inside the reference range the
whole time. Measure every quantity that appears in a claim.

**Measure the arm where it makes the turn.** msd-1's bar is 35px along most of
its length and steps down to 27px approaching the corner. The elbow's ratio
belongs to the 27px.

**A crop can be too small to measure an arm.** The Voyager crop shows only ~16px
of bar before its edge. Locate the crop in the full-size source (normalised
cross-correlation finds it exactly) and measure the arm along its whole length
there. One of the four crops matches no image in this repo, so its arms stay
crop-only, and that limit is recorded with the number.

**A subagent reading a shape can be confidently wrong.** The `visual-inspector`
agent called the Voyager crop "a rounded bar end, no inner corner" -- the pixel
data shows a 59px stem running off the top edge and a 10px bar leaving at the
bottom through a small fillet. It also described the zsh prompt's chips as the
contents of the kitty tab bar. Both times the numbers settled it in one command.
Use the subagent for *rendering* questions where pixels are the evidence
(alignment, clipping, colour, "does this read as the same family"), and settle
*structure* questions -- what is in the frame, how wide is this arm, is there a
corner here -- from the array. See also AGENTS.md, "Context discipline".

---

## What the measurements support

Bounds, not a formula. Least squares over the five elbows misses by 45% at best
for the outer radius; the tightest single law is `R_outer ~ sqrt(thin x thick)`,
good to about +-17% once the smallest, lowest-resolution elbow is set aside.
The bounds that held across all five, and the two rules the measurements
disprove, are in `docs/lcars-design.md`, which is also where the settled values
for our own elbow live.

One property is worth keeping as a shape test rather than a ratio: **the turn
never pinches.** The narrowest band of colour across the corner equalled the
thin arm (0.91-1.02x) in every reference. It is a floor a bad corner falls
below, not an equation that pins the inner radius -- the narrowest ray sits at
the edge of the turn, where it simply crosses the thin arm.
