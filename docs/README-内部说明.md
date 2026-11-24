# PetDFY / 大肥鱼〇V〇 — 可编译工程（T3 基线）

由「源码完整版（0.1.8-editable）」整理而来，用 GitHub Actions 自动编译出 **arm64 + arm64e** 的 deb。

- 包名：`com.ojbkclub.petdfy`
- 注入：`com.apple.springboard`
- 偏好域：`com.susudear.petdfyprefs`

---

## 1. 目录

```
.
├── Makefile                     Theos 工程（三个 dylib）
├── control                      包元数据（Version 0.1.8-e1）
├── src/
│   ├── Core/                    渲染与桌宠核心（WN* + PD*）
│   ├── Sources/                 AI / 语音 / 设备操控 / AX
│   ├── Ext/                     可编辑化扩展（发色 / 布局 / 服装目录 / 贴图链）
│   ├── Auxiliary/               PDFYEnhance + PDFYSecurity
│   └── PetDFY.h                 伞形头文件
├── layout/                      安装树（原版 plist / 偏好包 / petdfy-voice）
├── assets_src/                  运行时素材（originals/ + live/model.json）
├── patches/                     e2 起的补丁（见第 5 节）
├── tools/                       素材与还原度脚本
├── docs/                        12 篇工程文档
└── .github/workflows/build.yml  CI
```

> `src/Aux` 是 Windows 保留设备名，仓库里统一叫 `src/Auxiliary`，Makefile 已同步。

---

## 2. 触发构建

推送到 `main` 即自动构建，或在 Actions 页点 **Run workflow**。

```bash
git add -A
git commit -m "e1: T3 baseline"
git push origin main
```

**只对代码生效**（`paths-ignore`）：`src/**`、`layout/**`、`assets_src/**`、`Makefile`、`control`、workflow 改动会触发；
任何 `.md`、`docs/**`、`MEMORY/**` 改动**不会**触发，不浪费 Actions 分钟。

**版本号自动递增**：`control` 里的 `Version` 是 base（人维护），CI 每次加 `+build.NNN`：

```
0.1.8-e1  →  0.1.8-e1+build.042
```

产物：Actions → 对应 run → Artifacts → `PetDFY-0.1.8-e1+build.042.zip`
里面含 `*.deb`、三个 `*.dylib`、`SHA256.txt`。

---

## 3. 安装

```bash
scp PetDFY_0.1.8-e1_iphoneos-arm64e.deb root@<设备IP>:/var/mobile/
ssh root@<设备IP>
dpkg -i /var/mobile/PetDFY_0.1.8-e1_iphoneos-arm64e.deb
killall -9 SpringBoard
```

回退（原版基线随时可装）：

```bash
dpkg -i com.ojbkclub.petdfy_0.1.7_iphoneos-arm64e.deb
```

---

## 4. e1 能做什么、不能做什么

**能**：编译通过、出 deb、装上去、注入 SpringBoard、设置页可开、素材已进包。

**不能**：**桌面不会出现角色**。

原因（已定位，不是编译问题）：`src/Core/WNLiveRig.m` 里加载 `live/model.json` 的代码写在了 `return self;` **之后**，永远执行不到，导致 `rig.model == nil` → 部件列表为空 → 没有网格可画。

| | 现象 |
|---|---|
| 装完没角色 | 正常，e1 的已知限制 |
| 设置页能进 | 说明注入与偏好包正常 |
| 日志里无 `[PetDFY] model injected` | 证实上面那条 |

---

## 5. e2：让角色显示出来（必做）

`patches/WNLiveRig.m.e2` 是补好 model 注入的完整文件，直接覆盖：

```bash
cp patches/WNLiveRig.m.e2 src/Core/WNLiveRig.m
git commit -am "e2: inject live/model.json into WNLiveRig"
git push
```

它会：

1. 在 `init` 返回前读 `live/model.json` 的 `models.<outfit>`
2. 同时兼容 `NSDictionary`（实测素材）与 `NSArray`（旧格式）
3. 把 `parts` / `deformers` / `view` 注入 `_model` 与 `_sourceModel`
4. 打一行日志：`[PetDFY] model injected: outfit=maid parts=34 deformers=…`

看到这行日志 + 桌面出现角色，e2 就算通过。

