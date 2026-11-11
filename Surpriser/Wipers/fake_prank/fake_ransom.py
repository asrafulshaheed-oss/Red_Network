#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fake_ransom.py - Linux port of fake_ransom.cs

A fake ransomware lock screen.  It is a prank: nothing is encrypted,
nothing is deleted, and the only way out is the passphrase below (or
killing the process / switching to a TTY).

The artwork is drawn with Cairo so it works on any Linux desktop that
has PyGObject and GTK 3 or GTK 4 installed.  GTK 3 is preferred on X11
because only GTK 3 can hold a keyboard grab; otherwise GTK 4 is used.
Set FAKE_RANSOM_GTK=3 or 4 to force a version.

Every active monitor gets its own fullscreen prank window, so a laptop
with an external display or a multi-monitor desktop is covered from edge
to edge.  Only the primary monitor's window accepts keyboard input; the
other windows are display-only and mirror the typed password and the
ACCESS DENIED banner.

While running, only letters, digits, Backspace, Shift and Enter are
accepted.  Everything else is swallowed: Meta/Windows, Ctrl, Alt, Tab,
Esc, Print Screen, Delete, Insert, Home, End, arrows, Page Up/Down,
the function keys, Space, Caps Lock and punctuation.

On X11 the keyboard grab also stops the window manager from acting on
Super and Alt+Tab.  On Wayland the compositor owns those shortcuts and
a normal application cannot suppress them.

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
PLACEHOLDER = "ENTER PASSWORD"
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
        if len(ch) != 1:
            return
        # Match C# char.IsControl(): reject the C0, DEL and C1 control ranges.
        cp = ord(ch)
        if cp < 0x20 or 0x7F <= cp <= 0x9F:
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


def _session_is_x11() -> bool:
    """True when GTK will talk to an X server rather than Wayland."""
    backend = os.environ.get("GDK_BACKEND", "").strip().lower()
    if backend:
        first = next((part.strip() for part in backend.split(",")
                      if part.strip()), "")
        if first:
            return first == "x11"

    session = os.environ.get("XDG_SESSION_TYPE", "").strip().lower()
    if session == "x11":
        return True
    if session == "wayland":
        return False

    # XWayland also sets DISPLAY, so WAYLAND_DISPLAY is the better signal.
    return bool(os.environ.get("DISPLAY")) and not os.environ.get("WAYLAND_DISPLAY")


def load_gtk():
    """Load GTK 4 when possible, otherwise GTK 3.

    On X11 GTK 3 is preferred because it can hold a real keyboard grab,
    which is what stops the window manager from acting on Super, Alt+Tab
    and friends.  GTK 4 removed that API, so it is kept for Wayland.
    """
    try:
        import gi
        forced = os.environ.get("FAKE_RANSOM_GTK", "").strip()
        version = ""
        if forced in ("3", "3.0"):
            version = "3.0"
        elif forced in ("4", "4.0"):
            version = "4.0"
        elif _session_is_x11():
            try:
                gi.require_version("Gtk", "3.0")
                version = "3.0"
            except ValueError:
                gi.require_version("Gtk", "4.0")
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
    # GDI+ PathGradientBrush mixes straight (non-premultiplied) RGBA, while
    # Cairo mixes premultiplied colours.  A single centre/edge stop pair would
    # therefore render a noticeably brighter glow than the C# original, so the
    # straight ramp is pinned down with a list of intermediate stops.
    steps = 12
    for i in range(steps + 1):
        t = i / steps
        pattern.add_color_stop_rgba(
            t,
            center[0] + (edge[0] - center[0]) * t,
            center[1] + (edge[1] - center[1]) * t,
            center[2] + (edge[2] - center[2]) * t,
            center[3] + (edge[3] - center[3]) * t,
        )
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


def socket_bounds(left: bool) -> Rect:
    """GDI+ GraphicsPath.GetBounds() box for CreateSocketPath().

    GDI+ bounds the whole point set, including the Bezier control points, so
    its rectangle is looser than Cairo's tight curve envelope (Cairo reports
    ~142.25, 214.41, 137.75, 83.8).  The C# original feeds these looser
    numbers into the socket glows and flames, so use its exact values instead
    of measuring the path.
    """
    if left:
        return (141.0, 206.0, 139.0, 94.0)
    return (320.0, 206.0, 139.0, 94.0)


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


# The exact point sets are embedded from the C# original so every tongue,
# ember, drip and spark lands in precisely the same place. C#'s System.Random
# and Python's Mersenne Twister draw different sequences from the same seed,
# so the values are copied verbatim instead of re-generated.

MANE_DATA = [
    (105.0, 291.99997, 36.0, 211.23811, 4.918756, -42.500004, 0.9952474),
    (106.1431, 271.45737, 66.0, 209.55298, 0.90141433, -42.157074, 1.0375872),
    (109.559006, 251.15558, 57.0, 269.77036, 5.7432294, -79.1323, 1.0755372),
    (115.20764, 231.33267, 27.0, 264.7939, 0.9794166, -79.43771, 1.0565128),
    (123.0228, 212.22104, 48.0, 295.52957, 0.8885273, -54.093163, 0.88006705),
    (132.91286, 194.04477, 70.0, 220.88664, 1.0026162, -49.126144, 1.0370638),
    (144.76186, 177.01689, 50.0, 269.77887, 1.6306536, -57.571445, 1.0590911),
    (158.43091, 161.33707, 50.0, 290.12546, 0.5755049, -27.47073, 1.0877514),
    (173.75966, 147.18922, 51.0, 318.852, 4.3292375, -58.872105, 1.0034108),
    (190.5685, 134.7391, 63.0, 285.89133, 3.781269, -32.829453, 0.8754472),
    (208.6604, 124.13269, 52.0, 256.1844, 3.024222, -48.40188, 0.9613772),
    (227.82309, 115.494415, 59.0, 210.68083, 3.5708945, -12.653074, 0.9118718),
    (247.832, 108.92549, 43.0, 277.3397, 2.3136554, -7.6504, 0.87229884),
    (268.4525, 104.50296, 45.0, 250.12976, 0.37819508, 4.535754, 0.883054),
    (289.44293, 102.278656, 36.0, 241.03006, 1.2542671, 16.83288, 0.8205902),
    (310.5571, 102.278656, 45.0, 260.03006, 3.055921, 17.16713, 0.99705946),
    (331.54758, 104.502975, 48.0, 282.12976, 6.04142, 29.464273, 0.93918324),
    (352.1681, 108.92552, 47.0, 213.33966, 4.74125, 30.650429, 1.055539),
    (372.177, 115.494446, 64.0, 347.68082, 4.796967, 8.653101, 0.9615329),
    (391.3397, 124.13274, 65.0, 272.18436, 3.155689, 37.40191, 0.9335489),
    (409.43152, 134.73912, 28.0, 224.8913, 2.3663814, 29.829456, 0.8251026),
    (426.24036, 147.18922, 56.0, 215.85199, 3.0109777, 55.87211, 0.87257236),
    (441.56915, 161.33711, 68.0, 275.12546, 5.8808064, 27.470749, 1.059474),
    (455.23816, 177.0169, 47.0, 323.77887, 5.9222684, 56.57145, 0.8702081),
    (467.08716, 194.04477, 54.0, 289.88666, 1.375869, 27.126148, 0.8955079),
    (476.9772, 212.22105, 70.0, 218.52957, 4.3613696, 36.093163, 0.9727285),
    (484.79236, 231.33269, 59.0, 226.79391, 0.50796413, 44.43771, 0.9510162),
    (490.44104, 251.15567, 29.0, 217.77032, 5.92692, 59.132313, 0.9006606),
    (493.8569, 271.45743, 53.0, 194.55295, 3.5615635, 49.157074, 0.89224136),
    (495.0, 292.00003, 55.0, 139.23808, 5.706343, 48.500004, 0.97204214),
    (108.0, 345.0, 28.0, 193.0, 4.7531066, -45.0, 0.9066233),
    (494.0, 359.0, 24.0, 149.0, 1.395969, 38.0, 0.92033696),
    (104.0, 373.0, 38.0, 110.0, 1.1268587, -66.0, 0.9360509),
    (498.0, 387.0, 41.0, 180.0, 0.75576967, 50.0, 0.85517716),
    (100.0, 401.0, 49.0, 186.0, 4.8195605, -57.0, 0.9607097),
    (502.0, 415.0, 31.0, 113.0, 2.9225588, 67.0, 0.8149603),
    (96.0, 429.0, 42.0, 164.0, 1.5088879, -40.0, 0.8900877),
    (506.0, 443.0, 50.0, 123.0, 6.038112, 50.0, 0.97998565),
]

