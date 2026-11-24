# XiaoXiong 1.5.5 与 T3 功能对比统计

**对比对象**
- **T3** = `源码完整版.tar`（`com.ojbkclub.petdfy`，0.1.8-editable，骨骼引擎）
- **XX** = `XiaoXiongPetDFY-1.5.5-source 2`（`com.minis.petdfy`，1.5.5，分层引擎）

**方法**：统计 `.m/.c` 文件的类定义、行数、功能关键词命中、设置页文案；不含素材与二进制。
**日期**：2026-11-24　**口径**：`Observed`（代码实测）

---

## 0. 一句话结论

**这不是"新旧两个版本"，是两条独立产品线。**

- **零个同名类**（T3 全是 `PD*`/`WN*`，XX 全是 `DFY*`），代码不能互相覆盖替换。
- **T3 代码量是 XX 的 2.75 倍**（37,179 行 vs 13,482 行），因为它把骨骼渲染、MCP/AX 抓取做到了很深的程度。
- **XX 的功能面更宽**：它有你素材需要的帧动画与分层渲染，有可重编的设置页源码，有三越狱适配，有 152 个工程脚本。
- **两边的强项几乎互补**，不是同一维度的竞争。

---

## 1. 规模对照

| 指标 | T3 | XX 1.5.5 | 比值 |
|---|---:|---:|---|
| `.m/.c` 文件 | 74 | 57 | 1.30 |
| 代码行数 | 37,179 | 13,482 | **2.76** |
| 类数 | 71 | 62 | 1.15 |
| 同名类 | **0** | **0** | — |
| 头文件 | 63 | 68 | 0.93 |
| 工具脚本 | 14 | **152** | 0.09 |
| 打包/校验脚本 | 无（靠 theos） | `build.sh` + `verify_deb.sh` + 可复现构建 | — |

### 1.1 代码量分布

| T3 分组 | 文件 | 行数 |
|---|---:|---:|
| `WN*` 渲染引擎（11 类 + HairTint 扩展） | 21 | **9,472** |
| `PDNative_MCP*`（AX/MCP 桥） | 7 | **5,217** |
| `PDChat*` / `PDAI*`（对话） | 6 | 6,876 |
| `PDNative_*`（设备：屏幕/剪贴板/App/HID/输入） | 7 | 4,696 |
| `PDVoice*` / `PDDoubao*` / `PDCloudVoice*`（语音） | 7 | 2,357 |
| `PDHairTint*`（发色） | 2 | 799 |
| `PDLayout*`（布局外置） | 1 | 214 |
| 其它（宿主/视图/控制器/偏好/音效） | 23 | 7,548 |

| XX 分组 | 文件 | 行数 |
|---|---:|---:|
| `DFYPet*` / `DFYHost` / `DFYWindow`（视图宿主） | 3 | **2,149** |
| `DFYPrefs` / `DFYPages` / `DFYAssetManagerController` / `DFYToolPermissionController`（设置页） | 4 | **2,575** |
| `DFYTool*` / `DFYTask*`（工具与任务） | 4 | 1,586 |
| `DFYAI` / `DFYChat*` / `DFYVoice`（对话与语音） | 5 | 1,425 |
| `DFYAsset*`（素材库） | 2 | 908 |
| `DFYClip*`（帧动画） | 3 | 870 |
| `DFYLayered*`（分层渲染） | 1 | 548 |
| 其它 | 35 | 3,421 |

---

## 2. 能力域矩阵（22 项）

`●` 完整 / `◐` 部分 / `○` 无

