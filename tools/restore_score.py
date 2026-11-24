#!/usr/bin/env python3
"""restore_score.py —— 按「指令数加权」估算还原度

口径（可复核，不含主观打分）：
  · 权重 = 该方法在二进制里的指令条数（capstone 实测）
  · 有效实现 = 若分类里有同名方法，取分类那份（运行时分类覆盖主类）
  · 判为「近似/桩」 = 源码有效实现 ≤ 2 行语句 且 二进制 ≥ 40 条指令
  · 判为「访问器」 = @property 合成，二进制里通常 < 12 条指令
  · 语义还原度 = (总指令 - 近似桩指令) / (总指令 - 纯访问器指令)
"""
import json, os, re, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..'))
sys.path.insert(0, HERE)
from dedupe_methods import lex_strip, scan as scan_methods

GT = json.load(open(os.path.join(ROOT, 'ground_truth.json')))
BIN = os.environ.get('PETDFY_BIN', os.path.join(
    ROOT, '..', 'petdfy_re', 'deb_raw', 'data', 'Library',
    'MobileSubstrate', 'DynamicLibraries', 'PetDFY.dylib'))

# ---------- 1) 反汇编取指令数 ----------
import struct
data = open(BIN, 'rb').read()
base = 16384 if struct.unpack('>I', data[:4])[0] == 0xcafebabe else 0
macho = data[base:]
ncmds = struct.unpack('<I', macho[16:20])[0]
off, text_off, text_addr, text_size = 32, None, None, None
for _ in range(ncmds):
    cmd, size = struct.unpack('<II', macho[off:off + 8])
    if cmd == 0x19:
        nsec = struct.unpack('<I', macho[off + 64:off + 68])[0]
        so = off + 72
        for _i in range(nsec):
            if macho[so:so + 16].rstrip(b'\x00') == b'__text':
                text_addr, text_size = struct.unpack('<QQ', macho[so + 32:so + 48])
                text_off = struct.unpack('<I', macho[so + 48:so + 52])[0]
            so += 80
    off += size
text = macho[text_off:text_off + text_size]
md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
md.detail = True

starts = {}
for cls, e in GT.items():
    if not cls.startswith(('PD', 'WN')):
        continue
    for m in e['methods']:
        starts.setdefault(m['imp'], []).append((cls, m['sel'], m['types']))

addrs = sorted(a for a in starts if a)
insns = {}
for i, a in enumerate(addrs):
    end = addrs[i + 1] if i + 1 < len(addrs) else text_addr + text_size
    rel = a - text_addr
    if rel < 0 or rel >= len(text):
        continue
    # 函数结束判定：
    #   ret / retaa / retab 之后若紧跟 0x00 或 nop(0xD503201F) → 函数结束
    #   无条件 b 且目标落在本函数区间外 → 尾调用，结束
    n = 0
    blob = text[rel:rel + min(end - a, 8192)]
    for ins in md.disasm(blob, a):
        n += 1
        off_next = ins.address - a + ins.size
        tail = blob[off_next: off_next + 8]
        padded = (not tail) or tail[:4] == b'\x00\x00\x00\x00' or tail[:4] == b'\x1f\x20\x03\xd5'
        if ins.mnemonic in ('ret', 'retaa', 'retab') and padded:
            break
        if ins.mnemonic == 'b' and ins.operands:
            try:
                tgt = ins.operands[0].imm
            except Exception:
                tgt = None
            if tgt is not None and not (a <= tgt < end):
                break
        if n > 4000:
            break
    insns[a] = n

# ---------- 2) 源码里每个方法的有效实现行数 ----------
bodies = {}
for b, _, names in os.walk(os.path.join(ROOT, 'src')):
    for n in names:
        if not n.endswith('.m'):
            continue
        p = os.path.join(b, n)
        src, defs = scan_methods(p)
        masked = lex_strip(src)
        for cls, cat, sel, s, e in defs:
            body = masked[s:e]
            lines = [l for l in body.split('\n')
                     if l.strip() and l.strip() not in ('{', '}')
                     and not l.strip().startswith('//')]
            prev = bodies.get((cls, sel))
            # 分类优先
            if prev is None or (cat and not prev[1]):
                bodies[(cls, sel)] = (len(lines), bool(cat), os.path.basename(p))

