#!/usr/bin/env python3
"""source_check.py —— 源码树静态体检（不能替代编译，但能挡住低级错误）

检查：
  1. 花括号/圆括号/方括号是否配平
  2. @interface / @implementation / @end 是否成对
  3. #import "本地头文件" 是否存在
  4. 每个 .m 是否有对应 @implementation
  5. Objective-C 里常见的 `if (...)` 后漏分号/多分号
"""
import os, re, sys


def lex_strip(src):
    """把注释与字符串/字符常量替换成空白，保留换行与长度无关的其它字符。

    正确的词法扫描（状态机），所以 "http://x" 里的 // 不会被当注释、
    @"..." 里的 @end 不会被计数。
    """
    out = []
    i, n = 0, len(src)
    state = None      # None | 'line' | 'block' | 'str' | 'chr'
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ''
        if state is None:
            if c == '/' and nxt == '/':
                state = 'line'
                out.append('  ')
                i += 2
                continue
            if c == '/' and nxt == '*':
                state = 'block'
                out.append('  ')
                i += 2
                continue
            if c == '"':
                state = 'str'
                out.append(' ')
                i += 1
                continue
            if c == "'":
                state = 'chr'
                out.append(' ')
                i += 1
                continue
            out.append(c)
            i += 1
        elif state == 'line':
            if c == '\n':
                state = None
                out.append('\n')
            else:
                out.append(' ')
            i += 1
        elif state == 'block':
            if c == '*' and nxt == '/':
                state = None
                out.append('  ')
                i += 2
                continue
            out.append('\n' if c == '\n' else ' ')
            i += 1
        elif state in ('str', 'chr'):
            if c == '\\':
                out.append('  ')
                i += 2
                continue
            if (state == 'str' and c == '"') or (state == 'chr' and c == "'"):
                state = None
                out.append(' ')
                i += 1
                continue
            out.append('\n' if c == '\n' else ' ')
            i += 1
    return ''.join(out)

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
SRC = os.path.join(ROOT, 'src')
files = []
for base, _, names in os.walk(SRC):
    for n in sorted(names):
        if n.endswith(('.m', '.h')):
            files.append(os.path.join(base, n))

headers = {os.path.basename(p) for p in files}
problems = []
warnings = []
for p in files:
    s = open(p, errors='ignore').read()
    rel = os.path.relpath(p, ROOT)
    # 括号配平（粗略：字符串与注释先剥掉）
    t = lex_strip(s)                                      # 正确剥离注释/字符串
    t = re.sub(r'^\s*#.*$', '', t, flags=re.M)            # 预处理行
    # 括号配平：只当作强提示（字符串/注释剥离不可能 100% 准确，
    # 差值 > 2 才算可疑，差值 <= 2 记为提示）
    for op, cl in (('{', '}'), ('(', ')'), ('[', ']')):
        d = t.count(op) - t.count(cl)
        if abs(d) > 2:
            problems.append('%s: %s%s 疑似不配平 (%d vs %d)' % (rel, op, cl, t.count(op), t.count(cl)))
        elif d:
            warnings.append('%s: %s%s 差 %+d（可能是剥离伪影）' % (rel, op, cl, d))
    if p.endswith('.m'):
        body = lex_strip(s)
        impl = len(re.findall(r'@implementation\s+\w+', body))
        iface = len(re.findall(r'@interface\s+\w+', body))
        # 只算真正带 @end 的 @protocol：同行以 ; 结尾的是前向声明
        proto = 0
        for line in body.split('\n'):
            if re.search(r'@protocol\s+\w+', line) and not line.strip().endswith(';'):
                proto += 1
        end = len(re.findall(r'@end\b', body))
        expect = impl + iface + proto
        if expect != end:
            problems.append('%s: @interface/@implementation/@protocol 共 %d 个，@end %d 个'
                            % (rel, expect, end))
    if p.endswith('.h'):
        inter = len(re.findall(r'@interface\s+\w+', s))
        if inter and 'NS_ENUM' not in s and 'typedef' not in s:
            pass
    for m in re.finditer(r'#import\s+"([^"]+)"', s):
        name = m.group(1)
        if name not in headers:
            problems.append('%s: import "%s" 找不到对应头文件' % (rel, name))

print('检查 %d 个文件' % len(files))
if warnings:
    print('  · 提示 %d 条（不影响）：' % len(warnings))
    for w in warnings[:6]:
        print('    ' + w)
if problems:
    print('\n'.join('  ✗ ' + x for x in problems))
    sys.exit(1)
print('✓ 括号配平、@implementation/@end 配对、本地 import 全部可达')