| # | 能力 | T3 | XX | 谁更强 | 依据 |
|---|---|:--:|:--:|---|---|
| 1 | 骨骼网格渲染（mesh + 变形器） | ● | ○ | **T3** | `mesh` 68 处、`deformer` 46 处、11 个 WN 类 |
| 2 | Metal 管线 | ● | ○ | **T3** | `Metal` 39、`MTLDevice` 8；XX 无 Metal |
| 3 | 分层贴图渲染（sprite 叠层） | ○ | ● | **XX** | `Layered` 29 处，`DFYLayeredView` 548 行 |
| 4 | 换装（骨骼模型） | ● | ○ | **T3** | `model.json` 15 个 model，`outfit` 122 处 |
| 5 | 换装（分层目录） | ○ | ● | **XX** | `DFYAssetStore` 41 KB，`outfits/` 目录驱动 |
| 6 | **逐帧动作（clips.plist + frames）** | ○ | ● | **XX** | `clips.plist` 15 处、`frames/` 5 处；T3 均 **0** |
| 7 | 帧动画浏览 UI | ○ | ● | **XX** | `DFYClipBrowser` 29 KB + `DFYClipCell`/`Section`/`Entry` |
| 8 | 发色自定义 | ● | ○ | **T3** | `HairTint` 108 处 + 面板 UI |
| 9 | 布局外置（PDLayout.json） | ● | ○ | **T3** | `PDLayoutConfig` 214 行 |
| 10 | 分层素材包（layered manifest） | ○ | ◐ | **XX** | `DFYLayeredView` + `build_layered_plugin128.py` |
| 11 | AI 对话 | ● | ● | 平 | T3 6,876 行 / XX 1,425 行；T3 更厚 |
| 12 | 豆包 TTS + SSE 流 | ● | ○ | **T3** | `Doubao` 65、`SSE` 19；XX 无 |
| 13 | 语音输入 | ● | ◐ | **T3** | `PDCloudVoiceInput`；XX 用 `DFYSystemDictation` |
| 14 | **MCP / AX 设备操控桥** | ● | ○ | **T3** | `MCP` 351、`AXUIElement` 201、6 个 `PDNative_MCPAX*` 类；XX **MCP=0** |
| 15 | 工具注册与权限 | ◐ | ● | **XX** | `DFYToolRegistry` + `DFYToolDispatcher` + `DFYToolPermissionController` |
| 16 | 剪贴板 / 应用管理 / 屏幕 / 键盘 / 手势 | ● | ● | 平 | 两边都有，T3 更细 |
| 17 | **设置页可编程性** | ○ | ● | **XX** | T3 纯 plist 46 项；XX 代码 UI 132 条文案、24 处 UITableView |
| 18 | 素材管理 UI（缩略图/导入/移除） | ○ | ● | **XX** | `DFYAssetManagerController` 32 KB |
| 19 | 提醒 / 记忆导出 | ○ | ● | **XX** | `DFYReminder*`、`DFYMemoryStore`、"导出长期记忆" |
| 20 | **三越狱适配** | ○ | ● | **XX** | postinst 探 `/var/jb` + `.jbroot-*` |
| 21 | 可复现构建 | ○ | ● | **XX** | 两次构建 SHA256 相同；ar 头 mtime 归一 |
| 22 | 安装自检 / 验收脚本 | ○ | ● | **XX** | `verify_deb.sh` 查 fat、签名、`.jbroot` 链接 |

**统计**：T3 领先 8 项，XX 领先 10 项，平 4 项。

---

## 3. 渲染架构：两套根本不同的路

```
T3（骨骼）
  model.json(models.maid.parts 34 个)
    → WNLiveRig 骨骼 + WNPreparedDeformer 变形器
    → WNMesh 网格顶点（CPU 计算）
    → WNPainter 用 CoreGraphics 光栅化到两层位图
    → WNRenderer 上传 Metal 纹理 + 着色器合成
    → MTKView 上屏
  特点：部件级形变（眨眼、摇摆、拖拽甩飞）、可按部件换贴图、可发光/命中遮罩

XX（分层）
  originals/tex + outfits/<id>/*.png
    → DFYLayeredView 按 z 序叠 sprite
    → 每帧只改位置/缩放/透明度
    → CALayer/CG 直接上屏
  特点：整图拼贴、帧序列播放流畅（24fps）、换装 = 换 sprite 图集
```

**这个差异决定了可移植性**：T3 的那些"部件级"能力，在分层架构里没有对应概念。

