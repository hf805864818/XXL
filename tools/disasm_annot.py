#!/usr/bin/env python3
"""disasm_annot.py —— PetDFY.dylib 反汇编标注器

能力（把裸汇编变成可读逻辑）：
  · __objc_stubs 解码：`adrp x1,selref / ldr x1,[x1,#off] / br x16` →
    该 stub 就是一个"硬编码选择器的 objc_msgSend"，于是 `bl stub` 直接标出消息名
  · __auth_stubs / __stubs 解码：GOT 槽 → 导入符号（_objc_msgSend、_CFRelease …）
  · adrp+add/ldr 常量传播 → 解析 __objc_selrefs（选择器）、__cfstring（字符串）、
    __objc_classrefs（类名）、__objc_superrefs
  · imp → `-[Class sel]`：调用内部方法时直接显示类与方法名

用法：
  python3 tools/disasm_annot.py --class PDNative_AppManager --sel installApp:error:
  python3 tools/disasm_annot.py --ea 0x9c4ac --len 80
  python3 tools/disasm_annot.py --class PDChatService --list      # 列出该类所有方法与 EA
"""
import argparse, json, os, re, struct, subprocess, sys

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from capstone.arm64 import ARM64_OP_REG, ARM64_OP_IMM, ARM64_OP_MEM

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..'))
BIN = os.environ.get('PETDFY_BIN', os.path.abspath(os.path.join(
    ROOT, '..', 'petdfy_re', 'deb_raw', 'data', 'Library',
    'MobileSubstrate', 'DynamicLibraries', 'PetDFY.dylib')))

sys.path.insert(0, HERE)
from macho_objc import MachO           # noqa: E402


