# feature/dynamic-dictionary 分支修改说明

基于 upstream [marswaveai/TypeNo](https://github.com/marswaveai/TypeNo) main 分支。

## 改动概要

1. 将录音 overlay 从静态小圆点改为交互式波形界面
2. 优化首次启动模型下载体验，增加进度显示和模型完整性校验
3. 修复上游代码的超时逻辑和模型损坏处理缺陷
4. 重构 overlay 定位逻辑，消除重复代码

## 具体修改

### 1. 录音引擎替换：AVAudioRecorder → AVAudioEngine

- 原始代码使用 `AVAudioRecorder`，无法获取实时音频数据
- 替换为 `AVAudioEngine` + `installTap`，在录音的同时获取 PCM buffer
- 使用 Accelerate 框架（vDSP FFT）从音频 buffer 计算实时频谱数据
- 输出格式保持 m4a（与原始一致），ASR 行为不变
- 频谱聚焦语音频段（80Hz-4kHz），中心展开布局（低频居中，高频向两边）

### 2. Overlay UI 重新设计

录音状态下的 overlay 从原始的：
```
● Listening...
```
改为：
```
[✕]  |||||||||||||||  [✓]
取消   实时频谱波形     确认
```

- **✕ 按钮**：取消录音（圆形立体按钮，带阴影）
- **频谱波形**：14 根柱状图，实时 FFT 频谱
- **✓ 按钮**：停止录音并识别（圆形立体按钮，带阴影）
- 所有状态（录音/识别中/下载/错误）统一高度
- 识别完成后直接粘贴，不再闪显全文

### 3. 修复上游缺陷：模型下载与超时

原始代码的问题：
- 固定 120 秒超时，首次下载模型（~155MB）经常超时失败
- 没有下载进度显示，用户不知道在干什么
- 没有模型完整性校验，解压中断后 coli 加载损坏模型会 crash（protobuf 错误），且不会自动恢复

修复后：
- **智能超时**：改为 120 秒无活动超时（有下载进度就一直等，无输出才超时）
- **录音前检测模型**：按 Control 时先检查模型是否存在，不存在则先下载
- **圆形进度环**：显示已下载/总大小（如 `42.5 / 155.5 MB`），固定宽度不跳动，每秒更新一次
- **模型损坏自动恢复**：coli 加载模型失败时，自动删除损坏目录并重新下载
- **下载中可取消**：按 ✕ 或 Control 取消下载，下次会重新开始

### 4. Overlay 定位逻辑重构

原始代码的问题：
- `onOverlayRequest` 分散在 `AppState` 的 12+ 处手动调用
- 不同状态切换时 overlay 位置和大小不一致

修复后：
- 删除所有 `onOverlayRequest` 手动调用和属性
- `OverlayPanelController` 通过 Combine 订阅 `phase` 变化，统一驱动 show/hide/layout
- 每次状态切换自动重算大小和居中位置
- 所有进度回调通过 `handleProgressMessage()` 统一处理

## 文件变更

- `Sources/Typeno/main.swift` — 唯一修改文件

## 未修改

- ASR 引擎（coli / sherpa-onnx / SenseVoice）不变
- 录音输出格式（m4a）不变
- 热键逻辑不变