# ---------- 3) 归类与打分 ----------
SUBSYS = [
    ('渲染引擎 WN*', lambda c: c.startswith('WN')),
    ('桌宠宿主/交互', lambda c: c in ('PDPetView', 'PDOverlayController', 'PDWindow', 'PDRootController',
                                     'PDInteractionView', 'PDHostRootView', 'PDKeyboardMonitor',
                                     'PDActiveInterfaceOrientationMonitor', 'PDLocalizationBundle',
                                     'PDSoundPlayer', 'PDPreferences', 'PDAssetManager')),
    ('AI 对话/语音/设备工具', lambda c: c.startswith(('PDChat', 'PDDevice', 'PDVoice', 'PDDoubao',
                                                      'PDAI', 'PDNative', 'PDReplySpeech',
                                                      'PDCloudVoiceInput', 'PDSpeechBubbleView',
                                                      'PDComposerTextView'))),
]

rows = {}
detail = []
for a, lst in starts.items():
    n = insns.get(a, 0)
    for cls, sel, types in lst:
        key = (cls, sel)
        lines, is_cat, fname = bodies.get(key, (None, False, None))
        total_types = len(types or '')
        if sel in ('.cxx_destruct', 'dealloc') and lines is None:
            continue
        # 访问器判定：属性合成（源码没有方法体）+ 指令很少
        is_accessor = lines is None and n <= 14
        # 三档阈值：源码行数明显不足以承载这么多指令 → 判近似
        thin = False
        if lines is not None:
            if lines <= 2 and n >= 40:
                thin = True
            elif n >= 60 and lines <= 6:
                thin = True
            elif n >= 100 and lines <= 10:
                thin = True
            elif lines > 0 and (n / float(lines)) >= 14:
                thin = True
        if is_accessor:
            kind = 'accessor'
        elif lines is None:
            kind = 'nobody'      # 源码里没有（理论上不该有，方法级 100% 已覆盖）
        elif thin:
            kind = 'thin'
        else:
            kind = 'body'
        sub = '其他'
        for name, pred in SUBSYS:
            if pred(cls):
                sub = name
                break
        r = rows.setdefault(sub, dict(cls=set(), methods=0, insns=0, acc_insns=0,
                                      thin=0, thin_insns=0, nobody=0, nobody_insns=0))
        r['cls'].add(cls)
        r['methods'] += 1
        r['insns'] += n
        if kind == 'accessor':
            r['acc_insns'] += n
        elif kind == 'thin':
            r['thin'] += 1
            r['thin_insns'] += n
            detail.append((n, cls, sel, lines, fname))
        elif kind == 'nobody':
            r['nobody'] += 1
            r['nobody_insns'] += n
            detail.append((n, cls, sel, 'NO BODY', fname))

def pct(r):
    denom = r['insns'] - r['acc_insns']
    if denom <= 0:
        return 100.0
    return 100.0 * (denom - r['thin_insns'] - r['nobody_insns']) / denom

print('| 子系统 | 类 | 方法 | 指令总数 | 纯访问器指令 | 近似/桩 | 指令加权还原度 |')
print('|---|---|---|---|---|---|---|')
tot = dict(insns=0, acc=0, thin=0, nobody=0, methods=0)
for sub in [s[0] for s in SUBSYS] + ['其他']:
    r = rows.get(sub)
    if not r:
        continue
    print('| %s | %d | %d | %d | %d | %d | **%.1f%%** |' % (
        sub, len(r['cls']), r['methods'], r['insns'], r['acc_insns'], r['thin'] + r['nobody'], pct(r)))
    for k, kk in (('insns', 'insns'), ('acc_insns', 'acc'), ('thin_insns', 'thin'), ('nobody_insns', 'nobody')):
        tot[kk] += r[k]
    tot['methods'] += r['methods']

denom = tot['insns'] - tot['acc']
overall = 100.0 * (denom - tot['thin'] - tot['nobody']) / denom
print('| **合计** | 54 | %d | %d | %d | — | **%.1f%%** |' % (tot['methods'], tot['insns'], tot['acc'], overall))
print()
print('指令加权还原度 = %.1f%%（分母 = 非访问器指令 %d 条）' % (overall, denom))
print()
print('### 判为“近似/桩”的方法（%d 个）' % len(detail))
print('| 指令 | 类 | 方法 | 源码行数 | 文件 |')
print('|---|---|---|---|---|')
for n, cls, sel, lines, fname in sorted(detail, reverse=True)[:20]:
    print('| %d | `%s` | `%s` | %s | %s |' % (n, cls, sel, lines, fname or '—'))
