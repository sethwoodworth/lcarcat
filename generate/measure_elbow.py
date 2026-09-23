#!/usr/bin/env python3
"""Measure the corner radii of an LCARS elbow in a reference photograph.

This is the tool behind the numbers in `docs/lcars-design.md`; the method, and
the traps that voided three earlier attempts, are written up in
`docs/elbow-measurement.md`. Read that before trusting anything this prints.

It measures ONE elbow that YOU have already cropped. It does not find elbows --
every attempt at that produced confident wrong numbers -- so the input is a hand
made crop holding a single corner, like the ones in `references/elbows/`.

    uv run --with pillow --with numpy --with scipy --with scikit-image \\
        generate/measure_elbow.py references/elbows/voyager-elbow-1.jpg \\
        --transform flip_vertical --overlay /tmp/check.png

``--transform`` turns the crop into the canonical TOP-LEFT elbow: horizontal arm
along the top running right, vertical arm down the left, outer corner top-left.
Pick the one that gets you there:

    identity          already a top-left elbow
    rotate180         a bottom-right elbow
    flip_vertical     a bottom-left elbow
    flip_horizontal   a top-right elbow

ALWAYS pass ``--overlay`` and look at it. The fitted corners are drawn on the
image; a number whose overlay you have not seen is a number you have not
checked.
"""
from __future__ import annotations

import argparse
import json
import math
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage, optimize
from skimage import measure

TRANSFORMS = {
    "identity": lambda a: a,
    "rotate180": lambda a: a[::-1, ::-1],
    "flip_vertical": lambda a: a[::-1, :],
    "flip_horizontal": lambda a: a[:, ::-1],
}

#: How far a straight edge may drift before the run is deemed to have reached
#: the fillet. Sub-pixel, because the edges themselves are measured sub-pixel.
EDGE_TOLERANCE = 0.75


def load(path: str, transform: str, color: Optional[Sequence[int]] = None,
         color_tolerance: float = 90.0,
         box: Optional[Sequence[int]] = None) -> Tuple[np.ndarray, np.ndarray]:
    """Return (normalised intensity, mask of the elbow's own region).

    Intensity is normalised so the elbow is 1 and its surroundings 0, which is
    what lets edges be read at the 0.5 crossing rather than at a hard threshold.
    A hard threshold quantises the very curvature being measured.
    """
    rgb = np.asarray(Image.open(path).convert("RGB")).astype(float)
    if box is not None:
        left, top, right, bottom = box
        rgb = rgb[top:bottom, left:right]
    rgb = TRANSFORMS[transform](rgb)

    if color is None:
        signal = rgb.max(axis=2)
    else:
        distance = np.sqrt(((rgb - np.array(color, float)) ** 2).sum(axis=2))
        signal = np.clip(255 - distance * 255 / color_tolerance, 0, 255)

    rough = signal > 0.5 * signal.max()
    labels, count = ndimage.label(rough)
    if count == 0:
        raise SystemExit("no shape found: check --color, or the crop")
    sizes = ndimage.sum(rough, labels, range(1, count + 1))
    component = labels == 1 + int(np.argmax(sizes))

    near = ndimage.binary_dilation(component, iterations=3)
    core = ndimage.binary_erosion(component, iterations=2)
    far = ~ndimage.binary_dilation(component, iterations=4)
    foreground = np.median(signal[core]) if core.any() else signal.max()
    background = np.median(signal[far]) if far.any() else 0.0
    level = (signal - background) / max(1e-6, foreground - background)
    return np.clip(np.where(near, level, 0.0), 0, 1.2), component


def crossings(profile: np.ndarray) -> Tuple[List[float], List[float]]:
    """Sub-pixel positions where the profile crosses 0.5, (rising, falling)."""
    rising: List[float] = []
    falling: List[float] = []
    for index in range(len(profile) - 1):
        first, second = profile[index], profile[index + 1]
        if (first - 0.5) * (second - 0.5) < 0:
            position = index + (0.5 - first) / (second - first)
            (rising if second > first else falling).append(position)
    return rising, falling


