# feature/dynamic-dictionary 分支修改说明

基于 upstream [marswaveai/TypeNo](https://github.com/marswaveai/TypeNo) main 分支。

## 改动概要

将录音时的 overlay 从原始的静态小圆点改为 Typeless 风格的交互式波形界面。

## 具体修改

### 1. 录音引擎替换：AVAudioRecorder → AVAudioEngine

- 原始代码使用 `AVAudioRecorder`，无法获取实时音频数据
- 替换为 `AVAudioEngine` + `installTap`，在录音的同时获取 PCM buffer
- 使用 Accelerate 框架（vDSP FFT）从音频 buffer 计算实时频谱数据
- 输出格式保持 m4a（与原始一致），ASR 行为不变
- 频谱聚焦语音频段（80Hz-4kHz），生成 20 个柱状数据

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
- **频谱波形**：14 根柱状图，中心展开布局（低频居中，高频向两边）
- **✓ 按钮**：停止录音并识别（圆形立体按钮，带阴影）
- 所有状态（录音/识别中/完成/错误）统一高度

### 3. 修复上游 Bug：ASR 超时时间不足

- 原始代码 `ColiASRService` 中 install 和 transcribe 的超时均为 **120 秒**
- 首次运行需要下载 SenseVoice 模型（~155MB），120 秒不够，导致识别超时失败
- 修改为 **600 秒**，确保首次模型下载能完成

### 4. Overlay 定位逻辑重构

- 删除了原始代码中分散在 `AppState` 各处的 `onOverlayRequest` 手动调用（12+ 处）
- 改为 `OverlayPanelController` 通过 Combine 订阅 `phase` 变化，统一控制 show/hide/layout
- 确保所有状态切换时 overlay 居中显示

## 已知问题与修复记录

### AudioEngine 停止时 EXC_BAD_ACCESS（已修复）

引入 `AVAudioEngine` 后出现的新问题（原始 `AVAudioRecorder` 不存在此问题）。

- **原因**：`stop()` 在主线程释放音频资源，但 `installTap` 的回调可能还在音频 IO 线程上运行，访问了已释放的 `file` 和 `converter`，导致 crash
- **修复**：先调用 `engine.stop()` 停止音频 IO 线程，再调用 `removeTap`，并加入短暂延迟确保回调完成后再释放资源

### @MainActor 与音频线程冲突（已修复）

- **原因**：`AudioEngine` 最初标记为 `@MainActor`，但 `installTap` 回调在音频实时线程执行，Swift 6 严格并发检查触发 `dispatch_assert_queue_fail` crash
- **修复**：将 `AudioEngine` 改为 `@unchecked Sendable`，频谱数据通过 `DispatchQueue.main.async` 发布到主线程

## 文件变更

- `Sources/Typeno/main.swift` — 唯一修改文件（+284 / -128）
- `docs/` — 设计文档和对话记录

## 未修改

- ASR 引擎（coli / sherpa-onnx / SenseVoice）不变
- 录音输出格式（m4a）不变
- 识别流程不变
- 热键逻辑不变
