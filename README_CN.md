# TypeNo Agent

[English](README.md) | [日本語](README_JP.md)

**基于 TypeNo 的隐私优先 macOS 语音输入与改写工具。**

![TypeNo Agent 宣传图](assets/hero.webp)

`TypeNo Agent` 是一个基于 `TypeNo` fork 的工作流工具。它会先本地语音转写，再按当前模式决定是否调用 LLM 重写，最后把结果自动粘贴回当前应用。

官方网站：[https://typeno.com](https://typeno.com)

特别感谢 [marswave ai 的 coli 项目](https://github.com/marswaveai/coli) 提供本地语音识别能力。

## 使用方式

1. 用对应快捷键开始录音
2. 再按一次同一快捷键停止
3. 应用先本地转写，再按模式决定是否重写，最后自动粘贴到当前应用

当前默认快捷键：

- 左 `Option` = 当前默认模式
- 左 `Control` = `口语整理`
- 右 `Control` = `Agent`

## 安装

### 方式一：下载 app

- 下载当前的 `TypeNo Agent.app`
- 解压后将 `TypeNo Agent.app` 拖到 `/Applications` 或 `~/Applications`
- 打开 `TypeNo Agent`

#### 如果 macOS 提示应用已损坏

当前版本尚未经过 Apple 公证，macOS 可能会拦截应用。

请按顺序尝试：

1. 在 Finder 中右键 `TypeNo Agent.app`，选择 **打开**
2. 如果看到 **系统设置 → 隐私与安全性 → 仍要打开**，走这条路径
3. 如果仍被阻止，在终端中执行：

```bash
xattr -dr com.apple.quarantine "/Applications/TypeNo Agent.app"
```

4. 再次打开 `TypeNo Agent.app`

### 安装语音识别引擎

`TypeNo Agent` 使用 [coli](https://github.com/marswaveai/coli) 进行本地语音识别：

```bash
npm install -g @marswave/coli
```

如果未安装 Coli，应用会在界面内给出引导提示。

### 首次启动

`TypeNo Agent` 需要两个一次性授权：
- **麦克风** — 录制你的声音
- **辅助功能** — 将文字粘贴到应用中

首次启动时，应用会自动引导你完成授权。

### 方式二：从源码构建

```bash
git clone https://github.com/marswaveai/TypeNo.git
cd TypeNo
scripts/generate_icon.sh
scripts/build_app.sh
```

构建产物位于 `dist/TypeNo Agent.app`。建议移动到 `/Applications/` 或 `~/Applications/` 以获得持久权限。

## 操作方式

| 操作 | 触发方式 |
|---|---|
| 以当前默认模式开始/停止录音 | 短按左 `Option` |
| 以 `口语整理` 模式开始/停止录音 | 短按左 `Control` |
| 以 `Agent` 模式开始/停止录音 | 短按右 `Control` |
| 开始/停止录音 | 菜单栏 → Record |
| 转录文件 | 拖拽 `.m4a`/`.mp3`/`.wav`/`.aac` 到菜单栏图标 |
| 选择默认模式 | 菜单栏 → 默认输出模式 |
| 选择模型提供方 | 菜单栏 → 模型提供方 |
| 检查上游核心更新 | 菜单栏 → 检查上游更新... |
| 退出 | 菜单栏 → Quit（`⌘Q`） |

## 当前模式

- `普通`
- `Agent`
- `口语整理`
- `中英夹杂`
- `日漫中二`
- `网络热梗`
- `电影台词风`
- `哲学社会学黑话`
- `阴阳吐槽`

其中 `Agent` 模式用于生成可直接贴给 autonomous agent 的结构化任务单。

## 项目说明

- 这个仓库维护的是 `TypeNo Agent` fork，不是原版 upstream `TypeNo`
- 历史版本演进请看 `CHANGELOG.md`
- 当前产品基线和维护边界请看 `UPDATE_MANUAL.md`

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=marswaveai/TypeNo&type=Date)](https://star-history.com/#marswaveai/TypeNo&Date)

## 许可证

GNU General Public License v3.0