---

## 4. 设置页与素材管理（二开的关键）

| 项 | T3 | XX |
|---|---|---|
| 形态 | `Root.plist` 46 项（纯 plist） | 代码 UI：`DFYPrefs.m` 57 KB + `DFYPages.m` 23 KB |
| 二进制 | 原版 846,688 B，不含源码 | **源码在包内**，可重编 |
| 中文文案 | plist 里 labels | **132 条**（去重） |
| 表格视图 | 无（系统渲染） | 24 处 `UITableView` |
| 弹窗/子页 | `PSLinkCell` 跳转 | 10 处 `presentViewController` |
| 动态列表 | 做不到 | 可以（模型列表刷新、素材扫描） |
| 素材管理 | 无 UI（只有「下载」入口） | `DFYAssetManagerController` 32 KB，带缩略图与导入 |
| 帧动画浏览 | 无 | `DFYClipBrowser` 29 KB |
| 提醒/记忆 | 无 | 有（50 条上限、导出到剪贴板） |

XX 设置页里能看到的功能（从文案提取）：启用大肥鱼、设备操控授权、截图发模型、目标 App 范围、单次任务时限、记忆与人设（称呼/清空/导出）、提醒（新增/查看/清空）、手势映射、模型选择（含刷新模型列表、手动填 ID、备用模型）。

---

## 5. 越狱与工程化

| 项 | T3 | XX |
|---|---|---|
| 依赖声明 | `mobilesubstrate` 硬依赖 | `mobilesubstrate | ellekit | libhooker` |
| rootless | 不支持（标准 rootful 打包） | postinst 探测 `/var/jb` |
| roothide | 不支持 | 探测 `.jbroot-*`，多候选拒绝盲选 |
| 安装日志 | 无 | 私有目录 0700 + 文件 0600 |
| 版本管理 | 手改 `control` | `version.txt` 单一来源，注入 control + bundle 双版本号 |
| 构建 | theos `make package` | `build.sh`（工具链自探测 + 组装 + 归一 mtime + dpkg-deb） |
| 校验 | 无 | `verify_deb.sh`（fat / 签名 / `.jbroot` 链接 / postinst 可执行） |
| 可复现 | 未验证 | 两次构建 SHA256 相同（`45886a25…`） |
| 商店页 | 无 | `depiction/`（sileo.json + changelog.json + 模板） |

---

## 6. T3 的功能能不能搬到 XX 上（四类）

### 6.1 直接移植（低风险，不依赖渲染架构）

| 能力 | 规模 | 说明 |
|---|---|---|
| **MCP / AX 桥** | 7 文件 / **5,217 行** | `PDNative_MCPAX*` 是独立的 AX 抓取→序列化层，只依赖 `AXUIElement`，与渲染无关。XX 现在 `MCP=0`，搬过去等于给它加一整套设备操控 API |
| 布局外置 | 1 文件 / 214 行 | `PDLayoutConfig` + JSON，可映射到 `DFYAppearance`/`DFYTheme` |
| 豆包 TTS + SSE 解码 | 2 文件 / 约 900 行 | XX 只有 `DFYVoice`，没有 SSE 流式与音色参数 |
| 落盘日志 / 诊断 | 约 400 行 | 两边都缺，建议共用 |

### 6.2 需要改造（中风险）

| 能力 | 规模 | 改造点 |
|---|---|---|
| 发色 | 2 文件 / 799 行 | T3 作用于 `liveTextures`（Metal 纹理缓存），XX 要改成对 `DFYLayeredSprite` 的 CGImage 重着色；**HSV 算法本身可原样复用**，注入点要换 |
| 语音输入 | 约 1,400 行 | T3 的 `PDCloudVoiceInput` 与 XX 的 `DFYSystemDictation` 功能重叠，择优合并 |
| 骨骼动作状态机 | — | `WNMotion`（6 文件）里的走/跑/跳/重力逻辑，XX 用 `DFYMotion.c` + `DFYDeviceMotion`，只能参考思路 |

