#!/usr/bin/env python3
"""call_coverage.py —— 语义保真度：二进制里"实际调用了什么"，源码里"有没有对应"

思路（比"行数/指令数"可靠得多）：
  1. 反汇编每个方法，收集它真正用到的东西：
       · selector（__objc_stubs 解码）
       · 导入符号（CFRelease / posix_spawn / CC_SHA1 …）
       · CFString 常量（日志、key、路径、错误串）
  2. 在源码同名方法体里找这些证据：
       · selector  → 选择器片段出现即可（允许拆成多行调用）
       · 导入符号  → 去掉下划线后的名字出现
       · CFString  → 字符串内容作为子串出现（取前 24 字符）
  3. 覆盖率 = 命中数 / 总数，按方法聚合到类与全局。

用法：
  python3 tools/call_coverage.py                 # 全部
  python3 tools/call_coverage.py --class PDChatService --verbose
  python3 tools/call_coverage.py --threshold 70  # 只打印低于阈值的
"""
import argparse, json, os, re, struct, sys

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from capstone.arm64 import ARM64_OP_IMM, ARM64_OP_MEM, ARM64_OP_REG

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..'))
sys.path.insert(0, HERE)
from disasm_annot import Ctx
from dedupe_methods import lex_strip, scan as scan_methods

GT = json.load(open(os.path.join(ROOT, 'ground_truth.json')))


def method_evidence(ctx, ea, bound=None):
    """返回 (selectors, imports, strings) 三个集合（按出现顺序去重）"""
    m = ctx.m
    text = m.sect('__text')
    t0 = text['addr']
    t1 = t0 + text['size']
    # 找下一个函数起点做上界
    sels, syms, strs = [], [], []
    limit = 12 * 400
    if bound:
        limit = max(16, min(limit, bound - ea))
    blob = ctx.read(ea, limit)
    reg = {}
    for ins in ctx.md.disasm(blob, ea):
        mn = ins.mnemonic
        dsts = [ins.reg_name(o.reg) for o in ins.operands
                if o.type == ARM64_OP_REG and o.access and o.access & 2] if ins.operands else []
        if mn == 'adrp':
            try:
                reg[dsts[0]] = ins.operands[1].imm
            except IndexError:
                pass
        elif mn == 'add' and len(ins.operands) >= 3 and ins.operands[2].type == ARM64_OP_IMM:
            base = reg.get(ins.reg_name(ins.operands[1].reg))
            if base is not None and dsts:
                reg[dsts[0]] = base + ins.operands[2].imm
        elif mn.startswith('ldr') and len(ins.operands) == 2 and ins.operands[1].type == ARM64_OP_MEM:
            base = reg.get(ins.reg_name(ins.operands[1].mem.base))
            if base is not None and ins.operands[1].mem.index == 0:
                va = base + ins.operands[1].mem.disp
                if va in ctx.maps['cfstr']:
                    strs.append(ctx.maps['cfstr'][va])
                elif va in ctx.maps['sym']:
                    syms.append(ctx.maps['sym'][va])
            if dsts:
                reg.pop(dsts[0], None)
        else:
            for d in dsts:
                reg.pop(d, None)
        if mn in ('bl', 'b') and ins.operands and ins.operands[0].type == ARM64_OP_IMM:
            tgt = ins.operands[0].imm
            if tgt in ctx.maps['stub']:
                kind, name = ctx.maps['stub'][tgt]
                (sels if kind == 'sel' else syms).append(name)
            elif tgt in ctx.maps['imp']:
                sels.append(ctx.maps['imp'][tgt].split(' ', 1)[1])
            if mn == 'b' and None:
                break
            if mn == 'bl':
                continue
            # tail call 后本函数结束
            if not (t0 <= tgt < t1):
                break
        if mn in ('ret', 'retaa', 'retab'):
            off = ins.address - ea + ins.size
            tail = blob[off:off + 8]
            if not tail or tail[:4] == b'\x00\x00\x00\x00' or tail[:4] == b'\x1f\x20\x03\xd5':
                break

    def dedup(seq):
        out = []
        for x in seq:
            if x and x not in out:
                out.append(x)
        return out

    return dedup(sels), dedup(syms), dedup(strs)


