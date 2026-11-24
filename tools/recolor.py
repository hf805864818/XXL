#!/usr/bin/env python3
"""recolor.py —— 发色算法离线镜像（与 PDHairTint.m 同一套 HSV 规则）

用途：
  1) 在电脑上先看效果，再决定要不要刷到设备；
  2) 批量导出「预设色板」对照图；
  3) 校验某个部件到底会不会被染（近黑线稿 / 纯白高光会被跳过）。

算法（和 ObjC 里逐字一致）：
  h' = 目标色相
  s' = sat 系数 S * (0.45 + 0.85 * s_原)
  v' = v_原 * V 乘子
  混合：out = orig + (recolored - orig) * strength
  保护：v < 0.10 且 s < 0.35 的像素原样保留（线稿）
        v > 0.985 且 s < 0.04 的像素原样保留（高光）

用法：
  python3 recolor.py -i originals/tex/hair_back.png -o /tmp/hair_pink.png --hue 330 --sat 55
  python3 recolor.py --palette originals/tex/hair_back.png --out /tmp/palette.png
  python3 recolor.py -i originals/tex/hair_back.png --parts-with-presets --outdir /tmp/hair
"""
import argparse, os, sys, colorsys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pd_png import read_png, write_png

PRESETS = {
    'sakura': (0xFF, 0xB3, 0xD1),
    'mint': (0x8F, 0xE3, 0xC4),
    'sky': (0x8F, 0xC7, 0xFF),
    'lavender': (0xC4, 0xA7, 0xFF),
    'amber': (0xFF, 0xC6, 0x61),
    'scarlet': (0xFF, 0x6B, 0x6B),
    'silver': (0xD8, 0xDE, 0xE9),
    'ink': (0x2E, 0x34, 0x40),
    'matcha': (0xA8, 0xC9, 0x7F),
    'peach': (0xFF, 0xB3, 0x8A),
}


def hsv_of_rgb(r, g, b):
    return colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)


def recolor_rgba(rgba, hue, sat, value, strength, smooth=True):
    """hue: 0..360, sat: 0..1, value: 0.4..1.6, strength: 0..1"""
    out = bytearray(rgba)
    th, ts, tv = hue, sat, value
    for i in range(0, len(out), 4):
        a = out[i + 3]
        if a == 0:
            continue
        r, g, b = out[i], out[i + 1], out[i + 2]
        h, s, v = hsv_of_rgb(r, g, b)
        if smooth and v < 0.10 and s < 0.35:
            continue
        if smooth and v > 0.985 and s < 0.04:
            continue
        nv = min(1.0, max(0.0, v * tv))
        ns = min(1.0, max(0.0, ts * (0.45 + 0.85 * s)))
        nr, ng, nb = colorsys.hsv_to_rgb(th / 360.0, ns, nv)
        nr = (r / 255.0) + (nr - (r / 255.0)) * strength
        ng = (g / 255.0) + (ng - (g / 255.0)) * strength
        nb = (b / 255.0) + (nb - (b / 255.0)) * strength
        out[i] = int(round(min(1.0, max(0.0, nr)) * 255))
        out[i + 1] = int(round(min(1.0, max(0.0, ng)) * 255))
        out[i + 2] = int(round(min(1.0, max(0.0, nb)) * 255))
    return out


def make_palette(src, out_path, cell_w=None):
    """把 10 个预设并排画成一张对照图（源图的 alpha 当遮罩）。"""
    w, h, rgba = read_png(src)
    cell = cell_w or w
    names = list(PRESETS.keys())
    W, H = cell * len(names), h
    canvas = bytearray(W * H * 4)
    for idx, name in enumerate(names):
        r, g, b = PRESETS[name]
        hh, ss, vv = hsv_of_rgb(r, g, b)
        tinted = recolor_rgba(rgba, hh * 360.0, ss, 1.0, 1.0)
        x0 = idx * cell
        for y in range(h):
            srow = y * w * 4
            drow = (y * W + x0) * 4
            canvas[drow:drow + w * 4] = tinted[srow:srow + w * 4]
    write_png(out_path, W, H, canvas)
    return out_path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-i', '--input')
    ap.add_argument('-o', '--out')
    ap.add_argument('--hue', type=float, default=330.0)
    ap.add_argument('--sat', type=float, default=55.0)
    ap.add_argument('--value', type=float, default=100.0)
    ap.add_argument('--strength', type=float, default=100.0)
    ap.add_argument('--preset', choices=sorted(PRESETS.keys()))
    ap.add_argument('--no-smooth', action='store_true')
    ap.add_argument('--palette', metavar='SRC')
    ap.add_argument('--palette-out', default='palette.png')
    ap.add_argument('--outdir')
    args = ap.parse_args()

    if args.palette:
        print(make_palette(args.palette, args.palette_out))
        return

    if not args.input or not args.out:
        ap.error('-i and -o are required (or use --palette)')

    hue, sat, val = args.hue, args.sat / 100.0, args.value / 100.0
    if args.preset:
        r, g, b = PRESETS[args.preset]
        hh, ss, vv = hsv_of_rgb(r, g, b)
        hue, sat, val = hh * 360.0, ss, max(vv, 0.4)

    w, h, rgba = read_png(args.input)
    out = recolor_rgba(rgba, hue, sat, val, args.strength / 100.0, not args.no_smooth)
    size = write_png(args.out, w, h, out)
    print('%s -> %s  %dx%d  %d bytes  H=%.0f S=%.0f%% V=%.0f%% str=%.0f%%'
          % (args.input, args.out, w, h, size, hue, sat * 100, val * 100, args.strength))


if __name__ == '__main__':
    main()
