#!/usr/bin/env python3
"""pd_png —— 纯标准库 PNG 读写（RGBA8 / 非隔行），供发色预览与素材检查使用。

素材包里的 PNG 全是 bitdepth=8、colorType=6（RGBA）、interlace=0，
所以这里只实现这一种格式：够用、无第三方依赖、可在手机上跑。
"""
import struct, zlib


def read_png(path):
    """返回 (width, height, bytearray RGBA)。"""
    data = open(path, 'rb').read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('not a PNG: %s' % path)
    pos = 8
    width = height = None
    idat = bytearray()
    bitdepth = colortype = interlace = None
    palette = None
    trns = None
    while pos < len(data):
        (length,) = struct.unpack('>I', data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        payload = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctype == b'IHDR':
            width, height, bitdepth, colortype, _comp, _filt, interlace = struct.unpack('>IIBBBBB', payload)
        elif ctype == b'IDAT':
            idat += payload
        elif ctype == b'PLTE':
            palette = payload
        elif ctype == b'tRNS':
            trns = payload
        elif ctype == b'IEND':
            break
    if bitdepth != 8 or interlace != 0:
        raise ValueError('only 8-bit non-interlaced PNG supported (%s)' % path)
    raw = zlib.decompress(bytes(idat))

    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colortype]
    stride = width * channels
    out = bytearray(stride * height)
    prev = bytearray(stride)
    p = 0
    for y in range(height):
        ftype = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if ftype == 0:
            pass
        elif ftype == 1:  # Sub
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif ftype == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:  # Average
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:  # Paeth
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        else:
            raise ValueError('bad filter %d' % ftype)
        out[y * stride:(y + 1) * stride] = line
        prev = line

    if colortype == 6:
        return width, height, out
    # 统一扩成 RGBA
    rgba = bytearray(width * height * 4)
    for i in range(width * height):
        if colortype == 2:
            r, g, b = out[i * 3:i * 3 + 3]
            a = 255
        elif colortype == 0:
            r = g = b = out[i]
            a = 255
        elif colortype == 4:
            r = g = b = out[i * 2]
            a = out[i * 2 + 1]
        elif colortype == 3:
            idx = out[i]
            r, g, b = palette[idx * 3:idx * 3 + 3]
            a = trns[idx] if trns and idx < len(trns) else 255
        else:
            raise ValueError('unsupported color type %d' % colortype)
        rgba[i * 4:i * 4 + 4] = bytes((r, g, b, a))
    return width, height, rgba


def write_png(path, width, height, rgba):
    """写 RGBA8 PNG（filter=0，够小、够快）。"""
    stride = width * 4
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += rgba[y * stride:(y + 1) * stride]

    def chunk(tag, payload):
        return (struct.pack('>I', len(payload)) + tag + payload +
                struct.pack('>I', zlib.crc32(tag + payload) & 0xFFFFFFFF))

    ihdr = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    data = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) +
            chunk(b'IDAT', zlib.compress(bytes(raw), 9)) + chunk(b'IEND', b''))
    with open(path, 'wb') as f:
        f.write(data)
    return len(data)


def crop(width, height, rgba, box):
    """box = (x, y, w, h)"""
    x0, y0, w, h = box
    out = bytearray(w * h * 4)
    for y in range(h):
        sy = y0 + y
        if sy < 0 or sy >= height:
            continue
        srow = (sy * width + x0) * 4
        drow = y * w * 4
        n = min(w, width - x0) * 4
        if n > 0:
            out[drow:drow + n] = rgba[srow:srow + n]
    return w, h, out
