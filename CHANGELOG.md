# Changelog

## 1.2.6

- merged key upstream improvements from `TypeNo v1.2.6`
- adopted upstream left/right modifier hotkey system and recording timer
- added a separate `口语整理` mode and dedicated hotkey
- changed default hotkey mapping to:
  - left `Option` = default mode
  - left `Control` = `口语整理`
  - right `Control` = `Agent`
- added additional style modes:
  - `中英夹杂`
  - `日漫中二`
  - `网络热梗`
  - `电影台词风`
  - `哲学社会学黑话`
  - `阴阳吐槽`
- refined prompt behavior to preserve key terms, reduce over-formalization, and clarify style boundaries

## 1.1.0

- forked the project into a separate app identity: `TypeNo Agent`
- changed bundle id to `ai.marswave.typeno.agent`
- kept two modes only: `普通模式` and `LLM Agent 模式`
- added provider switching for `Qwen` and `Kimi`
- added per-provider API key storage in Keychain
- added LLM-based rewrite after local transcription
- constrained LLM output to a fixed three-section format:
  - `任务：`
  - `检查项：`
  - `输出要求：`
- tuned rewrite style to keep original language and reduce overly formal wording

## 1.0.x

- upstream `TypeNo` baseline
- local speech transcription via `coli`
- menu bar recording and paste workflow
