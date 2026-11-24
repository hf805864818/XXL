#!/usr/bin/env python3
"""pack_assets.py —— 生成官方格式的素材包（可被 App 直接识别/下载/导入）

格式（从原包 asset-manifest.json / asset-spec.json 反推，已验证可逐字节复现）：

  manifest.json
    asset_version    = content_sha256 的前 16 个十六进制字符
    content_sha256   = sha256( 按路径排序后逐个拼接 "<path>:<sha256>\n" )
    files            = { "<相对路径>": { "bytes": n, "sha256": "..." } }

  PetDFY-assets.zip  ← 只包含 originals/ 与 live/ 下的文件，路径原样
  asset-spec.json
    { schema:1, file:"PetDFY-assets.zip", bytes, sha256(包), manifest_sha256, asset_version }

用法：
  python3 tools/pack_assets.py --src assets_src --out build/assets
  python3 tools/pack_assets.py --src assets_src --verify   # 只校验能否复现官方哈希
"""
import argparse, hashlib, json, os, sys, zipfile

INCLUDE_DIRS = ('originals', 'live')
SKIP_NAMES = {'.DS_Store', '.git', '.gitignore'}
SKIP_PREFIX = ('_',)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def collect(src):
    files = {}
    for d in INCLUDE_DIRS:
        root = os.path.join(src, d)
        if not os.path.isdir(root):
            continue
        for base, dirs, names in os.walk(root):
            dirs[:] = [x for x in dirs if x not in SKIP_NAMES and not x.startswith(SKIP_PREFIX)]
            for n in sorted(names):
                if n in SKIP_NAMES or n.startswith(SKIP_PREFIX):
                    continue
                abs_p = os.path.join(base, n)
                rel = os.path.relpath(abs_p, src).replace(os.sep, '/')
                files[rel] = {'bytes': os.path.getsize(abs_p), 'sha256': sha256_file(abs_p)}
    return files


def content_hash(files):
    payload = ''.join('%s:%s\n' % (k, files[k]['sha256']) for k in sorted(files))
    return hashlib.sha256(payload.encode()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src', default='assets_src')
    ap.add_argument('--out', default='build/assets')
    ap.add_argument('--verify', action='store_true',
                    help='只计算并打印哈希，用于和原包对照')
    ap.add_argument('--skip-zip', action='store_true')
    a = ap.parse_args()

    files = collect(a.src)
    if not files:
        sys.exit('没有找到 originals/ 或 live/，--src 指错了？')

    chash = content_hash(files)
    version = chash[:16]
    print('文件数 %d，合计 %d 字节' % (len(files), sum(v['bytes'] for v in files.values())))
    print('content_sha256 = %s' % chash)
    print('asset_version  = %s' % version)

    if a.verify:
        ref = None
        for cand in ('asset-manifest.json',
                     os.path.join(a.src, 'asset-manifest.json')):
            if os.path.exists(cand):
                ref = json.load(open(cand))
                break
        if ref:
            ok = (ref.get('content_sha256') == chash and ref.get('asset_version') == version)
            print('与原 manifest 对照：%s' % ('一致 ✅' if ok else '不一致 ❌'))
            if not ok:
                print('  原: %s / %s' % (ref.get('asset_version'), ref.get('content_sha256')))
                diff = set(ref.get('files', {})) ^ set(files)
                print('  文件集合差异 %d 项：%s' % (len(diff), sorted(diff)[:8]))
        return

    os.makedirs(a.out, exist_ok=True)

    manifest = {'asset_version': version, 'content_sha256': chash, 'files': files}
    mpath = os.path.join(a.out, 'asset-manifest.json')
    with open(mpath, 'w', encoding='utf-8') as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1, sort_keys=True)
        f.write('\n')

    zpath = os.path.join(a.out, 'PetDFY-assets.zip')
    if not a.skip_zip:
        with zipfile.ZipFile(zpath, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
            for rel in sorted(files):
                zi = zipfile.ZipInfo(rel, date_time=(1980, 1, 1, 0, 0, 0))
                zi.compress_type = zipfile.ZIP_DEFLATED
                zi.external_attr = 0o644 << 16
                with open(os.path.join(a.src, rel), 'rb') as fsrc:
                    z.writestr(zi, fsrc.read())
        spec = {
            'schema': 1,
            'file': 'PetDFY-assets.zip',
            'bytes': os.path.getsize(zpath),
            'sha256': sha256_file(zpath),
            'manifest_sha256': sha256_file(mpath),
            'asset_version': version,
        }
        spath = os.path.join(a.out, 'asset-spec.json')
        with open(spath, 'w', encoding='utf-8') as f:
            json.dump(spec, f, ensure_ascii=False, indent=2)
            f.write('\n')
        print('写出 %s（%d 字节）、%s、%s' % (zpath, spec['bytes'], mpath, spath))
    else:
        print('写出 %s（未打包 zip）' % mpath)


if __name__ == '__main__':
    main()