FORE_DATA = [
    (188.0, 120.0, 22.0, 148.0, 1.0122981, -22.0, 1.069653),
    (220.0, 162.0, 31.0, 96.0, 6.1538644, 12.0, 1.100728),
    (239.0, 123.0, 25.0, 126.0, 0.70197266, 12.0, 0.86251676),
    (268.0, 145.0, 19.0, 111.0, 1.5690304, -20.0, 0.9693816),
    (296.0, 115.0, 29.0, 179.0, 2.9411466, 7.0, 0.9156354),
    (338.0, 151.0, 35.0, 91.0, 0.6574401, 6.0, 0.99242324),
    (358.0, 137.0, 20.0, 82.0, 2.47354, 5.0, 0.9014411),
    (385.0, 179.0, 18.0, 96.0, 2.0803256, 8.0, 0.96795046),
    (421.0, 118.0, 35.0, 92.0, 6.150862, -12.0, 1.0525628),
    (135.0, 280.0, 25.0, 105.0, 1.2, -30.0, 0.9),
    (465.0, 280.0, 25.0, 105.0, 3.8, 30.0, 0.9),
]

EMBER_DATA = [
    (0.35145327, 0.75359184, 0.07456822, 0.002869404, 2.659168, 1.3126204),
    (0.34354275, 0.6576413, 0.02627321, 0.00335497, 2.6712642, 2.5000331),
    (0.34931785, 0.50524586, 0.021653766, 0.002691063, 0.76847196, 2.3807538),
    (0.8102019, 0.2191137, 0.082479045, 0.0016005028, 1.1503485, 1.9377649),
    (0.1458724, 0.037071444, 0.0831926, 0.0019247809, 1.4577118, 3.6968048),
    (0.44593754, 0.39548117, 0.035843313, 0.0019587243, 0.63620305, 1.6901335),
    (0.5997087, 0.82103723, 0.07712446, 0.0025996137, 6.1890483, 2.5677047),
    (0.055686828, 0.12859187, 0.03535106, 0.0016478722, 1.46431, 1.9271028),
    (0.60666853, 0.6257023, 0.07275903, 0.001975711, 2.8126047, 1.6705883),
    (0.5372983, 0.16940662, 0.057935193, 0.0024581985, 3.8511493, 2.3426342),
    (0.07335137, 0.014096915, 0.047794268, 0.0017070632, 3.3525722, 1.3801259),
    (0.18955226, 0.004443144, 0.046279162, 0.003196946, 0.4903705, 2.1134357),
    (0.55564386, 0.17401387, 0.03438469, 0.0021935399, 0.7939187, 1.4471424),
    (0.98833686, 0.9422941, 0.07428087, 0.0027379375, 4.5412097, 2.937028),
    (0.105433546, 0.09334166, 0.084347956, 0.001458829, 5.0740023, 3.8159983),
    (0.5739911, 0.027800426, 0.03256628, 0.002208644, 3.5363026, 3.9215643),
    (0.04388787, 0.8252036, 0.059649836, 0.0016800314, 0.0881253, 1.9172629),
    (0.8282723, 0.6989658, 0.056335855, 0.0022581988, 5.0072494, 2.038826),
    (0.90318793, 0.08568938, 0.021013275, 0.0023352122, 3.6665792, 3.110764),
    (0.5821484, 0.37428883, 0.038392372, 0.003002517, 0.78568715, 2.4886818),
    (0.08184824, 0.07190272, 0.031780675, 0.002238701, 2.0967102, 1.4356662),
    (0.09318275, 0.09716941, 0.060782406, 0.001778858, 2.5617115, 2.1131217),
    (0.45949954, 0.7701408, 0.08297877, 0.0024658723, 5.471175, 1.3642911),
    (0.05865149, 0.62443405, 0.038747273, 0.0026832153, 1.3474624, 3.249095),
    (0.88880444, 0.057985537, 0.04909603, 0.00238236, 5.5059566, 1.809079),
    (0.67963016, 0.22456203, 0.067010775, 0.0015404392, 0.8566734, 3.8437328),
    (0.031749144, 0.3561355, 0.043567788, 0.0022942983, 2.4366524, 3.189413),
    (0.66246206, 0.6400707, 0.06545778, 0.0028321594, 0.35502744, 3.4962626),
    (0.7423852, 0.006751915, 0.0532449, 0.0017885179, 4.779317, 2.651662),
    (0.1438629, 0.4076595, 0.07802087, 0.0022449554, 3.6650777, 2.0444605),
    (0.60601777, 0.5557464, 0.03345903, 0.0021297848, 3.6660495, 1.7945294),
    (0.60100234, 0.30475444, 0.06236551, 0.0033695188, 3.4157362, 2.6895678),
    (0.6585574, 0.5612432, 0.034563214, 0.0025125355, 0.073678985, 2.8508556),
    (0.043918706, 0.14691383, 0.018103564, 0.0025877566, 4.995306, 3.64785),
    (0.68504924, 0.41212207, 0.050472137, 0.0016389843, 0.06837282, 3.2674584),
    (0.08468218, 0.5567694, 0.07209621, 0.0013969616, 5.600607, 3.5465899),
    (0.47893927, 0.23983258, 0.02196085, 0.0022885804, 0.8852009, 3.3297293),
    (0.17963764, 0.7562403, 0.05041732, 0.0033754564, 3.8260374, 1.8384643),
    (0.26399824, 0.5472559, 0.045715295, 0.0018227103, 2.7083566, 2.4783301),
    (0.27424663, 0.97521937, 0.071248665, 0.0019727922, 4.634217, 1.7626855),
    (0.71927136, 0.40146402, 0.03857106, 0.0031912304, 5.66389, 3.9645705),
    (0.7418517, 0.5690294, 0.06488968, 0.0020900036, 0.7393066, 3.3841143),
    (0.51780736, 0.54910946, 0.01842179, 0.0017494014, 2.8346431, 1.4047891),
    (0.40646958, 0.69620544, 0.074222, 0.0017818044, 5.8779984, 2.5517912),
    (0.33275557, 0.80163205, 0.026799582, 0.001940046, 5.122413, 3.7736623),
    (0.071375035, 0.1276701, 0.053157665, 0.003147481, 4.8727045, 3.2964454),
    (0.45787933, 0.274533, 0.077834435, 0.0022476986, 1.5518516, 1.4077876),
    (0.5295786, 0.85945123, 0.048071165, 0.002572885, 4.80802, 3.6812694),
    (0.43039298, 0.024518711, 0.054684103, 0.002788146, 5.936176, 1.4117119),
    (0.3681937, 0.45481485, 0.050614677, 0.003026541, 3.596069, 1.5695426),
    (0.86116964, 0.40546715, 0.07076236, 0.002858099, 2.0933197, 3.9729939),
    (0.26964176, 0.6325888, 0.07215001, 0.001786523, 4.975185, 1.7768948),
    (0.18403316, 0.93024296, 0.04944493, 0.0028791502, 4.6172376, 1.5054399),
    (0.034038283, 0.7087169, 0.02054725, 0.0017362649, 5.692345, 3.435059),
    (0.39211258, 0.34949055, 0.030800935, 0.0022139307, 3.2484672, 2.1659522),
    (0.2735003, 0.62763345, 0.06715287, 0.0028608835, 3.864403, 3.5721176),
    (0.28617334, 0.77589726, 0.054839544, 0.002167099, 2.2266755, 1.6581656),
    (0.10838005, 0.16379167, 0.03428691, 0.001964348, 3.37932, 1.3393028),
    (0.59216154, 0.60494363, 0.068395585, 0.0020576373, 5.0025725, 3.6318069),
    (0.063441336, 0.6174129, 0.05296329, 0.0033185678, 2.2717366, 3.9559398),
    (0.8071272, 0.8087642, 0.026089475, 0.0021962668, 6.2396536, 1.7433808),
    (0.47444382, 0.42908618, 0.040063016, 0.0025369143, 2.9974728, 3.8892477),
    (0.54980963, 0.5944479, 0.0428024, 0.003188218, 0.85057163, 3.3039398),
    (0.55809253, 0.044681713, 0.074814744, 0.0015702907, 5.4581428, 3.7626193),
    (0.6007861, 0.8836652, 0.0761998, 0.0030448139, 4.34473, 3.993639),
    (0.3420494, 0.32318804, 0.047002994, 0.002393715, 3.9737663, 2.7732081),
    (0.017089989, 0.6555315, 0.029948344, 0.0013506011, 5.4849777, 1.5936658),
    (0.6993706, 0.9844733, 0.026950687, 0.0028741038, 5.27788, 1.8447512),
    (0.5093121, 0.15970595, 0.051742535, 0.0028660067, 2.5439413, 2.155595),
    (0.17204224, 0.63881326, 0.08380338, 0.001647662, 5.353508, 1.5954767),
    (0.33278933, 0.63589203, 0.06963064, 0.0018985922, 1.6690091, 1.7154993),
    (0.54465216, 0.0072118742, 0.08533893, 0.0029791123, 5.5707927, 2.595582),
    (0.57150924, 0.48963755, 0.030018624, 0.0027463231, 2.9463706, 3.6874554),
    (0.78421426, 0.83982974, 0.02105478, 0.0025852653, 2.068613, 2.7358592),
    (0.5156079, 0.58477366, 0.082280666, 0.0014143711, 2.3282003, 3.9828548),
    (0.60558444, 0.8136073, 0.07424284, 0.0013347607, 4.6221876, 1.9401566),
    (0.37118465, 0.38182876, 0.068318404, 0.0033427523, 1.359039, 3.5485969),
    (0.23977506, 0.7006247, 0.03711424, 0.0012048205, 1.167171, 3.771189),
    (0.14519243, 0.4691682, 0.029890899, 0.001322772, 2.6342635, 1.3330281),
    (0.06579612, 0.7031233, 0.039465662, 0.0016527178, 5.0385513, 3.1383362),
    (0.23559336, 0.4472108, 0.062565945, 0.0033303364, 1.2760957, 1.4972029),
    (0.676376, 0.51025444, 0.07077803, 0.003256119, 2.0840046, 1.5352092),
    (0.16540839, 0.8102359, 0.061646793, 0.0016638176, 2.449685, 2.9972606),
    (0.2587391, 0.51341677, 0.045930497, 0.0012066882, 5.9829803, 3.7337458),
    (0.82378, 0.549779, 0.04560372, 0.0029407204, 6.2544665, 1.3878644),
    (0.9304427, 0.16540381, 0.05859263, 0.0012835321, 4.6392727, 3.376552),
    (0.19615725, 0.27144036, 0.052826524, 0.0016400495, 2.0470963, 3.1238825),
    (0.16128333, 0.21059282, 0.027623512, 0.0013820621, 5.5943646, 2.944388),
    (0.38870704, 0.85497, 0.039926257, 0.0026916822, 5.950263, 2.0789964),
    (0.28185812, 0.2325533, 0.052647326, 0.002817592, 0.9082373, 3.0639746),
    (0.67869925, 0.8851395, 0.0540357, 0.0027871449, 0.026117768, 1.7489711),
    (0.5072198, 0.12743928, 0.023029566, 0.003079751, 0.0921645, 1.6198168),
    (0.13109323, 0.05871667, 0.03113212, 0.002791689, 5.2887573, 3.3024716),
    (0.76390857, 0.74102455, 0.06415674, 0.002927674, 2.5290923, 1.6793194),
    (0.71931016, 0.25240538, 0.033285346, 0.0018410305, 4.7506456, 2.6657455),
    (0.27413154, 0.4608882, 0.026881993, 0.0030572354, 3.2754736, 2.4898238),
    (0.16071638, 0.43985385, 0.032450516, 0.0033366252, 3.6160905, 3.359986),
    (0.53718156, 0.53427476, 0.07682108, 0.0016285196, 3.4364498, 3.6984775),
    (0.100915514, 0.5583631, 0.04535576, 0.0028572725, 6.103058, 2.3895316),
    (0.99394196, 0.8933929, 0.05178271, 0.0020234755, 0.013315892, 3.329729),
    (0.9479235, 0.21584229, 0.043992978, 0.0024452424, 3.6460297, 2.795208),
    (0.991565, 0.2868954, 0.05561754, 0.0028432377, 3.5359383, 2.3851378),
    (0.5352202, 0.7927154, 0.02958422, 0.0031721331, 1.5589678, 3.6442876),
    (0.30018756, 0.52452856, 0.06738229, 0.0019260817, 1.1966727, 1.8339193),
    (0.11503511, 0.52082586, 0.052266944, 0.0027913821, 5.3421574, 2.9954119),
    (0.95806545, 0.7864093, 0.048641413, 0.0022003057, 0.14620346, 2.271172),
    (0.39162952, 0.97116226, 0.08477818, 0.0018303451, 1.2768098, 2.0021315),
    (0.35093156, 0.35398936, 0.08769091, 0.003375566, 1.370231, 1.7823417),
    (0.23804131, 0.097517796, 0.063168764, 0.0025515822, 0.46569273, 2.5894952),
    (0.046290256, 0.6178864, 0.01977662, 0.0015818769, 2.8335335, 1.4605821),
    (0.0642529, 0.26820958, 0.048564766, 0.0032008193, 4.956412, 3.396197),
    (0.9641684, 0.08053581, 0.0718612, 0.0029727502, 3.171625, 2.0477986),
    (0.9142806, 0.013667062, 0.040491834, 0.0021799076, 6.15172, 3.5584762),
    (0.20216346, 0.12614143, 0.039191827, 0.0018839419, 3.0492287, 3.3323927),
    (0.9826621, 0.34370998, 0.06786029, 0.0033123163, 2.5659404, 2.3945348),
    (0.33431304, 0.21804915, 0.05441247, 0.0031678982, 1.3965073, 3.824519),
    (0.82340914, 0.44146833, 0.057559002, 0.0016822733, 0.15534887, 1.6713841),
    (0.4091994, 0.4322458, 0.059490617, 0.0020102726, 4.39857, 1.4632215),
    (0.15627886, 0.6008777, 0.062714666, 0.0016155969, 6.103412, 2.1770754),
    (0.7567345, 0.7533702, 0.07280268, 0.002704583, 5.8230915, 2.5019069),
    (0.06407945, 0.0040247343, 0.06504992, 0.0020009372, 2.9623244, 2.0742128),
    (0.7567844, 0.019781427, 0.073397964, 0.0020498708, 3.9080477, 2.7516203),
    (0.271344, 0.9829483, 0.02509913, 0.0015634196, 5.665276, 1.4432845),
    (0.16001493, 0.6143564, 0.06305446, 0.0026340424, 5.0506825, 3.4802945),
    (0.7666024, 0.14540538, 0.035264254, 0.0016297379, 0.8655755, 2.5660229),
    (0.15211159, 0.13950771, 0.054026704, 0.0014639514, 0.97471756, 1.3558913),
    (0.465408, 0.045137, 0.08525343, 0.0018731509, 3.8421884, 3.1367922),
    (0.26905295, 0.76997393, 0.0865212, 0.0014225162, 5.765053, 3.9688652),
    (0.22342658, 0.5915438, 0.077618085, 0.0028056197, 3.2915788, 2.1436007),
    (0.80151564, 0.41224203, 0.032011196, 0.0031021754, 3.753841, 2.180408),
    (0.040113267, 0.561449, 0.07974117, 0.0019095046, 1.4714366, 2.6027384),
    (0.02296998, 0.15136614, 0.07594688, 0.0013775744, 4.3967347, 3.612675),
    (0.09230501, 0.8540373, 0.018198455, 0.0033193517, 2.405035, 1.3915054),
    (0.8286422, 0.66545874, 0.03394892, 0.00176796, 6.106503, 2.7747965),
    (0.6172104, 0.4222845, 0.061093483, 0.0016448895, 2.0008981, 3.305813),
    (0.8205406, 0.6007828, 0.04933739, 0.0025963099, 1.6704259, 1.4351952),
    (0.79827666, 0.94655085, 0.055504642, 0.0022920328, 0.49116543, 3.3687332),
    (0.16065598, 0.14271095, 0.08042327, 0.0033893096, 4.0055513, 3.108593),
    (0.30960965, 0.838174, 0.020062027, 0.0015657919, 0.22608116, 3.8164034),
    (0.098235376, 0.78194964, 0.05926781, 0.001938751, 4.431348, 3.492154),
    (0.8668745, 0.8207475, 0.07630327, 0.0013868217, 1.6346797, 1.5672996),
    (0.40886927, 0.4576188, 0.059172105, 0.003296078, 1.0371033, 2.477831),
    (0.49811026, 0.33226362, 0.059109952, 0.0022156173, 0.6126406, 3.5388343),
    (0.65445983, 0.62206966, 0.072933376, 0.0032806983, 5.6082864, 2.5967784),
    (0.7134361, 0.6542716, 0.057535987, 0.0023344867, 3.3705208, 2.6065698),
    (0.46053213, 0.46248084, 0.034888137, 0.002792518, 3.9551737, 1.9950507),
    (0.9332936, 0.07573703, 0.07977752, 0.0029440746, 3.6835437, 1.7857388),
    (0.08167634, 0.35684693, 0.06511763, 0.0025050924, 4.1980414, 3.2000422),
    (0.34471625, 0.63659114, 0.065910935, 0.0028727532, 4.280834, 1.5246994),
    (0.027146408, 0.9211026, 0.08296943, 0.0019757545, 2.3340263, 2.9359393),
    (0.5342001, 0.89319354, 0.08248176, 0.001429368, 3.0926847, 3.1969771),
    (0.19497453, 0.7742385, 0.067193165, 0.0019256894, 3.3196268, 1.3587806),
    (0.94666195, 0.8616986, 0.020505875, 0.00253069, 5.429113, 2.7465677),
    (0.8071793, 0.12021225, 0.0870279, 0.003094377, 1.0741384, 3.7296212),
    (0.7994728, 0.7001898, 0.07268013, 0.0015476816, 4.3775253, 3.212684),
    (0.3292915, 0.580678, 0.067297794, 0.0018085915, 1.6245394, 3.1713104),
    (0.25873533, 0.9774182, 0.078523144, 0.0033351546, 2.5022006, 3.7135847),
    (0.00095980335, 0.0148574365, 0.025576837, 0.0026578768, 5.112354, 3.5130208),
    (0.047423806, 0.4222873, 0.02199049, 0.0020632115, 3.4269764, 1.9784305),
    (0.6197906, 0.6731196, 0.06855638, 0.0012468782, 1.9149665, 3.43851),
    (0.92143935, 0.036937468, 0.023425918, 0.0033875878, 0.003564488, 3.8587162),
    (0.31751642, 0.6700294, 0.060219627, 0.0019539846, 2.1746957, 3.694029),
    (0.67114955, 0.8366545, 0.0685374, 0.0014028237, 5.404138, 1.7214755),
    (0.7916191, 0.13680147, 0.080055654, 0.0033153165, 0.69498307, 2.0409827),
    (0.6513945, 0.93692267, 0.020466914, 0.002196564, 4.1269374, 2.880692),
    (0.9708439, 0.23742709, 0.06508429, 0.0013596662, 0.30840394, 2.275542),
    (0.81640714, 0.006601697, 0.019000307, 0.0015532494, 2.1686082, 1.6878576),
    (0.21649985, 0.7047035, 0.023331443, 0.0015747251, 4.5314207, 3.2137108),
    (0.52930766, 0.527598, 0.074909925, 0.0024454903, 1.4431367, 1.7535565),
    (0.9055314, 0.9599319, 0.08284269, 0.002966765, 2.1548405, 1.4718405),
    (0.912431, 0.8645327, 0.018923126, 0.0012389313, 2.3364995, 1.5934811),
    (0.2140446, 0.59857404, 0.07312983, 0.0019934322, 1.73276, 3.6045012),
    (0.14181194, 0.63105124, 0.07341526, 0.0028342884, 4.6808825, 2.3959563),
    (0.19827461, 0.48106492, 0.033099238, 0.0019182116, 5.8034563, 1.6489583),
    (0.7724425, 0.40471193, 0.018541658, 0.0023102276, 1.0495383, 1.5407145),
    (0.4349877, 0.013332077, 0.06445466, 0.00329142, 1.5590442, 2.59768),
    (0.13046347, 0.19880381, 0.041297898, 0.003328427, 6.0083385, 1.6311421),
    (0.9212128, 0.16865666, 0.03562688, 0.0033108562, 2.6660028, 2.9163222),
    (0.37633735, 0.16267298, 0.033044703, 0.002344912, 3.7999609, 3.6271265),
    (0.8479412, 0.58597124, 0.083859965, 0.003144676, 1.5409279, 3.911344),
    (0.10095873, 0.70939565, 0.04820709, 0.0027365142, 5.8159423, 2.008624),
    (0.18988088, 0.19116648, 0.044804, 0.0018842536, 3.8476772, 2.7747502),
    (0.07308266, 0.23080783, 0.054734595, 0.001404728, 2.5461667, 3.3385522),
    (0.8774313, 0.8129625, 0.08662743, 0.0021000202, 0.8061816, 1.311802),
    (0.87422913, 0.91457325, 0.046597213, 0.0029638265, 0.64529055, 3.0878472),
    (0.5397655, 0.24651979, 0.08474852, 0.0020044579, 5.44427, 1.9666011),
    (0.6911153, 0.22279732, 0.035009533, 0.0033765903, 4.8353915, 1.9295145),
    (0.21572357, 0.06531301, 0.056519464, 0.0026711854, 2.8105855, 2.3097801),
    (0.33711877, 0.75488305, 0.030650698, 0.0016088422, 0.040917434, 2.467186),
    (0.98677254, 0.69185865, 0.058675885, 0.0021397492, 5.178363, 1.3299431),
]