### 6.3 不建议移植（高风险，等于重写）

| 能力 | 规模 | 原因 |
|---|---|---|
| **骨骼渲染引擎** | 21 文件 / **9,472 行** | `WNLiveRig` + `WNMesh` + `WNPainter` + `WNRenderer` 是一整套 CPU 装配 + Metal 合成，与 layered 架构互斥。搬过去要么替换整个渲染层，要么两套并存（内存与窗口都打架） |
| Metal 着色器 | `Whale.metal` + 管线 | 同上 |

### 6.4 反向需要（XX 有，T3 没有，本来就是这次要做的）

| 能力 | 规模 | 说明 |
|---|---|---|
| 帧动画 | 3 文件 / 870 行 | 这正是 e4 要补的；有了 XX 的 `DFYClipCatalog`，**不用再从 T1 的 `PDFramePlayer` 改造** |
| 分层渲染 | 1 文件 / 548 行 | 如果 T3 要吃 layered 素材，这是最短路径 |
| 设置页源码 | 4 文件 / 2,575 行 | T3 只有二进制，要二开就得有它 |
| 三越狱 postinst | 1 脚本 | T3 完全没有 |

---

## 7. 工作量估算

| 做法 | 工作内容 | 相对成本 |
|---|---|---|
| 以 XX 为主线，补 T3 强项 | 移植 MCP（5,217）+ 发色改造（799）+ 布局（214）+ 豆包（900） ≈ **7,100 行** | **1.0×** |
| 以 T3 为主线，补 XX 强项 | 帧动画（870）+ 分层（548）+ 设置页（2,575）+ 越狱（脚本）+ 工具链 ≈ **4,000 行 + 大量脚本** | 1.2×（行数少但设置页/越狱是硬骨头） |
| 双线并行 | 两套都维护 | 2.5× 以上 |

> 关键差别不在行数，在**风险**：
> - XX 主线 = 拿现成的素材格式与设置页，风险集中在"能不能编过"；
> - T3 主线 = 要自己啃设置页（无源码）和多越狱（无参考），风险集中在"二开受限"。

---

## 8. 结论

1. **功能上不是谁全面碾压谁**：T3 在"渲染精细度 + AI/MCP 深度"上明显更强，XX 在"素材生态 + 设置页 + 越狱 + 工程化"上明显更强。
2. **你的素材站在 XX 这边**（`package: com.minis.petdfy`），15 套服装 / 116 动作 / 小白龙 12 动作都是给它做的。
3. **T3 的功能可以在 XX 上开发**，但要看是哪一块：
   - MCP/AX、布局、豆包 TTS → **能搬，风险低**
   - 发色 → **能搬，算法复用、注入点重写**
   - 骨骼渲染 → **不建议**，等于换掉整个渲染层
4. **推荐路线**：XX 1.5.5 做主线，把 T3 的 MCP 桥与发色作为后续增强（e7/e8）；T3 保留为"骨骼渲染"参考实现，不并行维护。
5. **前置动作**：先验证 XX 1.5.5 能否在 CI 编出包（`NOT RUN`）。这一步不通，后面都无从谈起。

---

## 9. 结论更新：主线定为 T3（2026-11-24）

### 9.1 为什么最终选 T3

上一版结论推荐"XX 做主线"，依据是三条：素材格式、设置页源码、多越狱。这三条在后续核查中被逐条修正：

| 原依据 | 修正后 |
|---|---|
| 素材格式不匹配 | **服装同构**（`live/model.json` 的 15 个 model + `originals/outfits/<id>/` 与 T3 的 `WNLiveRig`/`PDTextureResolver` 完全对得上），只差 3 处断点 |
| 动作要重做 | 动作**只差一个播放器**：`WNPainter` 已有 `draw:context:rect:` 与 `sprite:context:options:`，画整帧位图是现成能力 |
| 设置页不能二开 | T3 的 UI 二开**不走设置页**，走运行时面板（`PDHairTintPanel` 已证明可行，且与 plist 共享 CFPreferences 键） |
| 多越狱要自己写 | 这条仍成立，但成本是"照抄一个 postinst 脚本"，不是架构问题 |

