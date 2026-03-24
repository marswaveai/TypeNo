# TypeNo

ミニマルな macOS 音声入力アプリ。Control を押して、話して、完了。

TypeNo はあなたの声をキャプチャし、ローカルで文字起こしし、使用中のアプリに自動ペーストします — すべて1秒以内。

## 使い方

1. **Control を短く押す** と録音開始
2. **もう一度 Control を短く押す** と停止
3. テキストが自動的に文字起こしされ、アクティブなアプリにペーストされます（クリップボードにもコピー）

それだけです。ウィンドウなし、設定なし、アカウント不要。

## インストール

### 前提条件

- macOS 14+
- [coli](https://github.com/nicepkg/coli) ローカル音声認識用：

```bash
npm i -g @anthropic-ai/coli
```

### ソースからビルド

```bash
git clone https://github.com/marswave/TypeNo.git
cd TypeNo
scripts/generate_icon.sh
scripts/build_app.sh
```

アプリは `dist/TypeNo.app` に生成されます。永続的な権限のために `/Applications/` に移動してください。

### 初回起動

TypeNo には2つの権限が必要です（一度だけ）：
- **マイク** — 音声のキャプチャ
- **アクセシビリティ** — アプリへのテキストペースト

初回起動時にアプリが権限付与をガイドします。

## 操作方法

| 操作 | トリガー |
|---|---|
| 録音の開始/停止 | `Control` を短く押す（300ms以内、他のキーなし） |
| 録音の開始/停止 | メニューバー → Record（`⌃R`） |
| ファイルの文字起こし | `.m4a`/`.mp3`/`.wav`/`.aac` をメニューバーアイコンにドラッグ |
| 終了 | メニューバー → Quit（`⌘Q`） |

## 設計思想

TypeNo がやることはひとつだけ：音声 → テキスト → ペースト。余計な UI なし、設定なし、構成不要。最速のタイピングは、タイピングしないこと。

## ライセンス

GNU General Public License v3.0
