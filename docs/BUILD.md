# 编译与打包指南 (Build & Packaging)

本文记录 **Pinny** 的一键编译安装脚本、图标资源生成、Release 优化编译与稳定证书签名打包流程。

## 1. 一键编译、签名与安装（推荐）

日常构建并更新 `/Applications/Pinny.app` 可直接运行：

```bash
./scripts/install-pinny.sh --identity 'V2Do Dev'
```

该脚本自动依次执行：
1. 编译 `Release` 优化版（`../build/release`）；
2. 调用 `scripts/package-preview.py` 将产物打包为 `../build/preview-staged/Pinny.app` 并使用指定证书签名验证；
3. 退出当前运行的 `Pinny`，将旧版 `/Applications/Pinny.app` 备份为 `../build/preview/Pinny.before-update.<日期>.app.bak`，覆盖安装并重新启动。

若仅需将已编译好的 `Release` 产物重新签名并安装，可加 `--skip-build`：

```bash
./scripts/install-pinny.sh --identity 'V2Do Dev' --skip-build
```

---

## 2. 重新生成图标与工具栏资源

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

### 内联截图与录屏工具栏图标
内联工具栏的主栏、二级属性栏与录屏操作栏矢量图标由 `scripts/generate-toolbar-icons.py` 生成：

```bash
python3 scripts/generate-toolbar-icons.py <hugeicons-pro-unpacked-dir>
```

生成产物写入 `Snapzy/Resources/Assets.xcassets/CaptureTool-*.imageset`（详见 [HUGEICONS.md](HUGEICONS.md)）。

---

## 3. 分步编译与打包说明

### 编译 Release 优化版

Pinny 采用 `Release` 配置编译（开启 `-O` 与整模块优化，大幅降低空闲内存与 `F1` 浮层内存开销）：

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

### 打包并重签名为 `Pinny.app`

使用 `scripts/package-preview.py` 将编译产物打包为 `Pinny.app` 并使用本机稳定开发证书签名：

```bash
python3 scripts/package-preview.py --identity 'V2Do Dev' --configuration Release
```

- **切勿使用 ad-hoc 签名（`-`）安装**：ad-hoc 签名每次重编译都会改变标识，导致 macOS TCC 权限（屏幕录制、辅助功能、麦克风）失效。
- **同证书 + 同 Bundle ID 保持权限**：只要保持 Bundle ID 为 `com.tianruian.openshot.preview` 且使用同一稳定证书签名，覆盖安装后系统权限自动保留。
- **禁用上游更新**：脚本会自动移除 `Info.plist` 中的 `SUFeedURL` 并将 `SUEnableAutomaticChecks` 设为 `false`。
- **输出位置**：`../build/preview-staged/Pinny.app`（脚本每次直接覆盖该 staged 副本，不留多余可启动副本以免干扰 Launch Services）。

### 安装后检查

安装完成后，请确认：
1. **设置 → 权限**：屏幕录制、保存文件夹访问权限、辅助功能（以及录屏所需的麦克风）均为「授予」；
2. **设置 → 截图**：自动检测窗口、识别窗口内部元素两个开关均为开启状态。