class Ctx:
    def __init__(self, path):
        self.path = path
        self.m = MachO(path)
        self.data = open(path, 'rb').read()
        self.md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
        self.md.detail = True
        self.maps = {'sel': {}, 'cfstr': {}, 'class': {}, 'sym': {}, 'stub': {}, 'imp': {}}
        self._build()

    # ---------- 基础读取 ----------
    def read(self, va, n):
        o = self.m.va2off(va)
        return self.m.rd(o, n) if o is not None else b''

    def cstr(self, va):
        o = self.m.va2off(va)
        if o is None:
            return None
        try:
            end = self.data.index(b'\x00', self.m.base_off + o)
        except ValueError:
            return None
        return self.data[self.m.base_off + o:end].decode('utf-8', 'replace')

    def u64(self, va):
        raw = self.read(va, 8)
        return struct.unpack('<Q', raw)[0] if len(raw) == 8 else None

    # ---------- 地图构建 ----------
    def _build(self):
        m = self.m
        # 1) 选择器引用表 __objc_selrefs
        s = m.sect('__objc_selrefs')
        if s:
            for i in range(s['size'] // 8):
                va = s['addr'] + i * 8
                q = self.u64(va)
                d = m.dec(q) if q else None
                if d:
                    txt = self.cstr(d)
                    if txt:
                        self.maps['sel'][va] = txt
        # 2) 类引用表
        for sect, key in (('__objc_classrefs', 'class'), ('__objc_superrefs', 'class')):
            s = m.sect(sect)
            if not s:
                continue
            for i in range(s['size'] // 8):
                va = s['addr'] + i * 8
                q = self.u64(va)
                d = m.dec(q) if q else None
                if not d:
                    continue
                name = self._class_name(d)
                if name:
                    self.maps[key][va] = name
        # 3) CFString
        s = m.sect('__cfstring')
        if s:
            for i in range(s['size'] // 32):
                va = s['addr'] + i * 32
                raw = self.read(va, 32)
                if len(raw) < 32:
                    continue
                isa, flags, ptr, ln = struct.unpack('<QQQQ', raw)
                d = m.dec(ptr)
                if not d:
                    continue
                txt = self._cfstring_text(d, ln, flags)
                if txt is not None:
                    self.maps['cfstr'][va] = txt
        # 4) 导入符号：直接读 dyld chained fixups 的 imports 表 + 每个 GOT 槽的绑定 ordinal
        self._build_imports()
        # 5) stub 解码
        for sect in ('__auth_stubs', '__stubs', '__objc_stubs'):
            s = m.sect(sect)
            if not s:
                continue
            self._decode_stubs(s['addr'], s['size'])
        # 6) imp → -[Class sel]
        try:
            gt = json.load(open(os.path.join(ROOT, 'ground_truth.json')))
        except Exception:
            gt = {}
        for cls, e in gt.items():
            for meth in e.get('methods', []):
                self.maps['imp'][meth['imp']] = '%s %s' % (cls, meth['sel'])

    def _build_imports(self):
        m = self.m
        off = 32
        lc = None
        for _ in range(m.ncmds):
            cmd, sz = struct.unpack('<II', m.rd(off, 8))
            if cmd == 0x80000034:      # LC_DYLD_CHAINED_FIXUPS
                lc = off
            off += sz
        if lc is None:
            return
        dataoff, _datasize = struct.unpack('<II', m.rd(lc + 8, 8))
        (_ver, _starts, imports_off, symbols_off,
         imports_count, _ifmt, _sfmt, _pad) = struct.unpack('<8I', m.rd(dataoff, 32))
        simbase = dataoff + symbols_off

        def symname(o2):
            o = simbase + o2
            try:
                end = m.data.index(b'\x00', m.base_off + o)
            except ValueError:
                return None
            return m.data[m.base_off + o:end].decode('utf-8', 'replace')

        names = []
        for i in range(imports_count):
            v = struct.unpack('<I', m.rd(dataoff + imports_off + i * 4, 4))[0]
            names.append(symname(v >> 9))
        self.imports = names

        # 遍历 __auth_got / __got / __auth_ptr，把每个槽解成符号
        for sect in ('__auth_got', '__got', '__auth_ptr', '__la_symbol_ptr'):
            s2 = m.sect(sect)
            if not s2:
                continue
            for i in range(s2['size'] // 8):
                va = s2['addr'] + i * 8
                raw = self.read(va, 8)
                if len(raw) < 8:
                    continue
                v = struct.unpack('<Q', raw)[0]
                if v >> 63:                       # PTR_64_AUTH：ordinal 低 16 位
                    o = v & 0xffff
                elif (v >> 62) & 1:               # PTR_64 bind：ordinal 低 24 位
                    o = v & 0xffffff
                else:
                    continue
                if o < len(names) and names[o]:
                    self.maps['sym'][va] = names[o]


    def _cfstring_text(self, data_va, length, flags):
        """CFString 文本解码：按内容判断 8 位还是 UTF-16LE（二进制里大量中文常量是 UTF-16）。"""
        o = self.m.va2off(data_va)
        if o is None:
            return None
        n = length if 0 < length < 4096 else 64
        raw = self.data[self.m.base_off + o: self.m.base_off + o + n * 2 + 8]
        if not raw:
            return None
        # 判定：连续 n 个字节全是可打印 ASCII → 8 位；否则 UTF-16LE
        head = raw[:n]
        printable = all(0x20 <= b <= 0x7e for b in head) if head else False
        if printable:
            end = raw.find(b'\x00')
            if end < 0:
                end = len(raw)
            return raw[:end].decode('utf-8', 'replace')
        try:
            return raw[:n * 2].decode('utf-16-le', 'replace').split('\x00')[0]
        except Exception:
            return None

    def _class_name(self, class_va):
        bits = self.u64(class_va + 32)
        if not bits:
            return None
        ro = self.m.dec(bits & ~0x7)
        if not ro:
            return None
        raw = self.read(ro + 24, 8)      # name 指针在 class_ro_t+24
        if len(raw) < 8:
            return None
        nva = self.m.dec(struct.unpack('<Q', raw)[0])
        return self.cstr(nva) if nva else None

    def _decode_stubs(self, addr, size):
        """stub 有两种形态：
             A: adrp x1,selref / ldr x1,[x1,#o] / adrp x16,got / ldr x16,[x16,#o] / br x16   (0x20)
             B: adrp x16,got   / ldr x16,[x16,#o] / br x16                                  (0x10)
           按 4 字节步进探测，命中后按实际长度跳过。"""
        va = addr
        end = addr + size
        while va < end:
            blob = self.read(va, 0x20)
            if len(blob) < 0x10:
                break
            ins = list(self.md.disasm(blob, va))
            if len(ins) >= 5 and ins[0].mnemonic == 'adrp' and ins[1].mnemonic == 'ldr' \
                    and ins[2].mnemonic == 'adrp' and ins[3].mnemonic == 'ldr' \
                    and ins[4].mnemonic == 'br':
                try:
                    sel_slot = ins[0].operands[1].imm + ins[1].operands[1].mem.disp
                    got_slot = ins[2].operands[1].imm + ins[3].operands[1].mem.disp
                except (IndexError, AttributeError):
                    va += 4
                    continue
                sel = self.maps['sel'].get(sel_slot)
                sym = self.maps['sym'].get(got_slot)
                if sel:
                    self.maps['stub'][va] = ('sel', sel)
                elif sym:
                    self.maps['stub'][va] = ('sym', sym)
                va += 0x20
                continue
            if len(ins) >= 3 and ins[0].mnemonic == 'adrp' and ins[1].mnemonic == 'ldr' \
                    and ins[2].mnemonic == 'br':
                try:
                    got_slot = ins[0].operands[1].imm + ins[1].operands[1].mem.disp
                except (IndexError, AttributeError):
                    va += 4
                    continue
                sym = self.maps['sym'].get(got_slot)
                if sym:
                    self.maps['stub'][va] = ('sym', sym)
                va += 0xc   # __stubs 条目是 12 字节（无 brk 填充）
                continue
            va += 4

    # ---------- 反汇编 + 标注 ----------
    def annotate(self, ea, count=400, stop_at=None, brief=False):
        lines = []
        reg = {}
        text_sect = self.m.sect('__text')
        t0 = text_sect['addr']
        t1 = t0 + text_sect['size']
        blob = self.read(ea, min(4 * count + 16, 16 * 1024))
        n = 0
        for ins in self.md.disasm(blob, ea):
            note = []
            mn, ops = ins.mnemonic, ins.op_str
            dsts = [ins.reg_name(o.reg) for o in ins.operands
                    if o.type == ARM64_OP_REG and o.access and o.access & 2] if ins.operands else []
            if mn == 'adrp':
                try:
                    reg[dsts[0]] = ins.operands[1].imm
                except IndexError:
                    pass
            elif mn == 'add' and len(ins.operands) >= 3 and ins.operands[2].type == ARM64_OP_IMM:
                base = reg.get(ins.reg_name(ins.operands[1].reg))
                if base is not None:
                    va = base + ins.operands[2].imm
                    reg[dsts[0]] = va
                    if va in self.maps['cfstr']:
                        note.append('@"%s"' % _clip(self.maps['cfstr'][va]))
                    elif va in self.maps['class']:
                        note.append('CLASS %s' % self.maps['class'][va])
                    else:
                        c = self.cstr(va)
                        if c and self._in_cstring(va):
                            note.append('str "%s"' % _clip(c))
                else:
                    reg.pop(dsts[0] if dsts else '', None)
            elif mn.startswith('ldr') and len(ins.operands) == 2 and ins.operands[1].type == ARM64_OP_MEM:
                base = reg.get(ins.reg_name(ins.operands[1].mem.base))
                if base is not None and ins.operands[1].mem.index == 0:
                    va = base + ins.operands[1].mem.disp
                    if va in self.maps['sel']:
                        note.append('SEL %s' % self.maps['sel'][va])
                    elif va in self.maps['cfstr']:
                        note.append('CFSTR "%s"' % _clip(self.maps['cfstr'][va]))
                    elif va in self.maps['class']:
                        note.append('CLASS %s' % self.maps['class'][va])
                    elif va in self.maps['sym']:
                        note.append('GOT %s' % self.maps['sym'][va])
                if dsts:
                    reg.pop(dsts[0], None)
            else:
                for d in dsts:
                    reg.pop(d, None)
            if mn in ('bl', 'b', 'br', 'blr') and ins.operands \
                    and ins.operands[0].type == ARM64_OP_IMM:
                tgt = ins.operands[0].imm
                if tgt in self.maps['stub']:
                    kind, name = self.maps['stub'][tgt]
                    note.append('call %s' % (name if kind == 'sym' else 'send %s' % name))
                elif tgt in self.maps['imp']:
                    cls, sel = self.maps['imp'][tgt].split(' ', 1)
                    note.append('call -[%s %s]' % (cls, sel))
                elif not (t0 <= tgt < t1):
                    note.append('call %#x' % tgt)
            keep = True
            if brief:
                interesting = ('bl', 'b', 'br', 'blr', 'cbz', 'cbnz', 'tbz', 'tbnz',
                               'cmp', 'ccmp', 'adrp', 'add', 'ldr', 'ldur', 'ldrb',
                               'str', 'stur', 'strb', 'mov', 'movi', 'fmov', 'fmul',
                               'fadd', 'fdiv', 'fsub', 'fcmp', 'scvtf', 'fcvtzs')
                keep = (bool(note) or mn in interesting)
            line = '  %#08x  %-8s %-40s' % (ins.address, mn, ops)
            if note:
                line += ' ; ' + ' | '.join(note)
            if keep:
                lines.append(line)
            n += 1
            if n >= count:
                break
            if stop_at and ins.address >= stop_at:
                break
        return lines

    def _in_cstring(self, va):
        for name in ('__cstring', '__ustring'):
            s = self.m.sect(name)
            if s and s['addr'] <= va < s['addr'] + s['size']:
                return True
        return False


def _clip(s, n=90):
    s = s.replace('\n', '\\n')
    return s if len(s) <= n else s[:n] + '…'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bin', default=BIN)
    ap.add_argument('--class', dest='cls')
    ap.add_argument('--sel')
    ap.add_argument('--ea')
    ap.add_argument('--len', type=int, default=300)
    ap.add_argument('--list', action='store_true')
    ap.add_argument('--brief', action='store_true')
    a = ap.parse_args()

    ctx = Ctx(a.bin)
    gt = json.load(open(os.path.join(ROOT, 'ground_truth.json')))

    if a.cls and a.list:
        e = gt.get(a.cls)
        if not e:
            sys.exit('未知类 %s' % a.cls)
        for m in e['methods']:
            print('%#010x  %s' % (m['imp'], m['sel']))
        return

    if a.ea:
        ea = int(a.ea, 16)
        print('\n'.join(ctx.annotate(ea, a.len, brief=a.brief)))
        return

    if not (a.cls and a.sel):
        ap.error('需要 --class 与 --sel，或 --ea，或 --class … --list')
    e = gt.get(a.cls) or {}
    hit = [m for m in e.get('methods', []) if m['sel'] == a.sel]
    if not hit:
        sys.exit('类 %s 里没有 %s' % (a.cls, a.sel))
    m = hit[0]
    print(';; -[%s %s]   %s   imp=%#x' % (a.cls, a.sel, m['types'], m['imp']))
    print('\n'.join(ctx.annotate(m['imp'], a.len, brief=a.brief)))


if __name__ == '__main__':
    main()