DRIP_DATA = [
    (184.0, 302.0, 80.83918, 6.3727813, 0.46744034, 0.36273882),
    (205.0, 332.0, 67.81453, 7.7229853, 0.14941318, 0.33975527),
    (235.0, 365.0, 109.20231, 6.446719, 0.23985098, 0.5837937),
    (266.0, 516.0, 125.75615, 6.5148263, 0.7097725, 0.41856146),
    (300.0, 540.0, 100.25126, 11.118567, 0.5374383, 0.51318437),
    (334.0, 516.0, 154.04303, 6.181984, 0.48560062, 0.42043456),
    (365.0, 365.0, 76.99959, 8.160125, 0.71395177, 0.24972394),
    (395.0, 332.0, 152.90341, 9.635256, 0.13914758, 0.37183198),
    (416.0, 302.0, 69.625, 10.173779, 0.06012409, 0.35209674),
    (152.0, 352.0, 57.474266, 7.697048, 0.60358804, 0.5770287),
    (448.0, 352.0, 45.898647, 7.770502, 0.66178024, 0.47912788),
    (251.0, 508.0, 53.99075, 5.9026203, 0.87327623, 0.40801567),
    (349.0, 508.0, 87.86216, 4.092205, 0.24105275, 0.3009556),
]

SPARK_DATA = [
    (556.6024, 383.53882, 0.65178865, 2.824398),
    (474.52344, 355.77338, 0.13987443, 2.7164426),
    (167.55135, 519.63354, 0.8393544, 2.2132764),
    (100.66148, 455.00922, 0.7485973, 1.6004622),
    (430.594, 400.1516, 0.51246583, 1.3159866),
    (426.3707, 483.87244, 0.54282993, 2.155998),
    (512.94586, 395.82727, 0.80812454, 2.151589),
    (116.95068, 380.97183, 0.3593149, 1.5219223),
    (110.80856, 304.4503, 0.12128616, 2.9787173),
    (91.72168, 385.55945, 0.7973092, 2.0154452),
    (465.57465, 456.5905, 0.903494, 2.3512006),
    (479.00455, 500.54703, 0.45369977, 1.0233946),
    (497.8558, 465.4942, 0.5417801, 1.3044603),
    (512.64355, 325.6837, 0.24335961, 1.5642896),
    (434.12756, 368.77365, 0.45244384, 1.0418108),
    (30.196808, 371.04294, 0.52260035, 2.5855126),
    (86.80313, 292.51822, 0.011665466, 2.6197772),
    (46.10219, 418.9887, 0.11707661, 2.4329982),
    (495.61267, 512.08386, 0.30055553, 2.3297434),
    (524.3931, 414.42307, 0.928686, 1.1642289),
    (478.77426, 327.15314, 0.48098087, 2.7334862),
    (563.2417, 348.004, 0.83596504, 2.1156394),
]


