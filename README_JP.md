# TypeNo Agent

[English](README.md) | [中文](README_CN.md)

**TypeNo をベースにした、プライバシー重視の macOS 音声入力・書き換えツール。**

![TypeNo Agent hero image](assets/hero.webp)

`TypeNo Agent` は `TypeNo` をベースにした fork です。音声をローカルで文字起こしし、必要に応じて LLM で書き換えたうえで、現在使っているアプリへ自動ペーストします。

公式サイト: [https://typeno.com](https://typeno.com)

ローカル音声認識を支える [marswave ai の coli プロジェクト](https://github.com/marswaveai/coli) に感謝します。

## 使い方

1. 対応するホットキーで録音開始
2. 同じホットキーをもう一度押して停止
3. ローカル文字起こし後、モードに応じて書き換えを行い、アクティブなアプリに自動ペースト

現在のデフォルトホットキー:

- 左 `Option` = 現在のデフォルトモード
- 左 `Control` = `口語整理`
- 右 `Control` = `Agent`

## インストール

### 方法 1：アプリをダウンロード

- 現在の `TypeNo Agent.app` をダウンロード
- 解凍して `TypeNo Agent.app` を `/Applications` または `~/Applications` に移動
- `TypeNo Agent` を起動

#### macOS がアプリを破損と表示する場合

現在のリリースはまだ Apple の公証を通していないため、macOS がブロックすることがあります。

1. Finder で `TypeNo Agent.app` を右クリックして **開く** を選ぶ
2. **システム設定 → プライバシーとセキュリティ → このまま開く** が表示される場合はそちらを使用
3. それでもブロックされる場合は Terminal で：

```bash
xattr -dr com.apple.quarantine "/Applications/TypeNo Agent.app"
```

### 音声認識エンジンをインストール

`TypeNo Agent` はローカル音声認識に [coli](https://github.com/marswaveai/coli) を使用します：

```bash
npm install -g @marswave/coli
```

未インストールの場合、アプリ内でガイダンスが表示されます。

### 初回起動

`TypeNo Agent` には一度だけ次の2つの権限が必要です：
- **マイク** — 音声を録音するため
- **アクセシビリティ** — テキストをアプリに貼り付けるため

初回起動時にアプリが権限付与を案内します。

### 方法 2：ソースからビルド

```bash
git clone https://github.com/marswaveai/TypeNo.git
cd TypeNo
scripts/generate_icon.sh
scripts/build_app.sh
```

アプリは `dist/TypeNo Agent.app` に生成されます。権限を維持するため `/Applications/` または `~/Applications/` に移動してください。

## 操作方法

| 操作 | トリガー |
|---|---|
| 現在のデフォルトモードで録音開始/停止 | 左 `Option` を短く押す |
| `口語整理` モードで録音開始/停止 | 左 `Control` を短く押す |
| `Agent` モードで録音開始/停止 | 右 `Control` を短く押す |
| 録音の開始/停止 | メニューバー → Record |
| ファイルの文字起こし | `.m4a`/`.mp3`/`.wav`/`.aac` をメニューバーアイコンにドラッグ |
| デフォルトモードの選択 | メニューバー → Default Mode |
| LLM provider の選択 | メニューバー → Provider |
| 上流のコア更新を確認 | メニューバー → Check Upstream Updates... |
| 終了 | メニューバー → Quit（`⌘Q`） |

## 現在のモード

- `普通`
- `Agent`
- `口語整理`
- `中英夹杂`
- `日漫中二`
- `网络热梗`
- `电影台词风`
- `哲学社会学黑话`
- `阴阳吐槽`

`Agent` モードは、autonomous agent にそのまま貼り付けられる構造化タスク文を生成するためのモードです。

## プロジェクトメモ

- このリポジトリは upstream `TypeNo` 本体ではなく、`TypeNo Agent` fork を管理しています
- バージョン履歴は `CHANGELOG.md` を参照してください
- 現在の製品定義と保守方針は `UPDATE_MANUAL.md` を参照してください

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=marswaveai/TypeNo&type=Date)](https://star-history.com/#marswaveai/TypeNo&Date)

## ライセンス

GNU General Public License v3.0
