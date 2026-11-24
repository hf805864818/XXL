#!/usr/bin/env python3
"""worklist.py —— 生成「待还原清单」：按指令权重排序的缺口方法表

判定与 call_coverage 同源：
  · 二进制里用到的 selector / 导入符号 / CFString，源码方法体里没有对应 → 记为缺口
  · 权重 = 该方法在二进制里的指令条数（越重越值得先做）
"""
import json, os, sys

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
        ev = cc.method_evidence(ctx, m['imp'], bounds.get(m['imp']))
        insns = sum(1 for _ in ctx.md.disasm(ctx.read(m['imp'], 8192), m['imp'])) if False else 0
        # 指令数按 restore_score 的口径
        blob = ctx.read(m['imp'], min(8192, (bounds.get(m['imp']) or (m['imp'] + 8192)) - m['imp']))
        n = 0
        for ins in ctx.md.disasm(blob, m['imp']):
            n += 1
            if ins.mnemonic in ('ret', 'retaa', 'retab'):
                tail = blob[ins.address - m['imp'] + ins.size:
                            ins.address - m['imp'] + ins.size + 8]
                if not tail or tail[:4] == b'\x00\x00\x00\x00' or tail[:4] == b'\x1f\x20\x03\xd5':
                    break
            if n > 2000:
                break
        if not body:
            continue
        text = body[0]
        sels, syms, strs = ev
        missing = []
        for s in sels:
            if s in cc.NOISE_SEL:
                continue
            if not cc.sel_present(s, text):
                missing.append('sel:' + s)
        for s in syms:
            if cc.is_noise_symbol(s):
                continue
            if s.lstrip('_') not in text and s not in text:
                missing.append('sym:' + s)
        for s in strs:
            if s[:24] not in text:
                missing.append('str:"%s"' % s[:40])
        total_ev = len([x for x in sels if x not in cc.NOISE_SEL]) + \
                   len([x for x in syms if not cc.is_noise_symbol(x)]) + len(strs)
        ratio = (len(missing) / float(total_ev)) if total_ev else 0.0
        # 只有「缺口占比高」才算真缺口：单个日志串/包装器差异不算
        if missing and ratio >= 0.30 and len(missing) >= 3:
            rows.append((n, cls, sel, len(missing), missing, body[1], ratio))

rows.sort(reverse=True)
tot = sum(r[0] for r in rows)
print('# 待还原清单（按二进制指令数排序）')
print()
print('规则见 `tools/call_coverage.py` 与 `tools/worklist.py`：')
print('缺口 = 二进制里真实调用/引用、但源码方法体里找不到对应证据。')
print()
print('**合计 %d 个方法、%d 条指令待核。**' % (len(rows), tot))
print()
print('| # | 指令 | 类 | 方法 | 缺口项 | 来源文件 |')
print('|---|---|---|---|---|---|')
for i, (n, cls, sel, miss, missing, is_cat, ratio) in enumerate(rows, 1):
    print('| %d | %d | `%s` | `%s` | %d | %s |' % (i, n, cls, sel, miss, '分类' if is_cat else '主文件'))
print()
print('## 逐条缺口证据（前 25 个方法）')
print()
for n, cls, sel, miss, missing, is_cat, ratio in rows[:25]:
    print('### `-[%s %s]`  %d 条指令' % (cls, sel, n))
    print('```')
    for x in missing[:20]:
        print(x)
    print('```')