def create_mane_flames() -> List[FlameSpec]:
    return [FlameSpec(*row) for row in MANE_DATA]


def create_foreground_flames() -> List[FlameSpec]:
    return [FlameSpec(*row) for row in FORE_DATA]


def create_embers() -> List[EmberSpec]:
    return [EmberSpec(*row) for row in EMBER_DATA]


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


def _vignette_surface(bw: int, bh: int):
    """Black overlay whose alpha matches GDI+'s rectangle PathGradientBrush."""
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, bw, bh)
    data = surface.get_data()
    cx = bw * 0.50
    cy = bh * 0.46
    left = cx if cx > 0.0 else 1.0
    right = (bw - cx) if (bw - cx) > 0.0 else 1.0
    top = cy if cy > 0.0 else 1.0
    bottom = (bh - cy) if (bh - cy) > 0.0 else 1.0
    stride = bw * 4
    for y in range(bh):
        dy = y + 0.5 - cy
        fy = (-dy / top) if dy < 0.0 else (dy / bottom)
        row = y * stride
        for x in range(bw):
            dx = x + 0.5 - cx
            fx = (-dx / left) if dx < 0.0 else (dx / right)
            f = fx if fx > fy else fy
            if f <= 0.0:
                continue
            if f > 1.0:
                f = 1.0
            # ARGB32 is premultiplied; the colour is black so only alpha moves.
            data[row + x * 4 + 3] = int(170.0 * f + 0.5)
    surface.mark_dirty()
    return surface


