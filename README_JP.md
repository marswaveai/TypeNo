# TypeNo

[English](README.md) | [中文](README_CN.md)

**無料・オープンソース・プライバシー優先の macOS 音声入力ツール。**

![TypeNo hero image](assets/hero.webp)

ミニマルな macOS 音声入力アプリ。TypeNo はあなたの声をキャプチャし、ローカルで文字起こしし、使用中のアプリに自動ペーストします — すべて1秒以内。

公式サイト: [https://typeno.com](https://typeno.com)

ローカル音声認識を支える [marswave ai の coli プロジェクト](https://github.com/marswaveai/coli) に感謝します。

## 使い方

1. **Control を短く押す** と録音開始
2. **もう一度 Control を短く押す** と停止
3. テキストが自動的に文字起こしされ、アクティブなアプリにペーストされます（クリップボードにもコピー）

それだけです。ウィンドウなし、設定なし、アカウント不要。

## インストール

### 方法 1：アプリをダウンロード

- [TypeNo for macOS をダウンロード](https://github.com/marswaveai/TypeNo/releases/latest)
- 最新の `TypeNo.app.zip` をダウンロード
- 解凍して `TypeNo.app` を `/Applications` に移動
- TypeNo を起動

TypeNo は Apple の署名と公証済みです。警告なしでそのまま開けます。

### 音声認識エンジンをインストール

TypeNo はローカル音声認識に [coli](https://github.com/marswaveai/coli) を使用します。

**前提条件：**
- [Node.js](https://nodejs.org)（LTS 推奨 — nodejs.org から直接インストールすると互換性が高い）
- [ffmpeg](https://ffmpeg.org) — 音声変換に必要：`brew install ffmpeg`

```bash
npm install -g @marswave/coli
```

未インストールの場合、アプリ内でガイダンスが表示されます。

> **Node 24+：** `sherpa-onnx-node` エラーが出る場合はソースからビルドしてください：
> ```bash
> npm install -g @marswave/coli --build-from-source
> ```

### 初回起動

TypeNo には一度だけ次の2つの権限が必要です：
- **マイク** — 音声を録音するため
- **アクセシビリティ** — テキストをアプリに貼り付けるため

初回起動時にアプリが権限付与を案内します。

### トラブルシューティング：Coli モデルのダウンロードが失敗する

音声モデルは GitHub からダウンロードされます。ネットワークが GitHub にアクセスできない場合、ダウンロードに失敗します。

**対処法：** プロキシツールで **TUN モード**（拡張モードとも呼ばれる）を有効にして、システムレベルのトラフィックが正しくルーティングされるようにしてください。その後、インストールを再試行してください：

```bash
npm install -g @marswave/coli
```

### トラブルシューティング：アクセシビリティ権限が有効にならない

**システム設定 → プライバシーとセキュリティ → アクセシビリティ** で TypeNo を有効にしても反応しない場合があります — macOS の既知のバグです。対処法：

1. リストで **TypeNo** を選択
2. **−** をクリックして削除
3. **+** をクリックして `/Applications` から TypeNo を再追加

![アクセシビリティ権限の修正](assets/accessibility-fix.gif)

### 方法 2：ソースからビルド

```bash
git clone https://github.com/marswaveai/TypeNo.git
cd TypeNo
scripts/generate_icon.sh
scripts/build_app.sh
```

アプリは `dist/TypeNo.app` に生成されます。権限を維持するため `/Applications/` に移動してください。

## 操作方法

| 操作 | トリガー |
|---|---|
| 録音の開始/停止 | `Control` を短く押す（300ms以内、他のキーなし） |
| 録音の開始/停止 | メニューバー → Record |
| マイクを選択 | メニューバー → Microphone → Automatic / デバイス名 |
| ファイルの文字起こし | `.m4a`/`.mp3`/`.wav`/`.aac` をメニューバーアイコンにドラッグ |
| 最近の文字起こしを表示 | メニューバー → Recent → クリックでコピー |
| 履歴をクリア | メニューバー → Recent → Clear Recent History |
| アップデート確認 | メニューバー → Check for Updates... |
| 終了 | メニューバー → Quit（`⌘Q`） |

## 設計思想

TypeNo がやることはひとつだけ：音声 → テキスト → ペースト。余計な UI なし、設定なし、構成不要。最速のタイピングは、タイピングしないこと。

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=marswaveai/TypeNo&type=Date)](https://star-history.com/#marswaveai/TypeNo&Date)

## ライセンス

GNU General Public License v3.0
