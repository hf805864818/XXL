#!/usr/bin/env python3
"""validate_assets.py —— 素材完整性体检

检查项（都对应运行时真实会踩的坑）：
  1. 每套服装的每个部件都能解析到 PNG（候选链与 PDTextureResolver 一致）
  2. PNG 必须是 8bit RGBA（Metal 端按 RGBA8 加载；别存成调色板 PNG）
  3. 部件 id 重复会让 z 排序与命中蒙版错乱
  4. 缩略图缺失（设置里会显示空白）
  5. 主题包 schemes/<x>/ 有没有整体缺 tex/feat
  6. 发色可染部件是否齐全（少一张头发贴图 = 换色后秃一块）

用法：
  python3 tools/validate_assets.py --root assets_src
  python3 tools/validate_assets.py --root "/Library/Application Support/PetDFY.bundle"
"""
import argparse, json, os, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pd_png import read_png

DEFAULT_OUTFITS = ['maid', 'cape', 'crew', 'sailor']
RUNTIME_PARTS = {'faceFx', '__face'}   # 运行时合成，包里本来就没有 PNG
HAIR_IDS = ['hair_back', 'hair_back_curl', 'hair_front_left', 'hair_front_right',
            'sidelocks', 'bangs', 'ahoge', 'tail']


def load_json(p):
    try:
        with open(p, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception as e:
        return {'__error__': str(e)}


def scheme_root(scheme):
    return 'originals' if scheme in (None, '', 'deepseek') else os.path.join('schemes', scheme)


def candidates(root, scheme, outfit, part):
    """与 PDTextureResolver.texturePathForPart: 同序（两级根：主题根 → originals/）"""
    tex = part.get('tex') or part.get('id')
    src = part.get('src')
    roots = [scheme_root(scheme), 'originals']
    out = []
    if src:
        for r in roots:
            out.append(os.path.join(r, src))
        out.append(src)
    for r in roots:
        out += [
            os.path.join(r, 'tex', tex + '.png'),
            os.path.join(r, 'outfits', outfit, tex + '.png'),
            os.path.join(r, 'outfits', outfit, 'tex', tex + '.png'),
            os.path.join(r, 'feat', tex + '.png'),
        ]
    return out


def resolve(root, scheme, outfit, part):
    for rel in candidates(root, scheme, outfit, part):
        if os.path.exists(os.path.join(root, rel)):
            return rel
    return None


def check_png(path):
    with open(path, 'rb') as f:
        head = f.read(29)
    if head[:8] != b'\x89PNG\r\n\x1a\n':
        return 'not PNG'
    w, h, bd, ct, _, _, il = struct.unpack('>IIBBBBB', head[16:29])
    if bd != 8:
        return 'bitdepth=%d（需要 8）' % bd
    if ct not in (6, 2, 0, 4, 3):
        return 'colortype=%d 无法解析' % ct
    if ct != 6:
        return 'colortype=%d（建议 RGBA=6，否则 alpha 语义可能丢）' % ct
    if il != 0:
        return 'interlaced'
    if w == 0 or h == 0:
        return 'zero size'
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default='assets_src')
    ap.add_argument('--scheme', default=None, help='只检查某个主题')
    a = ap.parse_args()
    root = a.root

    problems = 0
    print('== 素材根：%s' % os.path.abspath(root))

    # ---- 模型 ----
    live_path = os.path.join(root, 'live/model.json')
    live = load_json(live_path) if os.path.exists(live_path) else {}
    models = live.get('models', {}) if isinstance(live, dict) else {}

    outfits = list(models.keys()) or DEFAULT_OUTFITS
    def _schemes_dir():
        for cand in (os.path.join(root, 'schemes'), os.path.join(root, 'originals', 'schemes')):
            if os.path.isdir(cand):
                return cand
        return None

    sd = _schemes_dir()
    scheme_names = sorted(d for d in os.listdir(sd)
                          if os.path.isdir(os.path.join(sd, d))) if sd else []
    schemes = [a.scheme] if a.scheme else (['deepseek'] + scheme_names)

    print('\n== 服装：%s' % ', '.join(outfits))
    print('== 主题：%s' % ', '.join(schemes))

    for outfit in outfits:
        parts = (models.get(outfit) or {}).get('parts')
        if parts is None:
            print('\n[%s] 只存在于磁盘，没有 model 定义（轻量新服装，可接受）' % outfit)
            parts = []
        ids = [p.get('id') for p in parts]
        dup = sorted({i for i in ids if ids.count(i) > 1})
        if dup:
            problems += 1
            print('  ✗ 重复部件 id：%s' % dup)
        for scheme in schemes:
            missing = []
            bad = []
            for p in parts:
                pid = p.get('id')
                rel = resolve(root, scheme, outfit, p)
                if not rel:
                    if pid not in RUNTIME_PARTS:
                        missing.append(pid)
                    continue
                err = check_png(os.path.join(root, rel))
                if err:
                    bad.append('%s(%s)' % (p.get('id'), err))
            tag = '✓' if not missing and not bad else '✗'
            if missing or bad:
                problems += 1
            print('  %s %-8s × %-10s 部件 %2d 缺失 %d 异常 %d'
                  % (tag, outfit, scheme, len(parts), len(missing), len(bad)))
            if missing:
                print('      缺：%s' % ', '.join(str(x) for x in missing[:12]))
            if bad:
                print('      异常：%s' % ', '.join(bad[:6]))

        # 头发部件齐全性（决定发色效果是否完整）
        hair_missing = [h for h in HAIR_IDS if h not in (ids or [])]
        if parts and hair_missing:
            print('      · 该服装不含头发部件：%s（若它本来就不换头发，可忽略）'
                  % ', '.join(hair_missing))

        # 缩略图
        thumb = os.path.join(root, 'originals/thumbs', outfit + '.png')
        if not os.path.exists(thumb):
            print('      · 缩略图缺失：originals/thumbs/%s.png' % outfit)

    # ---- 发色：确认头发贴图本身可读 ----
    print('\n== 发色可用性（头发贴图）')
    for scheme in schemes:
        got = []
        for h in HAIR_IDS:
            for r in (scheme_root(scheme), 'originals'):
                if os.path.exists(os.path.join(root, r, 'tex', h + '.png')):
                    got.append(h)
                    break
        print('  %-10s 命中 %d/%d：%s' % (scheme, len(got), len(HAIR_IDS), ', '.join(got) or '无'))

    print('\n问题计数：%d' % problems)
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
