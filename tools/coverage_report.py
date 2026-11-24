#!/usr/bin/env python3
"""coverage_report.py —— 生成「二进制 vs 源码」还原度矩阵（Markdown）

判定规则：
  explicit : 源码里有显式方法定义（-/+ (类型)sel…
  property : 由属性自动合成（@property/getter-setter），二进制里也存在同名访问器
  auto     : .cxx_destruct 之类由编译器生成
  missing  : 以上都不是 → 真实缺口
"""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
GT_PATH = os.path.join(HERE, '..', 'ground_truth.json')
if not os.path.exists(GT_PATH):
    GT_PATH = os.path.join(HERE, 'ground_truth.json')
GT = json.load(open(GT_PATH))
SRC = os.path.join(os.path.dirname(__file__), '..', 'src')

impl_text = {}
props = {}
for base, _, names in os.walk(SRC):
    for n in names:
        if not n.endswith(('.m', '.h')):
            continue
        p = os.path.join(base, n)
        t = open(p, errors='ignore').read()
        for m in re.finditer(r'@implementation\s+(\w+)', t):
            impl_text.setdefault(m.group(1), [])
            impl_text[m.group(1)].append((p, t))
        for m in re.finditer(r'@interface\s+(\w+)', t):
            props.setdefault(m.group(1), [])
            props[m.group(1)].append(t)   # 整段头文件，用于块属性/访问器声明匹配


def sel_regex(sel):
    if ':' in sel:
        first = sel.split(':')[0]
        return re.compile(r'[-+]\s*\([^)]*\)\s*' + re.escape(first) + r'\s*:\s*\(')
    return re.compile(r'[-+]\s*\([^)]*\)\s*' + re.escape(sel) + r'\s*[{\n;]')


rows = []
for cls, e in sorted(GT.items()):
    if not cls.startswith(('PD', 'WN')):
        continue
    texts = '\n'.join(t for _, t in impl_text.get(cls, []))
    files = sorted({os.path.relpath(p, SRC) for p, _ in impl_text.get(cls, [])})
    ex = prop = auto = miss = 0
    missing_sels = []
    for m in e['methods']:
        sel = m['sel']
        if sel == '.cxx_destruct':
            auto += 1
            continue
        if texts and sel_regex(sel).search(texts):
            ex += 1
            continue
        hdr = '\n'.join(props.get(cls, []))
        base_sel = sel.rstrip(':')
        prop_name = None
        if sel.startswith('set') and sel.endswith(':') and len(sel) > 5:
            prop_name = sel[3:4].lower() + sel[4:-1]
        elif sel.startswith('is') and len(sel) > 3 and sel[2:3].isupper():
            prop_name = sel[2:3].lower() + sel[3:]
        candidate_names = [n for n in (base_sel, prop_name) if n]
        hit_prop = False
        for nm in candidate_names:
            if re.search(r'@property[^;]*\b' + re.escape(nm) + r'\b[^;]*;', hdr, re.S):
                hit_prop = True
                break
        if hit_prop:
            prop += 1
            continue
        if texts:
            miss += 1
            missing_sels.append(sel)
    rows.append(dict(cls=cls, total=len(e['methods']), ex=ex, prop=prop, auto=auto,
                     miss=miss, missing=missing_sels, files=files))

tot = sum(r['total'] for r in rows)
ex = sum(r['ex'] for r in rows)
pr = sum(r['prop'] for r in rows)
au = sum(r['auto'] for r in rows)
mi = sum(r['miss'] for r in rows)

out = []
out.append('| 类 | 二进制方法 | 显式 | 属性合成 | 编译器 | 缺失 | 源码文件 |')
out.append('|---|---|---|---|---|---|---|')
for r in sorted(rows, key=lambda x: -x['miss']):
    out.append('| `%s` | %d | %d | %d | %d | %d | %s |' % (
        r['cls'], r['total'], r['ex'], r['prop'], r['auto'], r['miss'],
        ', '.join(os.path.basename(f) for f in r['files']) or '—'))
out.append('')
out.append('**合计**：%d 个方法；显式 %d（%.1f%%）、属性合成 %d、编译器生成 %d、缺失 %d（%.1f%%）'
           % (tot, ex, ex * 100.0 / tot, pr, au, mi, mi * 100.0 / tot))
out.append('')
out.append('### 仍缺失的选择器（按类）')
out.append('')
for r in sorted(rows, key=lambda x: -x['miss']):
    if r['missing']:
        out.append('- `%s`（%d）：%s' % (r['cls'], r['miss'], ', '.join('`%s`' % s for s in r['missing'])))
print('\n'.join(out))