**结论：T3 主线的风险是"工作量"，XX 主线的风险是"放弃骨骼渲染与 MCP 深度"。前者可控，后者不可逆。**

### 9.2 XX 的能力在 T3 上的落地方式（18 项）

| # | XX 能力 | T3 基础 | 方案 | 工作量 |
|---|---|---|---|---|
| 1 | 帧动画 | `WNPainter.draw:`/`sprite:` | 新写 `PDClipPlayer` | 400–600 行 |
| 2 | 帧浏览 UI | `PDHairTintPanel` 范本 | 新写 `PDClipPanel` | 300–500 行 |
| 3 | 素材管理 UI | `PDZip` + `PDAssets` | 新写 `PDAssetPanel` | 300–500 行 |
| 4 | 分层渲染 | — | **不需要** | 0 |
| 5 | 设置页源码 | 运行时面板替代 | 见 §15 路线 | — |
| 6 | 工具注册/权限 | `PDDeviceTools` + 7 个 MCP 类 | 加权限门控 | 200–300 行 |
| 7 | 提醒 | `PDAIAlarms` | 扩成提醒系统 | 150–300 行 |
| 8 | 记忆导出 | `PDAIMemory` | 加导出入口 | ~100 行 |
| 9 | 模型选择器 | `Provider.plist` 静态项 | `PDModelPanel` | ~200 行 |
| 10 | 音乐监控 | 无 | 新写 | 200–300 行 |
| 11 | 截图发模型 | `PDNative_ScreenManager` | 接进对话链路 | 沿用 |
| 12 | 任务代理 | MCP 工具链 | 等价 | 沿用 |
| 13 | 三越狱 postinst | 无 | 照抄逻辑 | 1 脚本 |
| 14 | 可复现构建 + verify | 无 | 抄进 CI | 1 脚本 |
| 15 | 点击/运动 | `WNMotion` 6 文件 | **不需要** | 0 |
| 16 | 主题/外观 | `schemes` 7 套 | **不需要** | 0 |
| 17 | 输入桥 | `PDNative_TextInputManager` | **不需要** | 0 |
| 18 | Keychain | `无（PDFYSecurity）` | 可选补 | 150 行 |

合计 **1,800–2,500 行新增**，其中 4 个面板 + 1 个播放器占 1,200–1,800 行，全部是新增文件，不动现有渲染代码。

### 9.3 那个 846 KB 设置页二进制的真相

| 项 | 实测 |
|---|---|
| 架构 | fat：arm64 + arm64e |
| 自定义类 | **18 个** |
| 方法 | 439 条（566 个 selector 引用） |
| 内嵌文案 | **100,428 字节 UTF-16**（含 AI 工具 JSON） |
| 语言 | Objective-C，无 Swift，无壳无加固 |
| 符号 | 仅 293 个导出（strip 过） |

**能重编**（ObjC 元数据齐全），但有三个坎：私有偏好框架头文件要自建、Preferences 进程签名（历史事故：改个名字没重算 CodeDirectory → 设置页点不进去）、几十个 CFPreferences 键必须与主 dylib 一致。工作量约 1–2 周，且坏掉后用户无法自救。

**决策：不重编**。新 UI 全部走运行时面板，设置页只留 plist 能表达的静态项。

### 9.4 最终路线

```
T3（主线，唯一维护）
  ├─ e1 编译通过
  ├─ e2 单套 maid 出画面
  ├─ e3 15 套服装
  ├─ e4 帧动画 + 116 动作 + 小白龙角色
  ├─ e5 合并 T1/T2 功能
  ├─ e6 三越狱兼容
  ├─ e7 面板扩展（4 个新面板）
  └─ e8 设置页是否重写 —— 到时再评估，默认不做

XX 1.5.5（只读参考，不并行维护）
  └─ 需要时借：clips 解析思路、postinst 三根探测、verify_deb 脚本
```