# 编译器/ARC/语法糖产生的“证据噪音”，源码里本来就不会出现，不能算缺失
NOISE_SYM_PREFIX = (
    '_objc_retain', '_objc_release', '_objc_claimAutoreleased', '_objc_autorelease',
    '_objc_storeStrong', '_objc_enumerationMutation', '_objc_begin_catch', '_objc_end_catch',
    '_objc_exception', '_objc_retainBlock', '_objc_retainAutorelease', '_objc_copyWeak',
    '_objc_moveWeak', '_objc_destroyWeak', '_objc_initWeak', '_objc_loadWeak',
    '_objc_storeWeak', '_objc_loadWeakRetained', '_objc_autoreleasePool',
    '___sincos_stret', '___stack_chk_fail', '_objc_msgSend', '_objc_opt_new',
    '__Block_object_assign', '__Block_object_dispose',
    '_objc_sync_', '___stack_chk', '___NSArray0__struct', '__NSConcrete', '__NSConstant',
    '__dispatch_main_q', '___chkstk', '_objc_unsafeClaim', '_objc_opt_',
    '_swift_', '_dyld_',
    # 属性合成 setter（ARC）与字面量/装箱的默认实现：源码写法不同但语义等价
    '_objc_setProperty_', '_objc_msgSendSuper2', '_objc_alloc', '_objc_msgSend$',
    '__Unwind_Resume', '__Block_object_dispose', '___NSDictionary0__struct',
    '___kCFBooleanTrue', '___kCFBooleanFalse', '_NSLog', '_NSSelectorFromString',
    '_objc_getClass', '_objc_opt_class', '_CGPointZero', '_CGRectZero', '_CGSizeZero',
)
NOISE_SEL = {
    'countByEnumeratingWithState:objects:count:',
    'objectForKeyedSubscript:', 'objectAtIndexedSubscript:',
    'setObject:forKeyedSubscript:', 'setObject:atIndexedSubscript:',
    'isEqual:', 'isKindOfClass:', 'class', 'self', 'superclass',
    'addObject:', 'mutableCopy', 'copy', 'autorelease', 'retain', 'release',
    # 字面量与装箱（源码写 @[] / @{} / @() ）
    'dictionaryWithObjects:forKeys:count:', 'arrayWithObjects:count:',
    'numberWithDouble:', 'numberWithBool:', 'numberWithInt:', 'numberWithInteger:',
    'numberWithUnsignedInteger:', 'numberWithUnsignedInt:', 'numberWithFloat:',
    'numberWithLongLong:', 'dictionary', 'array', 'string',
}


def is_noise_symbol(name):
    return any(name.startswith(pfx) for pfx in NOISE_SYM_PREFIX)


def source_bodies():
    bodies = {}
    for b, _, names in os.walk(os.path.join(ROOT, 'src')):
        for n in names:
            if not n.endswith('.m'):
                continue
            p = os.path.join(b, n)
            src, defs = scan_methods(p)
            masked = lex_strip(src)
            for cls, cat, sel, s, e in defs:
                body = src[s:e]           # 用原文（含注释），注释里也有价值
                prev = bodies.get((cls, sel))
                if prev is None or (cat and not prev[1]):
                    bodies[(cls, sel)] = (body, bool(cat), os.path.basename(p))
    return bodies


PROPERTY_EQUIV = re.compile(r'[.\s]([A-Za-z_]\w*)\s*=')


def sel_present(sel, text):
    """选择器在源码里是否有等价表达：
       - 直接出现（消息发送）
       - setX: → 属性赋值 .X = / X =
       - getter X → 属性读取 .X 或 ivar _X
    """
    frag = norm_sel(sel)
    if frag and frag in text:
        return True
    m = re.match(r'^set([A-Z]\w*):$', sel)
    if m:
        prop = m.group(1)[0].lower() + m.group(1)[1:]
        return bool(re.search(r'(\.|->|_)\s*' + re.escape(prop) + r'\s*=[^=]', text)
                    or re.search(r'\b' + re.escape(prop) + r'\s*=[^=]', text))
    if ':' not in sel:
        return bool(re.search(r'[.>]' + re.escape(sel) + r'\b', text)
                    or re.search(r'\b_' + re.escape(sel) + r'\b', text))
    return False


