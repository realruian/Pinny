<div align="center">
  <img src="./banner.png" width="160" height="160" alt="Pinny icon" />

  <h1>Pinny</h1>
  <p><strong>原生 macOS 原位截图、标注与纯图贴图工具</strong></p>

  <p>
    Built with <a href="https://developer.apple.com/xcode/swiftui/">SwiftUI</a>,
    <a href="https://developer.apple.com/documentation/appkit">AppKit</a>, and
    <a href="https://developer.apple.com/documentation/screencapturekit">ScreenCaptureKit</a>.
  </p>

  <p>
    <a href="#核心特性">核心特性</a> •
    <a href="#快捷键与交互">快捷键与交互</a> •
    <a href="#构建与安装">构建与安装</a> •
    <a href="#资源生成">资源生成</a> •
    <a href="#文档索引">文档索引</a> •
    <a href="#说明与许可">说明与许可</a>
  </p>
</div>

---

**Pinny** 是基于 [Snapzy](https://github.com/duongductrong/Snapzy) 深度定制的个人自用 macOS 截图与贴图工具，交互流程对齐 PixPin：将传统的「区域截图 / 窗口截图 / 全屏截图 / 标注」收敛为单一的 **原位截图主入口（`F1`）** 与 **剪贴板纯图贴图（`F2`）**，去除右下角中转卡片、录屏、云上传等冗余打断，专注极致流畅的截图、原位标注与屏幕钉图体验。

> [!IMPORTANT]
> 本仓库为**个人私有自用项目**（含个人授权的 Hugeicons Pro 图标资源），仅用于本地构建与自用备份，**不对外公开或分发**。

---

## 核心特性

### 1. 统一原位截图（`F1`）
- **单一主入口**：按下 `F1` 直接在当前屏幕唤起原位截图浮层（热启动首帧约 `85 ms`），无需事先区分“区域”、“窗口”或“全屏”模式。
- **智能界面块与窗口识别**：
  - 光标移动时自动高亮窗口与内部 UI 组件（默认优先面板级界面块，避免细碎文字/小图标干扰；全部 `AXUIElement` 查询在后台线程执行并设 `0.5 s` 超时，绝不阻塞主线程）。
  - 单击即可选中当前高亮的窗口或组件；也可直接按住鼠标拖拽手动框选区域。
  - 选区阶段支持按键快速切换：`R` 复用上次截图区域、`,` 依次切换最近截图区域、`Tab` 选中光标下整个窗口、`⌘A` 全屏。
- **无门槛直接调整**：
  - 默认「选择」工具下，直接在选区空白画面拖拽即可平移整个选区（无需按住空格）。
  - 选区四条完整边缘与四个角均可直接拖拽调整大小；支持方向键微调位置、`⌘/⌥ + 方向键` 逐像素扩缩四边。

### 2. 原位单栏标注
- **紧凑自适应工具栏**：
  - 工具栏默认贴靠在选区**下方**，仅当下方空间不足时自动切至选区上方；宽度按实际按钮紧凑包裹。
  - 主工具栏与二级属性栏全部采用 **Hugeicons Pro** 矢量图标（未选中为 `Stroke Rounded`，选中态自动切换为 `Solid Rounded`）。
- **标注工具集**：
  - 支持 **矩形、椭圆、填充矩形、箭头、直线、铅笔、荧光笔（支持自动对齐文字）、文字（固定使用苹方 `PingFang SC`）、九宫格模糊/像素化、聚光灯（Spotlight）、序号圆圈（Counter）、水印（©）**。
  - 再次点击当前已激活的标注工具按钮（或按对应数字键），可一键切回「选择」工具。
  - 已有标注随时可点击选中、拖拽移动、调整控制点或按 `⌫` 删除。

### 3. 瞬时产出（复制 / 钉图 / 保存）
- **复制（`↩` / 双击空白处 / 工具栏复制按钮）**：
  - 立即隐藏截图浮层，在后台完成原始分辨率图像渲染与编码并写入系统剪贴板，同时在剪贴板项中附带选区的屏幕坐标与逻辑尺寸元数据。
- **原位钉图（工具栏钉图按钮）**：
  - 直接从内存将当前选区（含标注）以**相同的屏幕位置、逻辑尺寸和像素内容**钉在屏幕上，像原画面一样无缝对齐（默认同时复制到剪贴板，可在贴图设置中开关）。
- **保存（`⌘S` / 工具栏保存按钮）**：
  - 默认保存至 `~/Downloads/Pinny`（全新安装默认为 `~/Desktop/Pinny`），文件名前缀为 `Pinny_`。

### 4. 纯图直角贴图（`F2` 与截图钉图完全统一）
- **`F2` 贴剪贴板图片**：
  - 将剪贴板中的图片（或复制的本地图片文件）直接贴到屏幕上（若 `F1` 刚触发后台复制，`F2` 会自动等待后台复制就绪后再贴出）。
  - **位置与尺寸恢复**：若剪贴板图片来自 Pinny 截图或贴图复制，自动按当时的屏幕位置与显示尺寸原位恢复；若为外部复制的图片，则在当前屏幕居中显示（小图保持原始逻辑尺寸不放大，超屏大图等比缩放适配屏幕）。
- **纯粹无干扰外观**：
  - 移除一切悬浮关闭按钮、缩放百分比浮层、锁定按钮与底部抽出栏，**贴图窗口仅显示直角图像本身**。
  - **交互一致**：直接拖拽移动位置；滚轮以光标为中心整图平滑缩放；**双击贴图即可复制其原始分辨率内容并关闭当前贴图**（关闭后再次按 `F2` 仍可按关闭前的位置和显示尺寸恢复）。

### 5. 精简设置与菜单栏
- **菜单栏**：光圈（Aperture）模板图标；菜单仅保留 `截图 (F1)`、`贴剪贴板图片 (F2)`、`设置`、`重新开始引导` 与 `退出`。
- **设置面板**：整理为 **通用 / 截图、标注、贴图 / 快捷键、权限、高级 / 关于** 共 7 页；原版录屏、视频编辑、云上传、历史面板、菜单栏定制及旧版多套全局快捷键已从界面退役隐藏。

---

## 快捷键与交互

### 全局快捷键

| 动作 | 默认快捷键 | 说明 |
| :--- | :--- | :--- |
| **截图** | `F1` | 打开统一原位截图浮层（自动识别窗口/组件、手动框选、原位标注） |
| **贴剪贴板图片** | `F2` | 将剪贴板中的图片或复制的图片文件贴到屏幕（支持恢复原坐标与尺寸） |

### 截图选区阶段（尚未确定选区时）

| 按键 / 操作 | 功能 |
| :--- | :--- |
| 鼠标移动 | 自动高亮光标下的窗口与界面块组件 |
| 左键单击 / 拖拽 | 选中当前高亮组件，或手动拖拽框选任意区域 |
| `R` | 复用上一次截图区域 |
| `,` | 依次切换最近使用过的截图区域 |
| `Tab` | 选中光标下的整个窗口 |
| `⌘A` | 选中当前整个显示器屏幕 |
| `C` | 复制放大镜当前指示像素的颜色值 |
| `⎋` (Esc) / 右键单击 | 取消截图并关闭浮层 |

### 选好区域后（调整与原位标注阶段）

| 按键 / 操作 | 功能 |
| :--- | :--- |
| 拖拽选区空白处 | 直接平移整个选区（选择工具下，无需按空格） |
| 拖拽选区四边 / 四角 | 直接调整选区范围 |
| `↑` `↓` `←` `→` | 按像素微调选区位置 |
| `⌘ + 方向键` | 向外扩展选区对应边缘 |
| `⌥ + 方向键` | 向内收缩选区对应边缘 |
| `1` – `9`、`0` | 切换标注工具（再次按下同一键切回选择工具） |
| `,` / `.` | 减小 / 增大当前标注工具描边粗细 |
| `↩` (Return) / 双击空白图像 | 复制原始分辨率截图并关闭浮层 |
| `⌘S` | 保存截图到导出目录（`~/Downloads/Pinny`） |
| `⌘Z` / `⇧⌘Z` | 撤销 / 重做标注 |
| `⌫` (Delete) | 删除当前选中的标注对象 |
| `⎋` (Esc) | 取消本次截图 |

### 贴图交互（Pin 窗口）

| 操作 | 功能 |
| :--- | :--- |
| 左键拖拽 | 移动贴图位置 |
| 鼠标滚轮 / 触控板双指滚动 | 以光标为中心等比缩放整张贴图 |
| **双击贴图** | **复制原始分辨率图像到剪贴板并关闭该贴图**（同时保留当前位置与显示尺寸供 `F2` 恢复） |
| `⎋` (Esc) | 关闭当前聚焦的贴图窗口 |

---

## 构建与安装

> **运行环境要求**：macOS 13.0+，Xcode 15.0+（Apple Silicon `arm64`）。

Pinny 日常安装使用 **Release 优化构建**（空闲内存约 `47 MB`，`F1` 浮层内存增量仅 `3–5 MB`），并通过本地稳定开发证书重签名，确保更新替换应用包后 macOS 的**屏幕录制（Screen Recording）**与**辅助功能 / 设备控制（Accessibility）**权限持续保留，无需重新授权。

### 1. 编译 Release 产物

在工作区根目录（仓库父目录）或仓库内执行：

```bash
xcodebuild -project Snapzy.xcodeproj \
  -scheme Snapzy \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath ../build/release \
  -clonedSourcePackagesDirPath ../build/packages \
  -disableAutomaticPackageResolution \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= \
  ONLY_ACTIVE_ARCH=YES \
  build
```

### 2. 使用稳定证书打包 `Pinny.app`

使用 `scripts/package-preview.py` 将编译好的 Release 包重写为 `Pinny` 身份并签名（切勿使用 ad-hoc 签名 `-` 覆盖安装，否则会导致 TCC 权限失效）：

```bash
python3 scripts/package-preview.py --identity 'V2Do Dev' --configuration Release
```

该脚本会自动完成以下处理并输出至 `../build/preview-staged/Pinny.app`：
- 将 `CFBundleIdentifier` 设为 `com.tianruian.openshot.preview`
- 将 `CFBundleName` 与 `CFBundleDisplayName` 设为 `Pinny`
- 移除 `SUFeedURL` 并禁用 Sparkle 自动检查更新（防止拉取原版 Snapzy 更新覆盖自用版）
- 使用指定的本地稳定证书完成 `--deep --strict` 签名校验

### 3. 安装与回退备份规范

本机唯一安装路径为 **`/Applications/Pinny.app`**（不要在多个目录保留相同 Bundle ID 的可启动副本，以免干扰 Launch Services 与权限关联）：

```bash
# 1. 退出正在运行的 Pinny
osascript -e 'tell application id "com.tianruian.openshot.preview" to quit'

# 2. 备份当前已安装版本（仅保留单份最新 .bak，清理更早的备份）
ditto /Applications/Pinny.app ../build/preview/Pinny.before-update.$(date +%Y%m%d).app.bak

# 3. 覆盖安装新包并启动
ditto ../build/preview-staged/Pinny.app /Applications/Pinny.app
open /Applications/Pinny.app
```

安装后可在 **Pinny 设置 → 权限** 与 **设置 → 截图** 中核对：
- 「屏幕录制」、「保存文件夹访问权限」、「辅助功能」状态均为 **已授予**；
- 「自动检测窗口」与「识别窗口内部元素」开关均为 **开启**。

---

## 资源生成

### 应用图标与菜单栏光圈图标
Pinny 使用 Hugeicons Pro 的 `Aperture`（相机光圈，Solid Rounded）作为应用前景图标（配合 macOS Icon Composer Liquid Glass 效果）与菜单栏模板图标：

```bash
# 需安装 librsvg (brew install librsvg) 与 Pillow
python3 scripts/generate-pinny-icon.py
```

脚本会同步生成：
- `Snapzy/PinnyIcon.icon/Assets/Aperture.svg`（Icon Composer 前景层）
- `Snapzy/Resources/Assets.xcassets/MenubarIcon.imageset/*.png`（菜单栏模板图，保持 `75.28%` 占空比）
- `../build/pinny-icon-preview.png` 与仓库根目录 `banner.png`

### 内联工具栏图标
内联截图工具栏主栏与二级属性栏图标由 `scripts/generate-toolbar-icons.py` 从本地 Hugeicons Pro 源生成：

```bash
python3 scripts/generate-toolbar-icons.py
```

详见 [docs/HUGEICONS.md](docs/HUGEICONS.md)。

---

## 文档索引

- [统一截图与纯图贴图工作流说明](docs/UNIFIED-CAPTURE.md)
- [Hugeicons Pro 工具栏图标生成说明](docs/HUGEICONS.md)
- [本地开发与调试指南](docs/DEVELOPMENT.md)
- [编译与打包指南](docs/BUILD.md)
- [项目文档总览与架构索引](docs/README.md)
- [源码目录与运行时架构](docs/STRUCTURE.md)

---

## 说明与许可

- **上游致谢**：本项目基于 [duongductrong/Snapzy](https://github.com/duongductrong/Snapzy)（[BSD 3-Clause License](LICENSE)）定制开发，截图与贴图交互参考 [PixPin](https://pixpinapp.com/)。
- **兼容性保留**：为保证内部模块与历史数据兼容，工程内部 target 名称、URL Scheme（`snapzy://`，触发时使用 `open -b com.tianruian.openshot.preview "snapzy://..."`）及应用支持目录（`~/Library/Application Support/Snapzy`）保持原名未改。
- **私有仓库约束**：仓库内包含账号所有者付费授权的 Hugeicons Pro 图标资源，**仓库必须保持 Private，严禁公开或向原作者上游仓库（`origin`）推送**。日常备份仅推送至个人私有远端 `mine`（`https://github.com/realruian/Pinny`）。