def stable_run(values: Sequence[float], tolerance: float = EDGE_TOLERANCE,
               minimum: int = 3) -> List[float]:
    """Values from the far end inward, while they stay put.

    The run stops at the first value that drifts, and THAT is where the fillet
    begins. Averaging a fixed fraction of the arm instead puts the fillet in the
    average and the edge spread jumps by an order of magnitude.
    """
    run: List[float] = []
    for value in values:
        if len(run) >= minimum and abs(value - float(np.median(run))) > tolerance:
            break
        run.append(value)
    return run


def edges(level: np.ndarray, component: np.ndarray) -> Dict[str, float]:
    """The four straight edges, each from the stable run at its own far end."""
    ys, xs = np.nonzero(component)
    tops: List[float] = []
    bottoms: List[float] = []
    for x in range(int(xs.max()) - 2, int(xs.min()), -1):
        rising, falling = crossings(level[:, x])
        if not (rising and falling):
            break
        tops.append(rising[0])
        bottoms.append(falling[0])
    lefts: List[float] = []
    rights: List[float] = []
    for y in range(int(ys.max()) - 2, int(ys.min()), -1):
        rising, falling = crossings(level[y, :])
        if not (rising and falling):
            break
        lefts.append(rising[0])
        rights.append(falling[0])

    tops, bottoms = stable_run(tops), stable_run(bottoms)
    lefts, rights = stable_run(lefts), stable_run(rights)
    if not (tops and bottoms and lefts and rights):
        raise SystemExit("could not find four straight edges: is this one elbow?")
    return {
        "bar_top": float(np.median(tops)),
        "bar_bottom": float(np.median(bottoms)),
        "stem_left": float(np.median(lefts)),
        "stem_right": float(np.median(rights)),
        "bar_columns": float(min(len(tops), len(bottoms))),
        "stem_rows": float(min(len(lefts), len(rights))),
        "bar_spread": float(max(np.ptp(tops), np.ptp(bottoms))),
        "stem_spread": float(max(np.ptp(lefts), np.ptp(rights))),
    }


