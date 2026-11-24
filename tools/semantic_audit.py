#!/usr/bin/env python3
"""semantic_audit.py —— 找出「方法存在但实现是桩」的地方

做法：
  1. 用 ground_truth.json 里的 imp 地址当函数起点，按地址排序；
  2. 用 capstone 反汇编到下一个起点（或遇到 ret 后若干条），数指令条数；
  3. 对照源码里同名方法体的语句行数；
  4. 指令数 >= 阈值而源码 <= 3 行 → 判为可疑桩，输出清单。
"""
import json, os, re, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..'))
GT = json.load(open(os.path.join(ROOT, 'ground_truth.json')))
BIN = os.environ.get('PETDFY_BIN', os.path.join(
    ROOT, '..', 'petdfy_re', 'deb_raw', 'data', 'Library',
    'MobileSubstrate', 'DynamicLibraries', 'PetDFY.dylib'))
SRC = os.path.join(ROOT, 'src')

sys.path.insert(0, os.path.join(ROOT, '..', 'petdfy_re', 'tools'))
data = open(BIN, 'rb').read()

# 粗取 __text：用 otool 更稳，这里直接找段表
import struct
base = 16384 if struct.unpack('>I', data[:4])[0] == 0xcafebabe else 0
macho = data[base:]
ncmds = struct.unpack('<I', macho[16:20])[0]
off = 32
text_off = text_addr = text_size = None
for _ in range(ncmds):
    cmd, size = struct.unpack('<II', macho[off:off + 8])
    if cmd == 0x19:
        vmaddr, vmsize, fileoff, filesize = struct.unpack('<QQQQ', macho[off + 24:off + 56])
        nsects = struct.unpack('<I', macho[off + 64:off + 68])[0]
        so = off + 72
        for _i in range(nsects):
            sect = macho[so:so + 16].rstrip(b'\x00').decode()
            addr, ssize = struct.unpack('<QQ', macho[so + 32:so + 48])
            soff = struct.unpack('<I', macho[so + 48:so + 52])[0]
            if sect == '__text':
                text_off, text_addr, text_size = soff, addr, ssize
            so += 80
    off += size

assert text_off is not None
text = macho[text_off:text_off + text_size]
md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
md.detail = False

starts = {}
for cls, e in GT.items():
    if not cls.startswith(('PD', 'WN')):
        continue
    for m in e['methods']:
        starts.setdefault(m['imp'], []).append((cls, m['sel']))

addrs = sorted(starts)
counts = {}
for i, a in enumerate(addrs):
    end = addrs[i + 1] if i + 1 < len(addrs) else text_addr + text_size
    rel = a - text_addr
    if rel < 0 or rel >= len(text):
        continue
    n = 0
    for ins in md.disasm(text[rel:rel + min(end - a, 4096)], a):
        n += 1
        if n > 1200:
            break
    counts[a] = n

# 源码方法体行数（按花括号深度切分，避免多行签名/注释干扰）
bodies = {}
for base_dir, _, names in os.walk(SRC):
    for n in names:
        if not n.endswith('.m'):
            continue
        text = open(os.path.join(base_dir, n), errors='ignore').read()
        cur_cls = None
        depth = 0
        cur_key = None
        cur_lines = 0
        in_block_comment = False
        for raw in text.split('\n'):
            line = raw
            st = line.strip()
            # 注释处理
            if in_block_comment:
                if '*/' in st:
                    in_block_comment = False
                continue
            if st.startswith('/*'):
                if '*/' not in st:
                    in_block_comment = True
                continue
            m = re.match(r'@implementation\s+(\w+)', st)
            if m:
                cur_cls = m.group(1); depth = 0; cur_key = None
                continue
            m = re.match(r'@end', st)
            if m:
                cur_cls = None; cur_key = None
                continue
            if depth == 0 and cur_cls:
                m = re.match(r'^[-+]\s*\(', st)
                if m:
                    mm = re.match(r'^[-+]\s*\([^)]*\)\s*([A-Za-z_]\w*)\s*(.*)$', st)
                    if mm:
                        cur_key = (cur_cls, mm.group(1))
                        cur_lines = 0
                        bodies[cur_key] = 0
            if cur_key is not None:
                if st and not st.startswith('//') and st not in ('{', '}'):
                    cur_lines += 1
                    bodies[cur_key] = max(bodies[cur_key], cur_lines)
            depth += st.count('{') - st.count('}')
            if depth == 0 and cur_key is not None and ('}' in st):
                cur_key = None

rows = []
for a, n in counts.items():
    for cls, sel in starts[a]:
        base_sel = sel.split(':')[0]
        lines = bodies.get((cls, base_sel))
        if lines is None:
            continue
        if n >= 60 and lines <= 4:
            rows.append((n, cls, sel, lines))

rows.sort(reverse=True)
print('可疑桩（二进制指令数 ≥ 60，源码 ≤ 4 行）：%d 个' % len(rows))
print('| 指令数 | 类 | 方法 | 源码行数 |')
print('|---|---|---|---|')
for n, cls, sel, lines in rows[:40]:
    print('| %d | `%s` | `%s` | %d |' % (n, cls, sel, lines))