查看日志：

```bash
log stream --predicate 'process == "SpringBoard"' --level debug | grep PetDFY
```

---

## 6. 后续版本（对应实施方案）

| 版本 | 内容 | 状态 |
|---|---|---|
| e1 | 编译通过、出包 | 本仓库当前 |
| e2 | 单套 maid 出画面（model 注入） | 补丁已附 |
| e3 | 15 套服装白名单 + 逐套验收 | 待做 |
| e4 | 帧动画引擎（素材 A 116 组 / 小白龙 12 组） | 待做 |
| e5 | 合并 T1 运维件与 T2 安全件 | 待做 |

15 套白名单改 `layout/Library/PreferenceBundles/PetDFYPrefs.bundle/Root.plist` 的 `Outfit.validValues`（4 项 → 15 项），设置页二进制不用重编。

---

## 7. 常见失败

| 现象 | 原因 | 处理 |
|---|---|---|
| `Makefile:1: *** missing separator` | 原 Makefile 用 `//` 注释 | 本仓库已修成 `#` |
| `error: no such SDK` | Theos 没装 sdks | workflow 会自动 clone `theos/sdks` |
| `ld: library not found for -lsubstrate` | runner 上 substrate 缺失 | workflow 有 fallback 步骤自动改 `dynamic_lookup` |
| `dpkg-deb: command not found` | 缺 dpkg | workflow 里 `brew install dpkg` |
| arm64e 链接报错 | SDK 版本太老 | `TARGET` 用 `iphone:clang:latest:16.0`，确保 sdks 里有 16.5+ |
| 装完进设置页闪退 | RootHide/rootless 环境路径不符 | 试 `make package THEOS_PACKAGE_SCHEME=rootless` |
| 有角色但缺贴图 | 素材没进包 | 确认 `make assets` 跑过；检查 `layout/.../PetDFY.bundle/originals/` |

---

## 8. 素材说明

`assets_src/` 来自「素材 A」（116 动作全量包）的 `originals/` + `live/`，32.9 MB：

- 基础贴图：`originals/tex/`（325 个扁平化贴图）
- 表情：`originals/feat/`
- 服装：`originals/outfits/<id>/`（14 套，maid 用扁平 tex）
- 配色：`originals/schemes/<name>/`（7 套）
- 模型：`live/model.json`（15 个 model）+ `originals/model.json`（26 parts + 15 outfits）

素材包的 `frames/`（逐帧动作）**没有**放进本仓库：e4 做帧动画时再单独引入（81 MB，不适合常驻 git）。

---

## 9. 仓库规范（三条铁律）

完整说明见 [`MEMORY/00-项目约定.md`](MEMORY/00-项目约定.md)，决策理由见 [`MEMORY/01-决策记录.md`](MEMORY/01-决策记录.md)。

| 铁律 | 规则 | 实现位置 | 怎么验证 |
|---|---|---|---|
| 1 | 代码变更才编译，文档不触发 | `build.yml` 的 `on.push.paths-ignore` | 改一个 `.md` 推上去，Actions 应无新 run |
| 2 | 每次编译自动递增版本号 | `build.yml` 的 `Compute version` | deb 文件名带 `+build.NNN`，Summary 里有版本 |
| 3 | 每次推送补记忆点 | CI 追加 `MEMORY/03-构建日志.md` + 人工补 `02-阶段进度.md` | Actions 跑完，构建日志多一行 |

### 记忆点目录

```
MEMORY/
├── README.md          怎么用、什么时候写哪份
├── 00-项目约定.md     三条铁律 + 版本阶段对照
├── 01-决策记录.md     D-1 … D-8
├── 02-阶段进度.md     e1 … e5 状态与可观察判据
├── 03-构建日志.md     CI 自动追加
├── 04-已知问题.md     B1-B7 / M1-M5 / 踩坑
└── 05-素材规格.md     三类素材、15 套、116/12 组、路径契约
```

**推送前自检**：这一步做完了什么？一句能写进 `MEMORY/02-阶段进度.md` 的话写出来了吗？写不出来，说明还没做完。

### 实施方案

完整方案见 [`docs/实施方案-T3完整化.md`](docs/实施方案-T3完整化.md)（决策、阶段判据、风险与回退）。
