# 本地开发与调试指南 (Development)

本文说明如何在本地编译、测试并打包安装 **Pinny**。

## 环境要求

- macOS 13.0+（原生液态玻璃需 macOS 26+，Apple Silicon `arm64`）
- Xcode 15.0+ 及 Command Line Tools（`xcode-select --install`）
- Python 3（若需重新生成图标资源，还需安装 `Pillow` 与 `librsvg`：`brew install librsvg`）

## 克隆仓库

```bash
git clone https://github.com/realruian/Pinny.git
cd Pinny
```

> **注意**：`pinny` 为默认主分支（`https://github.com/realruian/Pinny.git`）。

## 一键构建并安装 `Pinny.app`（Release 流程）

安装在 `/Applications/Pinny.app` 的版本使用 **Release 构建**，并通过 `scripts/install-pinny.sh` 调用 `scripts/package-preview.py` 使用本地稳定证书（如 `'V2Do Dev'`）签名，以保留 macOS 屏幕录制、辅助功能与麦克风权限：

```bash
./scripts/install-pinny.sh --identity 'V2Do Dev'
```

## 通过 URL Scheme 触发调试

由于本机可能同时存在 Debug 测试构建（`com.trongduong.snapzy.debug`），通过命令触发 `/Applications/Pinny.app` 时请显式指定 Bundle ID（`snapzy://` 仅放行截图与可见设置页）：

```bash
open -b com.tianruian.openshot.preview "snapzy://capture"
```

若需开启 `F1` 截图各阶段耗时日志（输出至 `~/Library/Logs/Snapzy/capture-timing.log`）：

```bash
defaults write com.tianruian.openshot.preview debug.captureTiming -bool true
```

配置文件默认位于 `~/.config/pinny/config.toml`（首次启动若不存在会自动从 `~/.config/snapzy/config.toml` 复制迁移）。

## 运行单元测试

单元测试位于 `SnapzyTests/` 目录，可通过 `xcodebuild test` 运行指定测试集：

```bash
# 运行核心截图、标注、录屏与贴图单元测试（快速验证）
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
  -only-testing:SnapzyTests/AnnotateCoreTests \
  -only-testing:SnapzyTests/PinnyRecordingBarsTests \
  -only-testing:SnapzyTests/QuickAccessPinInteractionTests \
  -only-testing:SnapzyTests/SnapzyConfigurationPathsTests \
  -only-testing:SnapzyTests/SnapzyDeepLinkHandlerTests
```

## 相关文档

- 详细编译与图标生成说明：[BUILD.md](BUILD.md)
- 统一截图、长截图、录屏与贴图流程：[UNIFIED-CAPTURE.md](UNIFIED-CAPTURE.md)
- 工具栏图标说明：[HUGEICONS.md](HUGEICONS.md)
