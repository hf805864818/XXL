# 大肥鱼〇V〇 · 可编辑源码工程

从 `com.ojbkclub.petdfy_0.1.7_iphoneos-arm64e.deb` 逆向还原出来的完整源码树，
目标不是"能看"，而是**所有内容都能改**：换衣服、加素材、加新衣服、改布局与操作、发色自定义。

```
PetDFY_Editable/
├── src/Core/      渲染与桌宠核心（WN* 引擎 + PD* 宿主）
├── src/Sources/   AI 对话 / 设备工具 / 语音 / AX 抓取
├── src/Ext/       ★ 可编辑化扩展层（发色、服装目录、素材定位、布局配置、长发色面板）
├── src/Aux/       PDFYEnhance / PDFYSecurity 两个辅助 dylib（行为等价重建）
├── assets_src/    官方素材包原样（originals/ + live/model.json，可直接改）
├── layout/        安装树（原包 plist / 偏好包 / 素材清单）
├── tools/         加衣服 / 打包素材 / 校验 / 发色预览（纯标准库，无第三方依赖）
├── docs/          本目录
├── Makefile       Theos 工程（一次编译三个 dylib）
└── control        包描述（版本 0.1.8-editable）
```

![发色实测](img/hair_palette_2x2.png)

---

## 先看这里：你的诉求分别落在哪

| 你想做的事 | 去哪里改 | 需要重编译吗 |
|---|---|---|
| **1. 换衣服** | 设置 →「主题与服装 → 服装」，或长按宠物 → 切换服装（目录是动态发现的） | 不用 |
| **2. 添加新素材**（贴图/表情/主题） | `assets_src/originals/tex`、`feat`、`schemes/<主题>/` 放 PNG；或用 `tools/pack_assets.py` 打官方 ZIP | 不用 |
| **3. 添加新衣服** | `python3 tools/add_outfit.py --id 新名字 --from 模板`，再改那套的 PNG | 不用（目录动态发现） |
| **4. 改任何操作或布局** | `PDLayout.json`（尺寸/位置/锚点/手势映射/物理/气泡样式） | 不用 |
| **5. 头发颜色自定义** | 设置 →「发色」分页（10 预设 + HSV 滑杆），或长按宠物 →「发色」面板 | 不用 |

只有改 `src/` 里的 **代码逻辑** 才需要重新编译 + 安装。

---

## 五分钟上手

### A. 只想改内容（不编译）

设备上素材在：

```
/var/mobile/Library/Application Support/PetDFY.bundle/
├── originals/tex/*.png        身体/头发/脸/制服
├── originals/feat/*.png       表情（眼、嘴、高光、腮红）
├── originals/outfits/<名字>/   每套服装私有贴图
├── originals/schemes/<主题>/   品牌主题（chatgpt/claude/gemini/…）的 tex + feat
├── originals/thumbs/*.png     缩略图
├── live/model.json            装配后的模型（part 列表 + z 序 + 网格）
└── Whale.metal                渲染着色器源码（可直接改）
```

改完 PNG 后在桌宠上长按 → 面板，或在终端发命令（见 `docs/05`），贴图缓存会重建。

### B. 要重新编译整个包

```bash
export THEOS=~/theos                 # 需要 theos + iOS SDK
make clean package                   # 产出 .deb（含 layout/ 里的 plist 与偏好包）
make install THEOS_DEVICE_IP=手机IP   # 推到设备
```

详见 `docs/01_编译安装.md`。

---

## 逆向依据（不是猜的）

* 二进制定位：`PetDFY.dylib`（universal arm64+arm64e，2.5 MB）
  * **54 个自有类 / 1579 个方法**：用自研 Mach-O ObjC 解析器（`tools/macho_objc.py` 思路）直接读
    `__objc_classlist` / `class_ro_t` 相对方法表，逐条拿到 selector、type encoding、IMP 地址
  * 方法级还原度：**1579/1579（100%）**，其中 1413 显式实现、125 属性合成、41 编译器生成
  * 见 `docs/07_还原度报告.md`
* 素材格式：从 `live/model.json`、`figure.json`、`asset-manifest.json` 实测反推
  * `content_sha256 = sha256( 排序后逐行 "<path>:<sha256>\n" )`，`asset_version = 前 16 位`
  * `tools/pack_assets.py` 用这条公式**逐字节复现**了官方 `ad294eba347cbc43…`（见验证输出）
* 着色器：`Whale.metal` 是资产包里的源码字符串
  * 已有 `Appearance.tint` 通道：`c.rgb = mix(c.rgb, c.rgb * tint.rgb, tint.a)`
  * 发色功能就建立在"贴图重着色 + liveTextures 注入"上，不动着色器与管线，命中蒙版不受影响

---

## 我改了什么（相对原版）

1. **发色自定义**（新）：`PDHairTint`（HSV 重着色引擎）+ `PDHairTintPanel`（运行时面板）
   + 设置里的「发色」分页（纯 plist specifier，不需要编偏好包）
2. **服装目录动态发现**（改）：`PDOutfitCatalog` 取代写死的 `@[@"maid",@"cape",@"crew",@"sailor"]`
   和偏好白名单 `@[@"maid"]`
3. **素材候选链**（改）：`PDTextureResolver` 取代单条模板，支持 `outfits/<名>/`、主题回退、用户素材包
4. **布局/操作外置**（新）：`PDLayoutConfig` + `PDLayout.json`
5. **设置即时生效**（改）：原实现没有任何监听，改完必须注销；现在挂 Darwin 通知热重载
6. **两个辅助 dylib**（补）：`PDFYSecurity`（18 条 chmod 逐条还原）、`PDFYEnhance`（行为等价重建）

---

## 已知差异（别被"100%"骗了）

方法级 100% 覆盖不等于逐指令等价。已实测确认的简化集中在**边缘路径**：

* `WNLiveRig renderPointToStage:` / `point:deformer:` — 变换被简化；核心装配在 `WNLiveRig+Mesh.m`（3673 条指令，完整）
* `WNRenderer encodeClip:` / `drawMesh:` — 没提交 `Appearance` uniform（剪裁矩形与 tint 未生效），
  但发色走贴图注入，不依赖它
* `WNPainter newOverlayForRig:background:` 等 3 个合成接口为近似实现
* `PDFYEnhance` 的重投递节奏、`PDFYSecurity` 的标记文件内容属推断，已在源码里用注释标出

`tools/semantic_audit.py` 可以随时重跑这套抽查（按指令数 vs 源码行数找可疑桩）。

---

## 常用命令速查

```bash
# 素材体检（4 套服装 × 8 主题 × PNG 格式 × 头发齐全性）
python3 tools/validate_assets.py --root assets_src

# 加一套新衣服（克隆 sailor）
python3 tools/add_outfit.py --id school --from sailor --title 校服

# 打包成官方格式素材 ZIP（可直接给 App 的「从文件导入 ZIP」）
python3 tools/pack_assets.py --src assets_src --out build/assets

# 电脑上先看发色效果（不用刷机）
python3 tools/recolor.py -i assets_src/originals/tex/hair_back.png \
    -o /tmp/pink.png --preset sakura
python3 tools/recolor.py --palette assets_src/originals/tex/bangs.png \
    --palette-out /tmp/palette.png

# 还原度矩阵 / 桩审计
python3 tools/coverage_report.py
python3 tools/semantic_audit.py
```