def build_background_surface(w: int, h: int):
    """Bake the low-resolution burning-city backdrop, then scale it up."""
    bw = max(80, w // 6)
    bh = max(50, h // 6)
    low = _build_background_low(bw, bh)

    full = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h)
    fctx = cairo.Context(full)
    fctx.scale(w / bw, h / bh)
    pattern = cairo.SurfacePattern(low)
    pattern.set_filter(cairo.FILTER_BEST)
    fctx.set_source(pattern)
    fctx.paint()
    return full


def _build_background_low(bw: int, bh: int):
    """Draw the low-resolution backdrop that gets scaled up to the window."""
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
    # GDI+ FillEllipse uses (x, y, w, h) = (0.775bw, 0.145bh, 0.050bw, 0.050bw).
    fill_ellipse(ctx, bw * 0.775 + bw * 0.025, bh * 0.145 + bw * 0.025,
                 bw * 0.025, bw * 0.025, rgba(255, 132, 58, 80))

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

    # Vignette baked into the cached scene.  GDI+ rasterizes a rectangle
    # PathGradientBrush: the alpha at a pixel is the largest of the two
    # axis ratios measured from the focus point, i.e. the "Chebyshev" radius
    # of a rectangle homothetic about the focus.  Cairo only offers radial
    # (elliptical) gradients, so the field is filled pixel by pixel instead.
    vig = _vignette_surface(bw, bh)
    ctx.set_source_surface(vig, 0, 0)
    ctx.paint()
    return low


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


CHAR_DATA = [
    (431.20102, 56.07893, 12.809923, 15.278094, 185, 80, 45, 13),
    (143.11578, 336.61966, 16.179329, 5.1749997, 75, 46, 34, 15),
    (159.2346, 485.51343, 28.823956, 22.381214, 20, 9, 6, 22),
    (225.32191, 499.05414, 11.699255, 23.687855, 75, 46, 34, 16),
    (423.87006, 400.36884, 29.295498, 24.851337, 116, 36, 16, 16),
    (213.1122, 144.2117, 10.1653805, 22.9981, 185, 80, 45, 13),
    (197.96204, 364.66473, 7.2245235, 27.738033, 4, 1, 0, 25),
    (358.7828, 503.64917, 19.553328, 13.415388, 20, 9, 6, 30),
    (167.46042, 105.282455, 36.493103, 28.015827, 20, 9, 6, 33),
    (142.9428, 165.16867, 14.725964, 31.077833, 185, 80, 45, 24),
    (322.41144, 266.7178, 12.535122, 6.6752605, 75, 46, 34, 18),
    (163.09337, 318.81406, 20.988525, 17.20446, 116, 36, 16, 18),
    (280.26593, 326.77213, 35.989567, 31.883873, 20, 9, 6, 31),
    (470.42422, 326.73047, 33.912613, 29.046314, 185, 80, 45, 15),
    (260.1521, 306.07678, 14.312529, 9.345059, 185, 80, 45, 14),
    (480.20035, 235.10898, 9.873907, 12.274733, 4, 1, 0, 36),
    (140.88637, 353.4248, 12.09808, 32.68715, 4, 1, 0, 29),
    (270.72818, 426.19815, 33.92279, 20.955395, 116, 36, 16, 21),
    (169.74121, 149.28122, 15.401715, 16.004429, 20, 9, 6, 33),
    (123.75953, 432.7168, 39.852634, 31.717262, 75, 46, 34, 14),
    (193.12051, 551.442, 6.6061726, 10.085034, 185, 80, 45, 27),
    (181.28464, 156.7886, 18.823729, 9.691551, 20, 9, 6, 20),
    (377.59967, 66.78989, 20.972692, 15.370405, 116, 36, 16, 28),
    (311.9242, 485.64532, 12.846022, 29.433403, 20, 9, 6, 19),
    (482.96762, 357.6986, 22.333342, 9.005955, 116, 36, 16, 21),
    (390.89896, 149.35223, 40.711353, 33.034435, 75, 46, 34, 12),
    (259.086, 180.73387, 17.53632, 28.069798, 116, 36, 16, 14),
    (134.17899, 54.41434, 19.90139, 31.541391, 75, 46, 34, 27),
    (325.2704, 399.26456, 20.017769, 9.464983, 116, 36, 16, 29),
    (127.2156, 256.14572, 6.268712, 25.811012, 4, 1, 0, 41),
    (316.8094, 81.029686, 42.97393, 32.151917, 185, 80, 45, 21),
    (273.8722, 438.86423, 17.89228, 12.762737, 20, 9, 6, 14),
    (282.6381, 435.19308, 25.204308, 7.144364, 75, 46, 34, 29),
    (469.84836, 102.39035, 40.957325, 21.387354, 185, 80, 45, 19),
    (133.81264, 349.1875, 36.765816, 9.221914, 20, 9, 6, 18),
    (162.68585, 403.31558, 8.422034, 19.597576, 116, 36, 16, 18),
    (153.41629, 133.28256, 27.595104, 27.547056, 185, 80, 45, 26),
    (328.03778, 207.87155, 33.27568, 12.612542, 75, 46, 34, 21),
    (215.78397, 540.9127, 30.178524, 5.614087, 75, 46, 34, 11),
    (444.5573, 552.995, 24.020058, 19.50628, 20, 9, 6, 30),
    (411.20178, 199.25607, 38.58041, 5.6461277, 4, 1, 0, 25),
    (132.6658, 537.8624, 25.892237, 11.865183, 20, 9, 6, 25),
    (263.19376, 151.70041, 29.80248, 6.557495, 20, 9, 6, 17),
    (405.85742, 458.45673, 39.14656, 12.0409565, 20, 9, 6, 32),
    (355.6327, 113.0887, 41.220303, 34.227013, 75, 46, 34, 14),
    (415.20358, 369.35532, 17.698147, 27.705477, 20, 9, 6, 15),
    (114.68332, 330.123, 12.94239, 19.473896, 4, 1, 0, 38),
    (132.48912, 78.76973, 6.6142, 6.836627, 75, 46, 34, 21),
    (280.20822, 468.24878, 6.944551, 11.832227, 75, 46, 34, 10),
    (463.7607, 332.96887, 21.84194, 33.956, 116, 36, 16, 12),
    (225.07056, 96.70655, 19.377464, 14.325797, 185, 80, 45, 15),
    (214.9129, 377.14612, 14.749335, 19.41056, 4, 1, 0, 29),
    (137.2291, 202.05446, 28.747929, 10.071676, 4, 1, 0, 40),
    (451.52557, 346.59042, 24.531424, 17.017094, 185, 80, 45, 23),
    (186.47108, 341.71323, 40.252384, 13.480418, 20, 9, 6, 20),
    (389.22314, 77.562225, 12.553074, 10.570959, 4, 1, 0, 21),
    (248.79272, 428.161, 29.083094, 25.702557, 75, 46, 34, 29),
    (229.64748, 537.78217, 35.189507, 23.159384, 4, 1, 0, 29),
    (269.0971, 434.94666, 20.14958, 23.460451, 4, 1, 0, 40),
    (300.412, 505.12375, 26.686543, 22.516365, 4, 1, 0, 41),
    (262.29437, 550.703, 36.35451, 30.064219, 75, 46, 34, 29),
    (202.38008, 496.97845, 10.30913, 20.183521, 20, 9, 6, 21),
    (181.79903, 158.33313, 35.601723, 20.894402, 4, 1, 0, 33),
    (485.73212, 351.96347, 21.51562, 20.506351, 20, 9, 6, 13),
    (117.05792, 113.72467, 42.285007, 16.614655, 75, 46, 34, 15),
    (318.84637, 444.68262, 29.631966, 28.208652, 116, 36, 16, 29),
    (167.2446, 293.6939, 14.214372, 28.89314, 116, 36, 16, 17),
    (221.11148, 510.27963, 41.449017, 33.65679, 185, 80, 45, 25),
    (486.16522, 539.6354, 36.21196, 5.0102816, 185, 80, 45, 19),
    (273.74374, 495.94812, 10.787874, 27.691566, 20, 9, 6, 25),
    (114.48082, 481.9752, 13.449673, 30.171934, 20, 9, 6, 12),
    (409.6273, 261.66156, 40.01616, 5.2495437, 116, 36, 16, 25),
]


def create_charring() -> List[CharSpec]:
    return [CharSpec(x, y, rx, ry, rgba(r, g, b, a))
            for (x, y, rx, ry, r, g, b, a) in CHAR_DATA]


SOOT_STREAKS = [
    (174, 242), (155, 300), (166, 362), (151, 420),
    (214, 250), (201, 306), (212, 370), (200, 435),
    (248, 260), (238, 320), (249, 382), (239, 449),
    (341, 260), (355, 320), (344, 382), (357, 449),
    (386, 250), (401, 306), (390, 370), (405, 435),
    (426, 242), (445, 300), (434, 362), (449, 420),
]


def create_drips() -> List[DripSpec]:
    return [DripSpec(*row) for row in DRIP_DATA]


def create_sparks() -> List[SparkSpec]:
    return [SparkSpec(*row) for row in SPARK_DATA]


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
    b = socket_bounds(left)
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
    b = socket_bounds(left)
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

class _PrankWindow:
    """One fullscreen prank window and the drawing state for its monitor."""

    __slots__ = ("window", "area", "renderer", "renderer_size",
                 "renderer_failed", "geometry", "monitor", "primary")

    def __init__(self, window, monitor, geometry, primary):
        self.window = window
        self.area = None
        self.renderer = None
        self.renderer_size = None
        self.renderer_failed = False
        self.geometry = geometry
        self.monitor = monitor
        self.primary = primary


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
        self.windows = []
        # Compatibility aliases for the primary window.
        self.window = None
        self.area = None
        self.timer_id = None
        self.cursor_timer_id = None
        self.blank_cursor = None
        self._seat = None
        self._grab_ticks = 0
        self.closing = False
        self.windowed = args.windowed_size is not None

        self.app = Gtk.Application(
            application_id="com.bossdefender.fakeransom",
            flags=Gio.ApplicationFlags.FLAGS_NONE,
        )
        self.app.connect("activate", self._on_activate)
        self.app.connect("shutdown", self._on_shutdown)

    # -- window setup -------------------------------------------------------

    def _monitors(self):
        """Return ([(monitor, (x, y, width, height)), ...], primary_index).

        GTK 3 names a monitor by its GdkScreen index; GTK 4 needs the
        GdkMonitor object itself for fullscreen_on_monitor().  GTK 4 no
        longer exposes a primary-monitor query, so its first monitor is
        treated as primary, which matches the compositor's order.
        """
        result = []
        primary = 0
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                if self.version == "4.0":
                    display = self.Gdk.Display.get_default()
                    monitors = display.get_monitors() if display else None
                    if monitors is not None:
                        for index in range(monitors.get_n_items()):
                            monitor = monitors.get_item(index)
                            geo = monitor.get_geometry()
                            if geo.width > 0 and geo.height > 0:
                                result.append(
                                    (monitor,
                                     (int(geo.x), int(geo.y),
                                      int(geo.width), int(geo.height))))
                else:
                    screen = self.Gdk.Screen.get_default()
                    if screen is not None:
                        primary_ref = screen.get_primary_monitor()
                        for index in range(screen.get_n_monitors()):
                            geo = screen.get_monitor_geometry(index)
                            if geo.width > 0 and geo.height > 0:
                                result.append(
                                    (index,
                                     (int(geo.x), int(geo.y),
                                      int(geo.width), int(geo.height))))
                        primary = next(
                            (pos for pos, item in enumerate(result)
                             if item[0] == primary_ref), 0)
        except Exception:
            result = []
            primary = 0
        if not result:
            return [(0, (0, 0, 1920, 1080))], 0
        if primary < 0 or primary >= len(result):
            primary = 0
        return result, primary

    def _monitor_geometry(self):
        monitors, primary = self._monitors()
        return monitors[primary][1]

    def _create_window(self, app, monitor, geometry, primary):
        win = self.Gtk.Window()
        win.set_application(app)
        win.set_title("Locked by BossDefender")
        win.set_decorated(False)
        win.set_resizable(False)
        try:
            win.set_modal(False)
        except Exception:
            pass

        if primary:
            try:
                win.set_can_focus(True)
            except Exception:
                pass
        else:
            # Display-only window: it must never take focus or keyboard
            # input.  The primary window owns the password and mirrors its
            # state here.
            try:
                if self.version == "3.0":
                    win.set_accept_focus(False)
                    win.set_focus_on_map(False)
                else:
                    win.set_focusable(False)
            except Exception:
                pass
            try:
                win.set_can_focus(False)
            except Exception:
                pass

        if self.windowed:
            width, height = self.args.windowed_size
            win.set_default_size(width, height)
        else:
            mx, my, mw, mh = geometry
            win.set_default_size(mw, mh)
            if self.version == "3.0":
                try:
                    win.move(mx, my)
                except Exception:
                    pass

        if self.version == "3.0":
            try:
                win.set_keep_above(True)
                win.set_skip_taskbar_hint(True)
                win.set_skip_pager_hint(True)
                win.set_urgency_hint(False)
            except Exception:
                pass

        rec = _PrankWindow(win, monitor, geometry, primary)
        area = self.Gtk.DrawingArea()
        rec.area = area
        if self.version == "4.0":
            area.set_draw_func(
                lambda widget, cr, width, height, r=rec: self._draw(
                    r, cr, int(width), int(height)))
            area.set_hexpand(True)
            area.set_vexpand(True)
            win.set_child(area)
        else:
            area.set_size_request(640, 480)
            area.connect(
                "draw",
                lambda widget, cr, r=rec: self._on_draw3(r, widget, cr))
            win.add(area)
            # GTK 3 does not reveal children automatically the way GTK 4
            # does.  Without this the DrawingArea stays hidden and the
            # window shows only the theme background.
            area.show()

        if self.version == "4.0":
            if primary:
                controller = self.Gtk.EventControllerKey.new()
                controller.set_propagation_phase(
                    self.Gtk.PropagationPhase.CAPTURE)
                controller.connect("key-pressed", self._on_key4)
                win.add_controller(controller)
            win.connect("close-request", self._on_close_request)
            win.connect(
                "notify::fullscreened",
                lambda window, pspec, r=rec:
                self._on_fullscreen_changed4(r, window, pspec))
        else:
            if primary:
                win.connect("key-press-event", self._on_key3)
                win.connect(
                    "realize",
                    lambda window, r=rec: self._on_realize3(r, window))
            win.connect("delete-event", self._on_delete_event)
            win.connect(
                "window-state-event",
                lambda window, event, r=rec:
                self._on_window_state3(r, window, event))

        for widget in (win, area):
            if widget is None:
                continue
            try:
                widget.connect("map", lambda w, r=rec: self._on_map(r))
            except Exception:
                pass
        if primary:
            try:
                win.connect(
                    "notify::is-active",
                    lambda window, pspec, r=rec:
                    self._on_active_changed(r, window, pspec))
            except Exception:
                pass
        return rec

    def _build_windows(self, app):
        monitors, primary_index = self._monitors()
        if self.windowed:
            monitors = [monitors[primary_index]]
            primary_index = 0
        for index, (monitor, geometry) in enumerate(monitors):
            rec = self._create_window(
                app, monitor, geometry, index == primary_index)
            self.windows.append(rec)
            if rec.primary:
                self.window = rec.window
                self.area = rec.area

        if self.window is None:
            # Defensive fallback: there must always be one window that can
            # take keyboard input.
            rec = self._create_window(app, 0, (0, 0, 1920, 1080), True)
            self.windows.append(rec)
            self.window = rec.window
            self.area = rec.area

    def _show_window(self, rec, activate):
        try:
            if self.version == "3.0":
                rec.window.show_all()
            if activate:
                rec.window.present()
                try:
                    rec.window.grab_focus()
                except Exception:
                    pass
            elif self.version == "4.0":
                rec.window.set_visible(True)
        except Exception:
            pass

    def _show_windows(self):
        if not self.windowed:
            for rec in self.windows:
                self._fullscreen_on(rec)
        # Map the display-only windows first and the primary last, so the
        # window manager gives the keyboard focus to the primary window.
        for rec in self.windows:
            if not rec.primary:
                self._show_window(rec, False)
        for rec in self.windows:
            if rec.primary:
                self._show_window(rec, True)

    def _primary_window(self):
        for rec in self.windows:
            if rec.primary:
                return rec
        return None

    def _focus_primary(self):
        rec = self._primary_window()
        if rec is None:
            return
        try:
            rec.window.present()
            rec.window.grab_focus()
        except Exception:
            pass
        self._refullscreen()

    def _fullscreen_on(self, rec):
        if self.windowed or rec.window is None:
            return
        try:
            if self.version == "3.0":
                screen = self.Gdk.Screen.get_default()
                if screen is not None:
                    rec.window.fullscreen_on_monitor(screen, rec.monitor)
                else:
                    rec.window.fullscreen()
            else:
                rec.window.fullscreen_on_monitor(rec.monitor)
        except Exception:
            try:
                rec.window.fullscreen()
            except Exception:
                pass

    def _on_activate(self, app):
        if self.windows:
            self._focus_primary()
            return

        self._build_windows(app)
        self._show_windows()

        self.GLib.idle_add(self._hide_cursor)
        if self.version == "3.0":
            self.GLib.idle_add(self._grab_keyboard)
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

    # -- drawing ------------------------------------------------------------

    def _queue_draw(self, rec=None):
        targets = self.windows if rec is None else (rec,)
        for item in targets:
            if item.area is not None:
                try:
                    item.area.queue_draw()
                except Exception:
                    pass

    def _draw(self, rec, cr, width, height):
        if width <= 0 or height <= 0:
            return
        if rec.renderer_failed:
            cr.set_source_rgba(0.02, 0.0, 0.0, 1.0)
            cr.paint()
            return
        try:
            if rec.renderer is None or rec.renderer_size != (width, height):
                rec.renderer = RansomRenderer(
                    width, height, self.Pango, self.PangoCairo)
                rec.renderer_size = (width, height)
            rec.renderer.draw(
                cr, time.monotonic(), self.start,
                self.state.typed, self.state.denied_until)
        except Exception:
            rec.renderer_failed = True
            traceback.print_exc()
            cr.set_source_rgba(0.02, 0.0, 0.0, 1.0)
            cr.paint()

    def _on_draw3(self, rec, area, cr):
        alloc = area.get_allocation()
        self._draw(rec, cr, int(alloc.width), int(alloc.height))
        return False

    # -- input --------------------------------------------------------------

    def _modifier_mask(self):
        # GTK 3 exposes Alt as MOD1_MASK; GTK 4 renamed it ALT_MASK.
        # Look both up defensively so the same code works on either.
        mods = self.Gdk.ModifierType.CONTROL_MASK
        for name in ("ALT_MASK", "MOD1_MASK",
                     "SUPER_MASK", "META_MASK", "HYPER_MASK"):
            mods |= getattr(self.Gdk.ModifierType, name, 0)
        return mods

    def _handle_key(self, keyval, state):
        if self.closing:
            return True
        if state & self._modifier_mask():
            return True

        if keyval in (self.Gdk.KEY_Return, self.Gdk.KEY_KP_Enter,
                      getattr(self.Gdk, "KEY_ISO_Enter", self.Gdk.KEY_Return)):
            if self.state.enter(time.monotonic()):
                self._exit_prank()
            else:
                self._queue_draw()
            return True

        if keyval == getattr(self.Gdk, "KEY_BackSpace", 0xFF08):
            self.state.backspace()
            self._queue_draw()
            return True

        codepoint = self.Gdk.keyval_to_unicode(keyval)
        if codepoint <= 0 or codepoint > 0x10FFFF:
            return True
        ch = chr(codepoint)
        # Only ASCII letters and digits may enter the password.  Space,
        # punctuation and every other character is ignored.
        if not (("a" <= ch <= "z") or ("A" <= ch <= "Z") or
                ("0" <= ch <= "9")):
            return True
        self.state.type_char(ch)
        self._queue_draw()
        return True

    def _on_key4(self, controller, keyval, keycode, state):
        return self._handle_key(keyval, state)

    def _on_key3(self, widget, event):
        return self._handle_key(event.keyval, event.state)

    # -- keyboard grab (X11 only) -----------------------------------------

    def _is_x11(self):
        try:
            name = self.Gdk.Display.get_default().get_name() or ""
        except Exception:
            return False
        return not name.lower().startswith("wayland")

    def _grab_keyboard(self):
        """Hold an X11 keyboard grab so the WM sees no Super/Alt+Tab.

        Wayland has no client-side keyboard grab and GTK 4 removed the
        API, so this only applies to GTK 3 on X11.  Elsewhere the app
        still filters every key it receives.
        """
        rec = self._primary_window()
        if (self.version != "3.0" or rec is None or
                self.closing or self.windowed or not self._is_x11()):
            if os.environ.get("FAKE_RANSOM_DEBUG", "").strip():
                print("keyboard grab: not available on this backend",
                      file=sys.stderr)
            return False

        try:
            display = self.Gdk.Display.get_default()
            seat = display.get_default_seat() if display is not None else None
            gdk_window = rec.window.get_window()
            if seat is not None and gdk_window is not None:
                status = seat.grab(
                    gdk_window,
                    self.Gdk.SeatCapabilities.KEYBOARD |
                    self.Gdk.SeatCapabilities.POINTER,
                    False, None, None, None, None,
                )
                if os.environ.get("FAKE_RANSOM_DEBUG", "").strip():
                    print("keyboard grab:", status, file=sys.stderr)
                if status == self.Gdk.GrabStatus.SUCCESS:
                    self._seat = seat
        except Exception:
            self._seat = None
        return False

    def _release_keyboard(self):
        if self._seat is not None:
            try:
                self._seat.ungrab()
            except Exception:
                pass
            self._seat = None

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
        if self.closing or self.windowed:
            return False
        for rec in list(self.windows):
            try:
                if rec.window is not None and not rec.window.is_fullscreen():
                    self._fullscreen_on(rec)
                    if self.version == "3.0":
                        rec.window.set_keep_above(True)
            except Exception:
                pass
        rec = self._primary_window()
        if rec is not None:
            try:
                rec.window.present()
            except Exception:
                pass
        self._grab_keyboard()
        return False

    def _on_fullscreen_changed4(self, rec, window, pspec):
        if self.closing or self.windowed:
            return
        try:
            if not window.is_fullscreen():
                self.GLib.idle_add(self._refullscreen)
        except Exception:
            pass

    def _on_window_state3(self, rec, window, event):
        if self.closing or self.windowed:
            return False
        try:
            if event.new_window_state & self.Gdk.WindowState.ICONIFIED:
                window.deiconify()
                self._fullscreen_on(rec)
                if rec.primary:
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

    def _apply_cursor(self, cursor, rec=None) -> None:
        targets = self.windows if rec is None else (rec,)
        for item in targets:
            window = item.window
            if window is None:
                continue
            try:
                if self.version == "4.0":
                    window.set_cursor(cursor)
                    if item.area is not None:
                        item.area.set_cursor(cursor)
                else:
                    for widget in (window, item.area):
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

    def _on_map(self, rec):
        self.GLib.idle_add(self._hide_cursor)
        if rec.primary and self.version == "3.0":
            self.GLib.idle_add(self._grab_keyboard)
        self._queue_draw(rec)

    def _on_active_changed(self, rec, window, pspec):
        try:
            if window.is_active():
                self.GLib.idle_add(self._hide_cursor)
                self.GLib.idle_add(self._refullscreen)
            elif not self.closing and not self.windowed:
                # A display-only window was clicked.  Put the keyboard
                # focus straight back on the primary window.
                self.GLib.timeout_add(80, self._refocus_primary)
        except Exception:
            pass

    def _refocus_primary(self):
        if self.closing or self.windowed:
            return False
        rec = self._primary_window()
        if rec is not None:
            try:
                rec.window.present()
                rec.window.grab_focus()
            except Exception:
                pass
        self._grab_keyboard()
        return False

    def _cursor_tick(self):
        if self.closing:
            return False
        self._hide_cursor()
        return True

    def _on_realize3(self, rec, window):
        self._hide_cursor()
        if not rec.primary:
            return
        try:
            window.grab_focus()
        except Exception:
            pass
        if rec.area is not None:
            try:
                rec.area.grab_focus()
            except Exception:
                pass

    # -- timers / exit ------------------------------------------------------

    def _on_tick(self):
        if self.closing:
            return False
        self._queue_draw()
        if not self.windowed:
            for rec in list(self.windows):
                try:
                    if not rec.window.is_fullscreen():
                        self._fullscreen_on(rec)
                        if self.version == "3.0":
                            rec.window.set_keep_above(True)
                except Exception:
                    pass

            # Re-assert the X11 keyboard/pointer grab about once a second.
            # If another client or the compositor steals the grab, window
            # manager shortcuts (Super, Alt+Tab, Print Screen) would start
            # working again; this pulls them back.  It is a no-op off X11.
            self._grab_ticks += 1
            if self._grab_ticks >= 25:
                self._grab_ticks = 0
                self._grab_keyboard()
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
        self._release_keyboard()
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
        for rec in self.windows:
            try:
                rec.window.destroy()
            except Exception:
                pass
        self.windows = []
        self.window = None
        self.area = None
        try:
            self.app.quit()
        except Exception:
            pass

    def _on_shutdown(self, app):
        self._release_keyboard()
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
