# 编译与打包指南 (Build & Packaging)

本文记录 **Pinny** 的图标资源生成、Release 优化编译、稳定证书签名打包与本地安装流程。

## 1. 重新生成图标与工具栏资源

### 应用图标与菜单栏光圈图标
Pinny 的应用图标（`Snapzy/PinnyIcon.icon`）与菜单栏图标（`MenubarIcon.imageset`）由 `scripts/generate-pinny-icon.py` 生成：

```bash
brew install librsvg   # 首次运行需提供 rsvg-convert
python3 scripts/generate-pinny-icon.py
```

生成产物：
- `Snapzy/PinnyIcon.icon/Assets/Aperture.svg`：Icon Composer 前景层（Hugeicons Pro `Aperture` Solid Rounded）
- `Snapzy/Resources/Assets.xcassets/MenubarIcon.imageset/*.png`：菜单栏模板图标（保持 `75.28%` 占空比）
- `../build/pinny-icon-preview.png` 与仓库根目录 `banner.png`：`1024 × 1024` 预览图

### 内联截图工具栏图标
内联工具栏的主栏与二级属性栏矢量图标由 `scripts/generate-toolbar-icons.py` 生成：

```bash
python3 scripts/generate-toolbar-icons.py
```

生成产物写入 `Snapzy/Resources/Assets.xcassets/CaptureTool-*.imageset`（详见 [HUGEICONS.md](HUGEICONS.md)）。

---

## 2. 编译 Release 优化版

Pinny 正式自用包统一采用 `Release` 配置编译（开启 `-O` 与整模块优化，大幅降低空闲内存与 `F1` 浮层内存开销）：

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

编译产物位于：`../build/release/Build/Products/Release/Snapzy.app`。

---

## 3. 打包并重签名为 `Pinny.app`

使用 `scripts/package-preview.py` 将编译产物打包为 `Pinny.app` 并使用本机稳定开发证书签名：

```bash
python3 scripts/package-preview.py --identity 'V2Do Dev' --configuration Release
```

- **切勿使用 ad-hoc 签名（`-`）安装**：ad-hoc 签名每次重编译都会改变标识，导致 macOS TCC 权限（屏幕录制、辅助功能）失效。
- **同证书 + 同 Bundle ID 保持权限**：只要保持 Bundle ID 为 `com.tianruian.openshot.preview` 且使用同一稳定证书签名，覆盖安装后系统权限自动保留。
- **禁用上游更新**：脚本会自动移除 `Info.plist` 中的 `SUFeedURL` 并将 `SUEnableAutomaticChecks` 设为 `false`。
- **输出位置**：`../build/preview-staged/Pinny.app`（脚本每次直接覆盖该 staged 副本，不留多余副本以免干扰 Launch Services）。

---

## 4. 安装到 `/Applications/Pinny.app`

本机唯一安装位置为 `/Applications/Pinny.app`：

```bash
# 1. 退出当前运行的 Pinny
osascript -e 'tell application id "com.tianruian.openshot.preview" to quit'

# 2. 备份旧包（仅保留单份 .bak 回退包，删除更早的备份）
ditto /Applications/Pinny.app ../build/preview/Pinny.before-update.$(date +%Y%m%d).app.bak

# 3. 安装新包并启动
ditto ../build/preview-staged/Pinny.app /Applications/Pinny.app
open /Applications/Pinny.app
```

安装完成后，请确认：
1. **设置 → 权限**：屏幕录制、保存文件夹访问权限、辅助功能均为「授予」；
2. **设置 → 截图**：自动检测窗口、识别窗口内部元素两个开关均为开启状态。
