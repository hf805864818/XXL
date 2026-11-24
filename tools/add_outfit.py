#!/usr/bin/env python3
"""add_outfit.py —— 加一套新衣服（不用改一句代码）

原理：
  live/model.json 的 models 里，一套服装 = 一个 model 条目（parts 带 z/parent/grid/box）。
  几何（box/grid/deformer）是装配出来的结果，从零手写不现实，
  正确做法是「克隆一套最接近的，然后只换贴图 + 调 z」。
  本工具就做这件事，并把该服装自己的 PNG 独立到 outfits/<新id>/，
  以后改这套衣服的贴图不会影响别人。

用法：
  # 以 sailor 为模板，造一套叫 school 的校服
  python3 tools/add_outfit.py --id school --from sailor --title 校服

  # 只看会做什么，不落盘
  python3 tools/add_outfit.py --id school --from sailor --dry-run

产出：
  assets_src/live/model.json            新增 models["school"]（克隆 from）
  assets_src/originals/model.json       outfits 列表追加 {"id":"school"}（如果存在）
  assets_src/originals/PDOutfitTitles.json    {"school":"校服"}
  assets_src/originals/outfits/school/  该服装用到的 PNG 副本
  assets_src/originals/thumbs/school.png    缩略图（先复制模板的，之后自己换）
"""
import argparse, copy, json, os, shutil, sys

BASE = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'assets_src'))


def load(p):
    with open(p, 'r', encoding='utf-8') as f:
        return json.load(f)


def save(p, d):
    with open(p, 'w', encoding='utf-8') as f:
        json.dump(d, f, ensure_ascii=False, indent=2, sort_keys=False)
        f.write('\n')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--id', required=True, help='新服装 id（英文、无空格，例如 school）')
    ap.add_argument('--from', dest='src', default='sailor', help='模板服装 id（默认 sailor）')
    ap.add_argument('--title', default=None, help='显示名（中文）')
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--copy-shared', action='store_true',
                    help='连 tex/ 里的共享贴图也复制一份到新服装目录（默认不复制，走素材候选链）')
    a = ap.parse_args()

    live_p = os.path.join(BASE, 'live/model.json')
    orig_p = os.path.join(BASE, 'originals/model.json')
    live = load(live_p)

    models = live.get('models', {})
    if a.id in models:
        sys.exit('models 里已经有 %s 了，换个 id' % a.id)
    if a.src not in models:
        sys.exit('模板 %s 不存在，可选：%s' % (a.src, ', '.join(models)))

    donor = models[a.src]
    newmodel = copy.deepcopy(donor)
    models[a.id] = newmodel

    # live/model.json 的规矩：
    #   · 服装私有的部件带 "src"，形如 "outfits/jk-sailor/arm_far.png"（相对资源根）
    #   · 全部服装共用的部件没有 src，落到 "<root>tex/<tex>.png"
    # 所以克隆一套衣服 = 复制带 src 的那些 PNG，并把 src 改到新目录。
    tex_dir = os.path.join(BASE, 'originals/tex')
    private = []      # (part, old_src)
    for part in newmodel.get('parts', []):
        src = part.get('src')
        if not src or not src.startswith('outfits/'):
            continue
        private.append((part, src))

    donor_dirs = sorted({os.path.dirname(src) for _, src in private})
    donor_dir = donor_dirs[0] if len(donor_dirs) == 1 else None
    if not donor_dir:
        sys.exit('模板 %s 的 src 不在同一个目录里：%s' % (a.src, donor_dirs))

    new_rel_dir = 'outfits/%s' % a.id
    new_abs_dir = os.path.join(BASE, 'originals', new_rel_dir)

    print('新服装 %s（模板 %s）：%d 个部件，其中 %d 个带私有贴图（%s）'
          % (a.id, a.src, len(newmodel.get('parts', [])), len(private), donor_dir))

    if a.dry_run:
        print('\n[dry-run] 未写入任何文件')
        return

    # ---- 贴图目录：复制私有贴图，并把 src 指到新目录 ----
    os.makedirs(new_abs_dir, exist_ok=True)
    for part, src in private:
        fname = os.path.basename(src)
        shutil.copy2(os.path.join(BASE, 'originals', src), os.path.join(new_abs_dir, fname))
        part['src'] = '%s/%s' % (new_rel_dir, fname)
    if a.copy_shared:
        for part in newmodel.get('parts', []):
            if 'src' in part:
                continue
            tex = (part.get('tex') or part.get('id')) + '.png'
            if os.path.exists(os.path.join(tex_dir, tex)):
                shutil.copy2(os.path.join(tex_dir, tex), os.path.join(new_abs_dir, tex))
                part['src'] = '%s/%s' % (new_rel_dir, tex)

    # ---- live/model.json ----
    save(live_p, live)

    # ---- originals/model.json 的 outfits 列表 ----
    # 注意：这里存的是「源模型」的每套服装定义（可能带 parts/pivots/deformers），
    # 不是只有 id。所以必须整段克隆并改写 src，否则从源模型重编译时这套衣服会空掉。
    if os.path.exists(orig_p):
        orig = load(orig_p)
        outs = orig.get('outfits')
        if isinstance(outs, list):
            exists = any(isinstance(o, dict) and o.get('id') == a.id for o in outs)
            if not exists:
                donor_entry = next((o for o in outs
                                    if isinstance(o, dict) and o.get('id') == a.src), None)
                entry = copy.deepcopy(donor_entry) if donor_entry else {'id': a.id}
                entry['id'] = a.id
                for part in entry.get('parts', []) or []:
                    src = part.get('src')
                    if isinstance(src, str) and src.startswith('outfits/'):
                        part['src'] = '%s/%s' % (new_rel_dir, os.path.basename(src))
                outs.append(entry)
                save(orig_p, orig)
                print('  源模型 outfits 追加 %s（%d 个部件定义）'
                      % (a.id, len(entry.get('parts', []) or [])))

    # ---- 标题 ----
    titles_p = os.path.join(BASE, 'originals/PDOutfitTitles.json')
    titles = load(titles_p) if os.path.exists(titles_p) else {}
    titles[a.id] = a.title or a.id
    save(titles_p, titles)

    # ---- 缩略图 ----
    thumbs = os.path.join(BASE, 'originals/thumbs')
    src_thumb = os.path.join(thumbs, a.src + '.png')
    dst_thumb = os.path.join(thumbs, a.id + '.png')
    if os.path.exists(src_thumb) and not os.path.exists(dst_thumb):
        shutil.copy2(src_thumb, dst_thumb)

    print('\n完成。下一步：')
    print('  1) 改 %s 里的 PNG（保持画布尺寸一致，锚点才不会偏）' % os.path.relpath(new_abs_dir, BASE))
    print('  2) 想让它在设置里出现，往 Root.plist 的 Outfit 那条 cell 的 validValues/validTitles 各加一项')
    print('  3) 或者直接用「切换服装」手势循环到它（目录是动态发现的，不用重启）')


if __name__ == '__main__':
    main()
