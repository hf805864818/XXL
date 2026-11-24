#!/usr/bin/env python3
"""dedupe_methods.py —— 主 @implementation 与分类文件重复定义同一方法时，
把主文件里那份用 #if 0 包起来（不删除，可随时恢复），并注明真实生效的那份在哪。

原因：ObjC 分类会覆盖主类同名方法，所以主文件里的版本永远不生效——
对"可编辑源码"来说这是陷阱：改了没反应。
"""
import os, re, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
SRC = os.path.join(ROOT, 'src')


def lex_strip(src):
    out = []
    i, n = 0, len(src)
    state = None
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ''
        if state is None:
            if c == '/' and nxt == '/':
                state = 'line'; out.append('  '); i += 2; continue
            if c == '/' and nxt == '*':
                state = 'block'; out.append('  '); i += 2; continue
            if c == '"':
                state = 'str'; out.append(' '); i += 1; continue
            if c == "'":
                state = 'chr'; out.append(' '); i += 1; continue
            out.append(c); i += 1
        elif state == 'line':
            out.append('\n' if c == '\n' else ' ')
            if c == '\n': state = None
            i += 1
        elif state == 'block':
            if c == '*' and nxt == '/':
                state = None; out.append('  '); i += 2; continue
            out.append('\n' if c == '\n' else ' '); i += 1
        else:
            if c == '\\':
                out.append('  '); i += 2; continue
            if (state == 'str' and c == '"') or (state == 'chr' and c == "'"):
                state = None; out.append(' '); i += 1; continue
            out.append('\n' if c == '\n' else ' '); i += 1
    return ''.join(out)


def scan(path):
    """返回 (源码, [(类名, 分类名或'', 选择器, 起, 止)])"""
    src = open(path, errors='ignore').read()
    masked = lex_strip(src)
    results = []
    regions = []      # (cls, cat, start, end)
    for m in re.finditer(r'@implementation\s+(\w+)(?:\s*\((\w*)\))?', masked):
        em = re.search(r'@end\b', masked[m.end():])
        regions.append((m.group(1), m.group(2) or '', m.end(),
                        m.end() + (em.start() if em else len(masked) - m.end())))
    for cls, cat, a, b in regions:
        seg = masked[a:b]
        pos_of_line = {}
        for lm in re.finditer(r'^[-+]', seg, re.M):
            pos_of_line[a + lm.start()] = True
        starts = sorted(pos_of_line)
        for k, s in enumerate(starts):
            limit = starts[k + 1] if k + 1 < len(starts) else b
            brace = masked.find('{', s, limit)
            if brace < 0:
                continue
            sig = masked[s:brace]
            parts = re.findall(r'([A-Za-z_]\w*)\s*:', sig)
            if parts:
                sel = ''.join(p + ':' for p in parts)
            else:
                mm = re.search(r'\)\s*([A-Za-z_]\w*)', sig)
                if not mm:
                    continue
                sel = mm.group(1)
            depth = 0
            i = brace
            while i < b:
                ch = masked[i]
                if ch == '{':
                    depth += 1
                elif ch == '}':
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            results.append((cls, cat, sel, s, i + 1))
    return src, results


def main():
    changed = 0
    per_file = {}
    for base, _, names in os.walk(SRC):
        for n in sorted(names):
            if not n.endswith('.m'):
                continue
            p = os.path.join(base, n)
            src, defs = scan(p)
            cats = {}
            for cls, cat, sel, s, e in defs:
                if cat:
                    cats.setdefault((cls, sel), []).append((os.path.basename(p), s))
            per_file[p] = (src, defs, cats)

    for p, (src, defs, _c) in per_file.items():
        allcats = {}
        for q, (_s, _d, c) in per_file.items():
            for k, v in c.items():
                allcats.setdefault(k, []).extend(v)
        inserts = []
        for cls, cat, sel, s, e in defs:
            if cat:
                continue
            key = (cls, sel)
            if key not in allcats:
                continue
            where = allcats[key][0][0]
            inserts.append((s, e, where))
        if not inserts:
            continue
        inserts.sort(reverse=True)
        out = src
        for s, e, where in inserts:
            block = out[s:e]
            wrapped = ('#if 0  // 已被分类里的同名方法覆盖（真正生效的是 %s），改写请去那边\n'
                       % where) + block + '\n#endif'
            out = out[:s] + wrapped + out[e:]
            changed += 1
        open(p, 'w').write(out)
        print('%s: 包裹 %d 个重复方法' % (os.path.relpath(p, ROOT), len(inserts)))
    print('合计处理 %d 个' % changed)


if __name__ == '__main__':
    main()
