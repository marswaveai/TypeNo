# feature/dynamic-dictionary 分支修改说明

基于 upstream [marswaveai/TypeNo](https://github.com/marswaveai/TypeNo) main 分支。

## 改动概要

1. 将录音 overlay 从静态小圆点改为 Typeless 风格的交互式波形界面
2. 优化首次启动模型下载体验，增加进度显示和模型完整性校验
3. 修复上游代码的超时逻辑缺陷
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

### 3. 模型下载优化（修复上游缺陷）

原始代码的问题：
- 固定 120 秒超时，首次下载模型（~155MB）经常超时失败
- 没有下载进度显示，用户不知道在干什么
- 没有模型完整性校验，解压中断后无法恢复

修复后：
- **智能超时**：改为 120 秒无活动超时（有下载进度就一直等，无输出才超时）
- **录音前检测模型**：按 Control 时先检查模型是否存在，不存在则先下载
- **圆形进度环**：App Store 风格，显示已下载/总大小（如 `42.5 / 155.5 MB`），固定宽度不跳动
- **进度更新限流**：每秒更新一次，避免 UI 刷新过于频繁
- **模型损坏自动恢复**：如果 coli 加载模型失败（protobuf 错误），自动删除损坏目录并重新下载
- **下载中可取消**：按 ✕ 或 Control 取消下载，下次会重新开始
- **统一进度路由**：所有进度回调通过 `handleProgressMessage()` 统一处理，自动区分下载进度和识别进度，确保显示正确的 UI 样式

### 4. Overlay 定位逻辑重构

原始代码的问题：
- `onOverlayRequest` 分散在 `AppState` 的 12+ 处手动调用
- 不同状态切换时 overlay 位置和大小不一致

修复后：
- 删除所有 `onOverlayRequest` 手动调用和属性
- `OverlayPanelController` 通过 Combine 订阅 `phase` 变化，统一驱动 show/hide/layout
- 每次状态切换自动重算大小和居中位置

## 已知问题与修复记录

### AudioEngine 停止时 EXC_BAD_ACCESS（已修复）

引入 `AVAudioEngine` 后出现的新问题（原始 `AVAudioRecorder` 不存在此问题）。

- **原因**：`stop()` 在主线程释放音频资源，但 `installTap` 的回调可能还在音频 IO 线程上运行，访问了已释放的 `file` 和 `converter`
- **修复**：先调用 `engine.stop()` 停止音频 IO 线程，再调用 `removeTap`，并加入短暂延迟确保回调完成后再释放资源

### @MainActor 与音频线程冲突（已修复）

- **原因**：`AudioEngine` 最初标记为 `@MainActor`，但 `installTap` 回调在音频实时线程执行，Swift 6 严格并发检查触发 `dispatch_assert_queue_fail` crash
- **修复**：将 `AudioEngine` 改为 `@unchecked Sendable`，频谱数据通过 `DispatchQueue.main.async` 发布到主线程

### coli 模型损坏导致 SIGABRT（已修复）

- **原因**：解压中断后模型文件不完整，coli 加载时 protobuf 解析失败，进程以 `uncaughtSignal` 终止，原始代码将其误报为"Transcription timed out"
- **修复**：在 `uncaughtSignal` 处理中检查 stderr 内容，识别到 protobuf 错误后自动删除损坏模型并触发重新下载

## 文件变更

- `Sources/Typeno/main.swift` — 唯一修改文件
- `docs/` — 设计文档和对话记录

## 未修改

- ASR 引擎（coli / sherpa-onnx / SenseVoice）不变
- 录音输出格式（m4a）不变
- 热键逻辑不变