def contour(level: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    points = np.concatenate(measure.find_contours(level, 0.5))
    return points[:, 1], points[:, 0]


def tangent_circle(x, y, corner_x: float, corner_y: float, max_radius: float) -> Dict[str, float]:
    """Circle tangent to both edges, so only the radius is free.

    One free parameter is the point: an unconstrained fit can wander off and
    find a plausible circle somewhere that is not this corner.
    """
    def rms_for(radius: float) -> Tuple[float, int]:
        cx, cy = corner_x + radius, corner_y + radius
        inside = ((x >= corner_x - 0.5) & (x <= cx) & (y >= corner_y - 0.5) & (y <= cy))
        if inside.sum() < 8:
            return math.inf, 0
        residual = np.hypot(x[inside] - cx, y[inside] - cy) - radius
        return float(np.sqrt(np.mean(residual ** 2))), int(inside.sum())

    best = (math.inf, 1.0, 0)
    for radius in np.arange(1.0, max_radius, 0.25):
        rms, count = rms_for(float(radius))
        score = rms / radius
        if score < best[0]:
            best = (score, float(radius), count)
    refined = optimize.minimize_scalar(
        lambda r: rms_for(float(r))[0] / r,
        bounds=(max(1.0, best[1] - 1), best[1] + 1), method="bounded")
    radius = float(refined.x)
    rms, count = rms_for(radius)
    return {"radius": radius, "rms": rms, "points": count}


def free_circle(x, y, cx: float, cy: float, radius: float) -> Optional[Dict[str, float]]:
    """Unconstrained fit over the middle of the arc, as a cross-check."""
    angle = np.degrees(np.arctan2(-(y - cy), -(x - cx)))
    distance = np.hypot(x - cx, y - cy)
    use = (angle > 20) & (angle < 70) & (np.abs(distance - radius) < max(2.0, 0.25 * radius))
    if use.sum() < 6:
        return None
    px, py = x[use], y[use]
    fit = optimize.least_squares(
        lambda p: np.hypot(px - p[0], py - p[1]) - p[2], [cx, cy, radius])
    return {"radius": float(fit.x[2]),
            "rms": float(np.sqrt(np.mean(fit.fun ** 2))),
            "centre_offset": float(math.hypot(fit.x[0] - cx, fit.x[1] - cy)),
            "points": int(use.sum())}


def tangent_ellipse(x, y, corner_x: float, corner_y: float,
                    max_radius: float) -> Dict[str, float]:
    """Axis-aligned quarter ellipse tangent to both edges.

    Worth fitting because one canon elbow is not circular: msd-1's outer corner
    is an ellipse at about 1.5 : 1 along the bar, which is only visible as a
    disagreement between this and the circle.
    """
    def rms_for(a: float, b: float) -> Tuple[float, int]:
        if a <= 0 or b <= 0:
            return math.inf, 0
        cx, cy = corner_x + a, corner_y + b
        inside = ((x >= corner_x - 0.5) & (x <= cx) & (y >= corner_y - 0.5) & (y <= cy))
        if inside.sum() < 8:
            return math.inf, 0
        ray = np.hypot(x[inside] - cx, y[inside] - cy)
        rho = np.hypot((x[inside] - cx) / a, (y[inside] - cy) / b)
        return float(np.sqrt(np.mean((ray - ray / rho) ** 2))), int(inside.sum())

    best = (math.inf, 2.0, 2.0)
    for a in np.arange(2.0, max_radius, 1.0):
        for b in np.arange(2.0, max_radius, 1.0):
            rms, _ = rms_for(float(a), float(b))
            score = rms / min(a, b)
            if score < best[0]:
                best = (score, float(a), float(b))
    refined = optimize.minimize(
        lambda p: rms_for(float(p[0]), float(p[1]))[0] / max(1e-6, min(p)),
        [best[1], best[2]], method="Nelder-Mead",
        options=dict(xatol=0.05, fatol=1e-6))
    a, b = (float(v) for v in refined.x)
    rms, count = rms_for(a, b)
    return {"horizontal": a, "vertical": b, "rms": rms, "points": count}


def measure_elbow(path: str, transform: str, color=None, box=None) -> Dict:
    level, component = load(path, transform, color, box=box)
    edge = edges(level, component)
    bar = edge["bar_bottom"] - edge["bar_top"]
    stem = edge["stem_right"] - edge["stem_left"]
    x, y = contour(level)
    height, width = level.shape
    limit = float(min(height, width))

    outer = tangent_circle(x, y, edge["stem_left"], edge["bar_top"], limit)
    inner = tangent_circle(x, y, edge["stem_right"], edge["bar_bottom"], limit)
    outer_centre = (edge["stem_left"] + outer["radius"], edge["bar_top"] + outer["radius"])
    inner_centre = (edge["stem_right"] + inner["radius"], edge["bar_bottom"] + inner["radius"])

    thin, thick = min(bar, stem), max(bar, stem)
    return {
        "file": path,
        "transform": transform,
        "arms": {"bar": bar, "stem": stem, "thin": thin, "thick": thick,
                 "thick_over_thin": thick / thin},
        "edges": edge,
        "outer": outer,
        "outer_free": free_circle(x, y, *outer_centre, outer["radius"]),
        "outer_ellipse": tangent_ellipse(x, y, edge["stem_left"], edge["bar_top"], limit),
        "inner": inner,
        "inner_free": free_circle(x, y, *inner_centre, inner["radius"]),
        "ratios": {
            "outer_over_thin": outer["radius"] / thin,
            "outer_over_thick": outer["radius"] / thick,
            "inner_over_thin": inner["radius"] / thin,
            "inner_over_outer": inner["radius"] / outer["radius"],
        },
        "centres": {"outer": outer_centre, "inner": inner_centre},
    }


def draw_overlay(result: Dict, out: str, scale: Optional[int] = None) -> None:
    """The fit, drawn on the crop. Look at this before believing the numbers."""
    rgb = np.asarray(Image.open(result["file"]).convert("RGB"))
    rgb = TRANSFORMS[result["transform"]](rgb)
    image = Image.fromarray(np.ascontiguousarray(rgb))
    scale = scale or max(1, int(round(900 / max(image.size))))
    image = image.resize((image.width * scale, image.height * scale), Image.NEAREST)
    draw = ImageDraw.Draw(image)
    edge = result["edges"]
    at = lambda v: v * scale

    for value in (edge["bar_top"], edge["bar_bottom"]):
        draw.line([(0, at(value)), (image.width, at(value))], fill=(0, 229, 255), width=2)
    for value in (edge["stem_left"], edge["stem_right"]):
        draw.line([(at(value), 0), (at(value), image.height)], fill=(255, 214, 0), width=2)

    ellipse = result["outer_ellipse"]
    a, b = ellipse["horizontal"], ellipse["vertical"]
    cx, cy = edge["stem_left"] + a, edge["bar_top"] + b
    draw.ellipse([at(cx - a), at(cy - b), at(cx + a), at(cy + b)],
                 outline=(118, 255, 3), width=2)
    for key in ("outer", "inner"):
        cx, cy = result["centres"][key]
        radius = result[key]["radius"]
        draw.ellipse([at(cx - radius), at(cy - radius), at(cx + radius), at(cy + radius)],
                     outline=(255, 45, 85), width=3)
        draw.ellipse([at(cx) - 5, at(cy) - 5, at(cx) + 5, at(cy) + 5], fill=(255, 45, 85))
    image.save(out)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("image", help="a crop holding ONE elbow")
    parser.add_argument("--transform", default="identity", choices=sorted(TRANSFORMS),
                        help="how to turn the crop into a top-left elbow")
    parser.add_argument("--color", default=None,
                        help="RRGGBB of the elbow, when the crop holds more than one shape")
    parser.add_argument("--box", default=None, metavar="L,T,R,B",
                        help="crop the image further before measuring")
    parser.add_argument("--overlay", default=None, metavar="PATH",
                        help="write the fit drawn over the crop -- always use this")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    arguments = parser.parse_args()

    color = None
    if arguments.color:
        value = arguments.color.lstrip("#")
        color = [int(value[i:i + 2], 16) for i in (0, 2, 4)]
    box = [int(v) for v in arguments.box.split(",")] if arguments.box else None

    result = measure_elbow(arguments.image, arguments.transform, color, box)
    if arguments.overlay:
        draw_overlay(result, arguments.overlay)

    if arguments.json:
        print(json.dumps(result, indent=1, default=float))
        return 0

    arms, ratios = result["arms"], result["ratios"]
    print("%s  (%s)" % (result["file"], result["transform"]))
    print("  arms        thick %.1f  thin %.1f  (%.2f : 1)"
          % (arms["thick"], arms["thin"], arms["thick_over_thin"]))
    print("  edges       measured over %d bar columns, %d stem rows; spread %.1f / %.1f px"
          % (result["edges"]["bar_columns"], result["edges"]["stem_rows"],
             result["edges"]["bar_spread"], result["edges"]["stem_spread"]))
    print("  outer       %.1f px   rms %.2f" % (result["outer"]["radius"], result["outer"]["rms"]))
    if result["outer_free"]:
        print("    free      %.1f px   rms %.2f   centre off by %.1f px"
              % (result["outer_free"]["radius"], result["outer_free"]["rms"],
                 result["outer_free"]["centre_offset"]))
    print("    ellipse   %.1f x %.1f  (%.2f : 1)  rms %.2f"
          % (result["outer_ellipse"]["horizontal"], result["outer_ellipse"]["vertical"],
             result["outer_ellipse"]["horizontal"] / result["outer_ellipse"]["vertical"],
             result["outer_ellipse"]["rms"]))
    print("  inner       %.1f px   rms %.2f" % (result["inner"]["radius"], result["inner"]["rms"]))
    if result["inner_free"]:
        print("    free      %.1f px   rms %.2f   centre off by %.1f px"
              % (result["inner_free"]["radius"], result["inner_free"]["rms"],
                 result["inner_free"]["centre_offset"]))
    print("  ratios      outer/thin %.2f   outer/thick %.2f   inner/thin %.2f   inner/outer %.2f"
          % (ratios["outer_over_thin"], ratios["outer_over_thick"],
             ratios["inner_over_thin"], ratios["inner_over_outer"]))
    print("  NOTE: the fits agreeing is the confidence signal. Look at --overlay.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