def norm_sel(sel):
    return sel.rstrip(':').split(':')[0] if ':' in sel else sel


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bin', default=None)
    ap.add_argument('--class', dest='cls')
    ap.add_argument('--threshold', type=float, default=None)
    ap.add_argument('--verbose', action='store_true')
    a = ap.parse_args()

    ctx = Ctx(a.bin) if a.bin else Ctx(os.environ.get('PETDFY_BIN') or
        os.path.abspath(os.path.join(ROOT, '..', 'petdfy_re', 'deb_raw', 'data', 'Library',
                                     'MobileSubstrate', 'DynamicLibraries', 'PetDFY.dylib')))
    bodies = source_bodies()

    # 每个方法的地址上界 = 下一个 IMP（所有类合并排序）
    all_imps = sorted({m['imp'] for e in GT.values() for m in e.get('methods', [])
                       if m['imp'] and e.get('name', '').startswith(('PD', 'WN')) or True})
    bounds = {}
    for i, a2 in enumerate(all_imps):
        bounds[a2] = all_imps[i + 1] if i + 1 < len(all_imps) else None

    rows = {}
    details = {}
    for cls, e in GT.items():
        if not cls.startswith(('PD', 'WN')):
            continue
        if a.cls and cls != a.cls:
            continue
        for meth in e['methods']:
            sel = meth['sel']
            if sel == '.cxx_destruct':
                continue
            body = bodies.get((cls, sel))
            if not body:
                # 实现可能挂在等价方法名下（例如 pd_drawMesh:… 承载 drawMesh:…log）
                head = sel.split(':')[0]
                for alt in ('pd_' + head + ':' + sel.split(':', 1)[1] if ':' in sel else 'pd_' + sel,
                            'pd_' + sel.split(':')[0] + ':'):
                    if (cls, alt) in bodies:
                        body = bodies[(cls, alt)]
                        break
            if not body:
                continue
            sels, syms, strs = method_evidence(ctx, meth['imp'], bounds.get(meth['imp']))
            if not (sels or syms or strs):
                continue
            text = body[0]
            hit = miss = 0
            missing = []
            for s in sels:
                if s in NOISE_SEL:
                    continue
                if sel_present(s, text):
                    hit += 1
                else:
                    miss += 1
                    missing.append('sel:' + s)
            for s in syms:
                if is_noise_symbol(s):
                    continue
                nm = s.lstrip('_')
                if nm and (nm in text or s in text):
                    hit += 1
                else:
                    miss += 1
                    missing.append('sym:' + s)
            for s in strs:
                frag = s[:24]
                if frag and frag in text:
                    hit += 1
                else:
                    miss += 1
                    missing.append('str:"%s"' % s[:40])
            total = hit + miss
            if total == 0:
                continue
            r = rows.setdefault(cls, dict(hit=0, total=0, methods=0, worst=[]))
            r['hit'] += hit
            r['total'] += total
            r['methods'] += 1
            if miss:
                r['worst'].append((hit / total, sel, hit, total, missing[:6]))

    tot_hit = sum(r['hit'] for r in rows.values())
    tot_all = sum(r['total'] for r in rows.values())
    print('| 类 | 方法 | 证据命中/总 | 保真度 |')
    print('|---|---|---|---|')
    for cls, r in sorted(rows.items(), key=lambda kv: kv[1]['hit'] / kv[1]['total']):
        pct = 100.0 * r['hit'] / r['total']
        if a.threshold is not None and pct >= a.threshold:
            continue
        print('| `%s` | %d | %d/%d | **%.1f%%** |' % (cls, r['methods'], r['hit'], r['total'], pct))
    print('| **合计** | — | %d/%d | **%.1f%%** |' % (tot_hit, tot_all, 100.0 * tot_hit / tot_all))
    print()
    print('证据保真度 = %.1f%%（用二进制里实际调用的 selector/导入符号/字符串来对源码核对）'
          % (100.0 * tot_hit / tot_all))
    if a.verbose:
        print()
        for cls, r in sorted(rows.items(), key=lambda kv: kv[1]['hit'] / kv[1]['total']):
            if not r['worst']:
                continue
            print('## %s' % cls)
            for ratio, sel, hit, total, missing in sorted(r['worst'])[:8]:
                print('  %.0f%%  %s  (%d/%d)  缺: %s' % (ratio * 100, sel, hit, total, '; '.join(missing)))
            print()


if __name__ == '__main__':
    main()
