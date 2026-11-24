#!/usr/bin/env python3
"""Minimal Mach-O 64 ObjC metadata dumper, dyld-chained-fixup aware."""
import struct, sys, json

MASK36 = 0xFFFFFFFFF

class MachO:
    def __init__(self, path):
        self.data = open(path,'rb').read()
        magic = struct.unpack('>I', self.data[:4])[0]
        self.fat = magic in (0xcafebabe, 0xcafebabf)
        if self.fat:
            n = struct.unpack('>I', self.data[4:8])[0]
            self.slices=[]
            for i in range(n):
                cpu, sub, off, size, align = struct.unpack('>IIIII', self.data[8+i*20:8+i*20+20])
                self.slices.append((cpu,off,size))
            pick=None
            for s in self.slices:
                if s[0]==0x0100000c: pick=s;break
            if pick is None: pick=self.slices[0]
            self.base_off, self.size, self.cpu = pick[1], pick[2], pick[0]
        else:
            self.base_off=0; self.size=len(self.data); self.cpu=struct.unpack('<I',self.data[4:8])[0]
        self.parse_header()

    def rd(self, off, n): return self.data[self.base_off+off:self.base_off+off+n]
    def u32(self, off): return struct.unpack('<I', self.rd(off,4))[0]
    def u64(self, off): return struct.unpack('<Q', self.rd(off,8))[0]

    def parse_header(self):
        assert self.u32(0)==0xfeedfacf
        self.cputype,self.cpusub,self.filetype,self.ncmds,self.sizecmds,self.flags = struct.unpack('<IIIIII', self.rd(4,24))
        self.segments=[]; self.sections=[]
        off=32
        for _ in range(self.ncmds):
            cmd,cmdsize = struct.unpack('<II', self.rd(off,8))
            if cmd==0x19:
                segname = self.rd(off+8,16).rstrip(b'\x00').decode()
                vmaddr,vmsize,fileoff,filesize = struct.unpack('<QQQQ', self.rd(off+24,32))
                nsects = self.u32(off+64)
                self.segments.append((segname,vmaddr,vmsize,fileoff,filesize))
                so=off+72
                for i in range(nsects):
                    sectname=self.rd(so,16).rstrip(b'\x00').decode()
                    segn=self.rd(so+16,16).rstrip(b'\x00').decode()
                    addr,size = struct.unpack('<QQ', self.rd(so+32,16))
                    offset=self.u32(so+48)
                    self.sections.append(dict(sect=sectname,seg=segn,addr=addr,size=size,offset=offset))
                    so+=80
            off+=cmdsize
        self.mapl=[(s[1],s[2],s[3]) for s in self.segments if s[4]>0]

    def va2off(self, va):
        if va is None: return None
        for vmaddr,vmsize,fileoff in self.mapl:
            if vmaddr <= va < vmaddr+vmsize: return fileoff + (va-vmaddr)
        return None

    def dec(self, va):
        """decode chained/bound pointer to a file offset space address"""
        if va is None: return None
        if va==0: return 0
        low = va & MASK36
        if self.va2off(low) is not None: return low
        if self.va2off(va) is not None: return va
        return None

    def cstr(self, off):
        if off is None: return ''
        try:
            end=self.data.index(b'\x00', self.base_off+off)
        except ValueError:
            return ''
        return self.data[self.base_off+off:end].decode('utf-8','replace')

    def q(self, va):
        o=self.va2off(va)
        if o is None: return None
        return struct.unpack('<Q', self.rd(o,8))[0]

    def inrange(self, va, sectname):
        s=self.sect(sectname)
        return s and s['addr'] <= va < s['addr']+s['size']

    def resolve_sel(self, va, depth=0):
        if depth>2: return ''
        if self.inrange(va, '__objc_methname'):
            return self.cstr(self.va2off(va))
        q=self.q(va)
        d=self.dec(q) if q else None
        if d is not None and self.inrange(d, '__objc_methname'):
            return self.cstr(self.va2off(d))
        if d is not None:
            return self.resolve_sel(d, depth+1)
        return self.cstr(self.va2off(va))

    def sect(self,name,seg=None):
        for s in self.sections:
            if s['sect']==name and (seg is None or s['seg']==seg): return s
        return None

