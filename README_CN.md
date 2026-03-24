# TypeNo

一个极简的 macOS 语音输入应用。按下 Control，说话，完成。

TypeNo 录下你的声音，本地转录，然后自动粘贴到你正在使用的应用中 —— 全程不到一秒。

## 使用方式

1. **短按 Control** 开始录音
2. **再短按 Control** 停止
3. 文字自动转录并粘贴到当前应用（同时复制到剪贴板）

就这么简单。没有窗口，没有设置，没有账号。

## 安装

### 前置要求

- macOS 14+
- [coli](https://github.com/nicepkg/coli) 用于本地语音识别：

```bash
npm i -g @anthropic-ai/coli
```

### 从源码构建

```bash
git clone https://github.com/marswave/TypeNo.git
cd TypeNo
scripts/generate_icon.sh
scripts/build_app.sh
```

应用位于 `dist/TypeNo.app`。移动到 `/Applications/` 以获得持久权限。

### 首次启动

TypeNo 需要两个权限（仅需授权一次）：
- **麦克风** — 录制你的声音
- **辅助功能** — 将文字粘贴到应用中

首次启动时，应用会引导你完成授权。

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
