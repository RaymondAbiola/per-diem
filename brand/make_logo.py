#!/usr/bin/env python3
"""Render the PerDiem wordmark exactly as the dashboard draws it.

Same face (Archivo Bold), same tracking (-0.03em), same colours as the page tokens, so
the submission logo and the site are visibly one thing. Needs Archivo installed; the repo
pulls it from Google Fonts at runtime, this script needs it locally in ~/.fonts.
"""

import cairo

# page tokens
LIGHT_BG = (0xF4 / 255, 0xF6 / 255, 0xF9 / 255)
LIGHT_INK = (0x10 / 255, 0x16 / 255, 0x20 / 255)
LIGHT_ACCENT = (0x2A / 255, 0x78 / 255, 0xD6 / 255)
DARK_BG = (0x0C / 255, 0x0F / 255, 0x14 / 255)
DARK_INK = (0xEE / 255, 0xF2 / 255, 0xF8 / 255)
DARK_ACCENT = (0x39 / 255, 0x87 / 255, 0xE5 / 255)

WORD = "PerDiem"
TRACKING = -0.03  # em, matching .wordmark letter-spacing


def tracked_width(c, text, spacing):
    adv = [c.text_extents(ch).x_advance for ch in text]
    return sum(adv) + spacing * (len(text) - 1), adv


def draw_tracked(c, x, y, text, spacing, adv):
    for ch, a in zip(text, adv):
        c.move_to(x, y)
        c.show_text(ch)
        x += a + spacing


def wordmark(path, w, h, bg, ink, accent, fill=0.78, rule=True):
    s = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h)
    c = cairo.Context(s)
    if bg is not None:
        c.set_source_rgb(*bg)
        c.paint()

    c.select_font_face("Archivo", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)

    # size the type so the tracked word fills the requested fraction of the width
    target = w * fill
    size = 100.0
    for _ in range(40):
        c.set_font_size(size)
        tw, _adv = tracked_width(c, WORD, TRACKING * size)
        if abs(tw - target) < 0.5:
            break
        size *= target / tw
    c.set_font_size(size)
    tw, adv = tracked_width(c, WORD, TRACKING * size)

    ext = c.text_extents(WORD)
    # Centre on the inked bounds, not the sum of advances. The last glyph's right side
    # bearing is not ink, so centring on advances leaves the word sitting slightly left
    # and the rule underneath looks misaligned against it.
    last = c.text_extents(WORD[-1])
    inked = tw - (last.x_advance - (last.x_bearing + last.width))
    left = (w - inked) / 2 - ext.x_bearing

    # centre on cap height rather than the full em box, so it looks optically centred
    baseline = h / 2 + ext.height / 2 - (0 if not rule else size * 0.11)

    c.set_source_rgb(*ink)
    draw_tracked(c, left, baseline, WORD, TRACKING * size, adv)

    if rule:
        rw = inked * 0.34
        rh = max(3, round(size * 0.055))
        rx = left + ext.x_bearing + (inked - rw) / 2
        ry = baseline + size * 0.26
        c.set_source_rgb(*accent)
        c.rectangle(rx, ry, rw, rh)
        c.fill()

    s.write_to_png(path)
    return size


if __name__ == "__main__":
    out = __file__.rsplit("/", 1)[0]
    jobs = [
        ("logo-square-dark.png", 1000, 1000, DARK_BG, DARK_INK, DARK_ACCENT, 0.84, True),
        ("logo-square-light.png", 1000, 1000, LIGHT_BG, LIGHT_INK, LIGHT_ACCENT, 0.84, True),
        ("logo-wide-dark.png", 1600, 500, DARK_BG, DARK_INK, DARK_ACCENT, 0.62, False),
        ("logo-wide-light.png", 1600, 500, LIGHT_BG, LIGHT_INK, LIGHT_ACCENT, 0.62, False),
        ("logo-transparent-dark-text.png", 1600, 500, None, LIGHT_INK, LIGHT_ACCENT, 0.62, False),
        ("logo-transparent-light-text.png", 1600, 500, None, DARK_INK, DARK_ACCENT, 0.62, False),
    ]
    for name, w, h, bg, ink, accent, fill, rule in jobs:
        pt = wordmark(f"{out}/{name}", w, h, bg, ink, accent, fill, rule)
        print(f"  {name:34s} {w}x{h}  type {pt:.0f}px")