def parse(path):
    m=MachO(path)
    out={}
    sl=m.sect('__objc_classlist')
    n=sl['size']//8
    for i in range(n):
        cptrm = m.q(sl['addr']+i*8)
        cptr = m.dec(cptrm)
        if not cptr: continue
        data_bits = m.q(cptr+32) or 0
        ro = m.dec(data_bits & ~0x7)
        if not ro: continue
        hdr = m.rd(m.va2off(ro), 72)
        if len(hdr)<72: continue
        flags,iStart,iSize = struct.unpack('<III', hdr[0:12])
        ivarLayout,name_va,baseMethods,baseProtocols,ivars,weak,baseProps = struct.unpack('<QQQQQQQ', hdr[16:72])
        name_va = m.dec(name_va); baseMethods = m.dec(baseMethods)
        ivars = m.dec(ivars); baseProps = m.dec(baseProps)
        cname = m.cstr(m.va2off(name_va))
        e=dict(name=cname, methods=[], ivars=[], props=[])
        if baseMethods:
            f = m.u32(m.va2off(baseMethods))
            cnt = m.u32(m.va2off(baseMethods)+4)
            rel = bool(f & 0x80000000); entsize = f & 0xfffc
            for k in range(cnt):
                if rel:
                    ea = baseMethods+8+k*entsize
                    raw = m.rd(m.va2off(ea),12)
                    if len(raw)<12: break
                    no,to,io = struct.unpack('<iii',raw)
                    sel = m.resolve_sel(ea+no)
                    typva = ea+4+to
                    types = m.cstr(m.va2off(typva))
                    e['methods'].append(dict(sel=sel, types=types, imp=ea+8+io))
                else:
                    ea = baseMethods+8+k*entsize
                    nva,tva,imp = struct.unpack('<QQQ', m.rd(m.va2off(ea),24))
                    e['methods'].append(dict(sel=m.cstr(m.va2off(m.dec(nva))), types=m.cstr(m.va2off(m.dec(tva))), imp=imp))
        if ivars:
            es,cnt = struct.unpack('<II', m.rd(m.va2off(ivars),8))
            for k in range(cnt):
                raw=m.rd(m.va2off(ivars+8+k*es),32)
                if len(raw)<28: break
                offp,nv,tv,al,sz = struct.unpack('<iQQII', raw[:28])
                e['ivars'].append(dict(name=m.cstr(m.va2off(m.dec(nv))), type=m.cstr(m.va2off(m.dec(tv))), offset=offp, size=sz))
        if baseProps:
            es,cnt = struct.unpack('<II', m.rd(m.va2off(baseProps),8))
            for k in range(cnt):
                raw=m.rd(m.va2off(baseProps+8+k*es),16)
                if len(raw)<16: break
                nv,av=struct.unpack('<QQ',raw)
                e['props'].append(dict(name=m.cstr(m.va2off(m.dec(nv))), attrs=m.cstr(m.va2off(m.dec(av)))))
        out[cname]=e
    return out

if __name__=='__main__':
    d=parse(sys.argv[1])
    if len(sys.argv)>2 and sys.argv[2]=='-j':
        print(json.dumps(d,ensure_ascii=False,indent=1)); sys.exit()
    tot=0
    for c,e in sorted(d.items()):
        print(f"\n=== {c}   methods={len(e['methods'])} ivars={len(e['ivars'])} props={len(e['props'])}")
        for mm in e['methods']:
            print(f"    - {mm['sel']}   {mm['types']}  @0x{mm['imp']:x}")
        tot+=len(e['methods'])
    print(f"\nTOTAL classes={len(d)} methods={tot}",file=sys.stderr)
