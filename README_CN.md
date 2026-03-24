# TypeNo

![TypeNo 宣传图](assets/hero.webp)

> 免费、开源、隐私优先的 macOS 语音输入工具。
> 按下 Control，说话，完成。

一个极简的 macOS 语音输入应用。按下 Control，说话，完成。

TypeNo 录下你的声音，本地转录，然后自动粘贴到你正在使用的应用中 —— 全程不到一秒。

官方网站：[https://typeno.com](https://typeno.com)

特别感谢 [marswave ai 的 coli 项目](https://github.com/nicepkg/coli) 提供本地语音识别能力。

## 使用方式

1. **短按 Control** 开始录音
2. **再短按 Control** 停止
3. 文字自动转录并粘贴到当前应用（同时复制到剪贴板）

就这么简单。没有窗口，没有设置，没有账号。

## 安装

### 方式一：直接下载应用

对大多数用户来说，最简单的方式是直接下载最新版本：

- [下载 TypeNo for macOS](https://github.com/marswaveai/TypeNo/releases/latest)
- 下载最新的 `TypeNo.app.zip`
- 解压缩
- 将 `TypeNo.app` 拖到 `/Applications`
- 打开 TypeNo

### 如果 macOS 提示应用已损坏

当前发布版本还没有经过 Apple notarization（苹果公证），所以 macOS 在下载后可能会拦截应用。

请按顺序尝试以下方法：

1. 在 Finder 中右键 `TypeNo.app`，选择 **打开**
2. 如果 macOS 仍然阻止打开，请在终端中移除隔离标记：

```bash
xattr -dr com.apple.quarantine "/Applications/TypeNo.app"
```

3. 再次打开 `TypeNo.app`
4. 如果你确实看到了 **系统设置 → 隐私与安全性 → 仍要打开**，也可以走这条路径，但不是所有系统都会出现这个按钮

TypeNo 会在后续版本中支持正式的 Apple 签名与公证。

### 安装语音识别引擎

TypeNo 使用 [coli](https://github.com/nicepkg/coli) 进行本地语音识别：

```bash
npm i -g @anthropic-ai/coli
```

### 首次启动

TypeNo 需要两个一次性授权：
- **麦克风** — 用来录制你的声音
- **辅助功能** — 用来将文字粘贴到应用中

首次启动时，应用会引导你完成授权。

### 方式二：从源码构建

如果你希望自行构建：

```bash
git clone https://github.com/marswaveai/TypeNo.git
cd TypeNo
scripts/generate_icon.sh
scripts/build_app.sh
```

应用位于 `dist/TypeNo.app`。移动到 `/Applications/` 以获得持久权限。

## 操作方式

| 操作 | 触发方式 |
|---|---|
| 开始/停止录音 | 短按 `Control`（< 300ms，不要按其他键） |
| 开始/停止录音 | 菜单栏 → Record（`⌃R`） |
| 转录文件 | 拖拽 `.m4a`/`.mp3`/`.wav`/`.aac` 到菜单栏图标 |
| 退出 | 菜单栏 → Quit（`⌘Q`） |

## 设计理念

TypeNo 只做一件事：语音 → 文字 → 粘贴。没有多余的 UI，没有偏好设置，没有配置项。最快的打字方式就是不打字。

## 许可证

GNU General Public License v3.0
