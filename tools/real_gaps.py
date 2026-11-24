#!/usr/bin/env python3
"""real_gaps.py —— 只找「真的缺逻辑」的方法

判据：二进制里该方法的**不同选择器数量** vs 源码方法体里出现的调用片段数量。
  · 属性写法 / KVC / 包装器会造成 ±10~20% 差异 → 可接受
  · 二进制调 20 种、源码只出现 3 种 → 明显漏了逻辑

输出：ratio 升序（最缺的在前），带二进制侧的选择器列表（方便直接补）
"""
import json, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import call_coverage as cc
from disasm_annot import Ctx

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
GT = json.load(open(os.path.join(ROOT, 'ground_truth.json')))
BIN = os.environ.get('PETDFY_BIN') or os.path.abspath(os.path.join(
    ROOT, '..', 'petdfy_re', 'deb_raw', 'data', 'Library',
    'MobileSubstrate', 'DynamicLibraries', 'PetDFY.dylib'))

ctx = Ctx(BIN)
bodies = cc.source_bodies()
all_imps = sorted({m['imp'] for e in GT.values() for m in e.get('methods', []) if m['imp']})
bounds = {a: (all_imps[i + 1] if i + 1 < len(all_imps) else None) for i, a in enumerate(all_imps)}

rows = []
for cls, e in GT.items():
    if not cls.startswith(('PD', 'WN')):
        continue
    for m in e['methods']:
        sel = m['sel']
        if sel == '.cxx_destruct':
            continue
        body = bodies.get((cls, sel))
        if not body:
            continue
        sels, syms, strs = cc.method_evidence(ctx, m['imp'], bounds.get(m['imp']))
        bsels = [s for s in sels if s not in cc.NOISE_SEL]
        if len(bsels) < 6:
            continue
        text = body[0]
        # 源码侧：数「消息发送片段」和「属性访问」的去重数量
        toks = set(re.findall(r'\[\s*[A-Za-z_][\w.\[\]]*\s+([A-Za-z_]\w*)', text))
        toks |= set(re.findall(r'[.\s]([A-Za-z_]\w*)\s*=', text))
        toks |= set(re.findall(r'@selector\(([A-Za-z_]\w*)', text))
        have = set()
        for s in bsels:
            head = s.split(':')[0]
            if any(head == t or s.startswith(t) for t in toks):
                have.add(s)
        ratio = len(have) / float(len(bsels))
        if ratio < 0.65:
            rows.append((ratio, len(bsels), cls, sel, sorted(set(bsels) - have),
                         body[1]))

rows.sort(key=lambda r: (r[0], -r[1]))
print('# 真正缺逻辑的方法（按缺失比例排序）')
print()
print('判据：二进制里不同选择器数量 vs 源码里实际出现的调用/赋值片段。')
print('属性写法、KVC、包装器会造成 ±20% 差异，因此只列 < 65% 的。')
print()
print('**合计 %d 个方法。**' % len(rows))
print()
print('| 命中率 | 二进制选择器数 | 类 | 方法 | 源码文件 |')
print('|---|---|---|---|---|')
for ratio, n, cls, sel, miss, is_cat in rows:
    print('| %.0f%% | %d | `%s` | `%s` | %s |' % (ratio * 100, n, cls, sel,
                                                   '分类' if is_cat else '主文件'))
print()
print('## 逐条待补（前 20 个）')
for ratio, n, cls, sel, miss, is_cat in rows[:20]:
    print()
    print('### `-[%s %s]`  %.0f%% (%d 个选择器)' % (cls, sel, ratio * 100, n))
    print('```')
    for s in miss[:24]:
        print(s)
    print('```')
