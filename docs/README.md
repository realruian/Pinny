# Pinny 文档索引

本目录包含 Pinny 的交互说明、构建脚本说明与各模块设计文档。

## 常用文档

| 文档 | 内容 |
| --- | --- |
| [`../README.md`](../README.md) | 功能概览、快捷键、Release 编译打包与安装步骤 |
| [`UNIFIED-CAPTURE.md`](UNIFIED-CAPTURE.md) | `F1` 原位截图、长截图、原位标注与 `F2` 贴图交互规范 |
| [`HUGEICONS.md`](HUGEICONS.md) | 工具栏 Hugeicons Pro 图标映射与生成脚本说明 |
| [`DEVELOPMENT.md`](DEVELOPMENT.md) | 本地开发、测试运行与签名验证 |
| [`BUILD.md`](BUILD.md) | Release 编译、图标生成与 `package-preview.py` 打包流程 |
| [`STRUCTURE.md`](STRUCTURE.md) | 源码目录结构、运行时组件与持久化说明 |

## 模块文档

| 文档 | 覆盖范围 | 当前状态 |
| --- | --- | --- |
| [`CAPTURE.md`](CAPTURE.md) | 屏幕捕获、选区浮层、窗口与 `AXUIElement` 元素识别 | **启用**（收敛至 `F1` 浮层，辅助功能后台查询 + 滚轮切换父子层级） |
| [`ANNOTATE.md`](ANNOTATE.md) | 内联标注工具栏、形状/线条二级分组、画布渲染 | **启用**（macOS 26+ 原生液态玻璃面板，文字固定 `PingFang SC`） |
| [`SCROLLING_CAPTURE.md`](SCROLLING_CAPTURE.md) | 滚动长截图拼接管线、预览窗与常驻工具栏 | **启用**（从 `F1` 工具栏启动，逐帧拼接、回滚裁尾、固定元素去重、上下裁剪） |
| [`QUICK_ACCESS.md`](QUICK_ACCESS.md) | 贴图窗口（Pin Window）与旧版角落卡片 | **仅启用贴图窗口**（直角纯图、跨屏拖拽、滚轮缩放、双击复制并关闭） |
| [`PREFERENCES.md`](PREFERENCES.md) | 设置窗口与偏好存储 | **启用**（精简为通用、截图、标注、贴图、快捷键、权限、高级/关于 7 页） |
| [`SHORTCUTS.md`](SHORTCUTS.md) | 全局快捷键（`F1` / `F2`）、会话内快捷键与 `snapzy://` | **启用** |
| [`APP_LIFECYCLE.md`](APP_LIFECYCLE.md) | 启动引导、菜单栏与权限状态缓存 | **启用** |
| [`LIQUID_GLASS.md`](LIQUID_GLASS.md) | Liquid Glass 面板封装 | **启用** |
| [`LOCALIZATION.md`](LOCALIZATION.md) | 多语言文案目录 | **启用** |
| [`CONFIGURATION.md`](CONFIGURATION.md) | `~/.config/snapzy/config.toml` 导入导出 | **启用** |

## 源码保留但界面隐藏的模块

以下模块保留在工程中以维持编译与测试完整，不在菜单栏、设置页或全局快捷键中暴露：

- **录屏与视频编辑**：[`RECORDING.md`](RECORDING.md) · [`VIDEO_EDITOR.md`](VIDEO_EDITOR.md)（录屏计划后续接入 `F1` 工具栏）
- **旧版截图后动作矩阵**：[`POST_CAPTURE.md`](POST_CAPTURE.md)
- **历史面板与云上传**：[`HISTORY.md`](HISTORY.md) · [`CLOUD.md`](CLOUD.md)
- **Sparkle 自动更新与公开发布**：[`UPDATES.md`](UPDATES.md) · [`RELEASES.md`](RELEASES.md) · [`UPDATE_TESTING.md`](UPDATE_TESTING.md)

## 核心流程

```mermaid
flowchart TD
    A["启动 Pinny (/Applications/Pinny.app)"] --> B["注册全局快捷键 F1 / F2"]
    B --> C["F1：打开原位截图浮层"]
    B --> D["F2：从剪贴板生成纯图贴图"]

    C --> E["光标高亮元素 (滚轮切换父子层级) / 手动框选 / ⌘A 全屏 / Tab 窗口 / R 上次区域"]
    E --> F["调整选区 (边缘吸附) + 底部工具栏原位标注"]
    E --> L["点击长截图：逐帧拼接 + 回滚裁尾 + 固定元素去重 + 上下裁剪"]

    F --> G["复制 (↩ / ⌘C / 双击空白)：收起浮层 + 后台写入剪贴板 (含源坐标)"]
    F --> H["钉图：在原选区位置生成纯图贴图"]
    F --> I["保存 (⌘S)：输出至 ~/Downloads/Pinny"]

    L --> G
    L --> H
    L --> I

    G -. "附带坐标与尺寸" .-> D
    H --> J["纯图贴图：跨屏拖拽 / 滚轮缩放 / 双击复制原图并关闭"]
    D --> J
```
