# 本地开发与调试指南 (Development)

本文说明如何在本地编译、测试并打包安装 **Pinny**。

## 环境要求

- macOS 13.0+（Apple Silicon `arm64`）
- Xcode 15.0+ 及 Command Line Tools（`xcode-select --install`）
- Python 3（若需重新生成图标资源，还需安装 `Pillow` 与 `librsvg`：`brew install librsvg`）

## 克隆仓库

```bash
git clone https://github.com/realruian/Pinny.git
cd Pinny
```

> **注意**：`pinny` 为默认主分支；远端 `mine` 指向私有仓库 `https://github.com/realruian/Pinny.git`。切勿将提交推送到上游原作者仓库。

## 构建并打包自用版 `Pinny.app`（推荐 Release 流程）

日常安装在 `/Applications/Pinny.app` 的版本应始终使用 **Release 优化构建**，并通过 `scripts/package-preview.py` 使用现有稳定证书（如 `'V2Do Dev'`）签名，以保留 macOS 屏幕录制与辅助功能（设备控制）权限。

```bash
# 1. 编译 Release 优化版
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

# 2. 打包为 ../build/preview-staged/Pinny.app（Bundle ID: com.tianruian.openshot.preview）
python3 scripts/package-preview.py --identity 'V2Do Dev' --configuration Release
```

安装前请先退出正在运行的 `Pinny`，将 `/Applications/Pinny.app` 备份为单份 `.bak`（清理更早的旧备份），再使用 `ditto` 覆盖 `/Applications/Pinny.app`。

## 通过 URL Scheme 触发调试

由于本机可能同时存在 Debug 测试构建（`com.trongduong.snapzy.debug`），通过命令触发 `/Applications/Pinny.app` 时请显式指定 Bundle ID：

```bash
open -b com.tianruian.openshot.preview "snapzy://capture"
```

若需开启 `F1` 截图各阶段耗时日志（输出至 `~/Library/Logs/Snapzy/capture-timing.log`）：

```bash
defaults write com.tianruian.openshot.preview debug.captureTiming -bool true
```

## 运行单元测试

单元测试位于 `SnapzyTests/` 目录，可通过 `xcodebuild test` 运行指定测试集或全量测试：

```bash
# 运行指定单元测试类（快速验证）
xcodebuild test \
  -project Snapzy.xcodeproj \
  -scheme Snapzy \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath ../build/in-place-pin \
  -clonedSourcePackagesDirPath ../build/packages \
  -disableAutomaticPackageResolution \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= \
  ONLY_ACTIVE_ARCH=YES \
  -only-testing:SnapzyTests/InlineAreaAnnotateSessionTests \
  -only-testing:SnapzyTests/QuickAccessPinInteractionTests \
  -only-testing:SnapzyTests/AppBundleIdentityTests
```

## 相关文档

- 详细编译与图标生成说明：[BUILD.md](BUILD.md)
- 统一截图与贴图流程：[UNIFIED-CAPTURE.md](UNIFIED-CAPTURE.md)
- 工具栏图标说明：[HUGEICONS.md](HUGEICONS.md)
