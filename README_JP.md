# TypeNo

![TypeNo hero image](assets/hero.webp)

> 無料・オープンソース・プライバシー優先の macOS 音声入力ツール。
> Control を押して、話して、完了。

ミニマルな macOS 音声入力アプリ。Control を押して、話して、完了。

TypeNo はあなたの声をキャプチャし、ローカルで文字起こしし、使用中のアプリに自動ペーストします — すべて1秒以内。

公式サイト: [https://typeno.com](https://typeno.com)

ローカル音声認識を支える [marswave ai の coli プロジェクト](https://github.com/nicepkg/coli) に感謝します。

## 使い方

1. **Control を短く押す** と録音開始
2. **もう一度 Control を短く押す** と停止
3. テキストが自動的に文字起こしされ、アクティブなアプリにペーストされます（クリップボードにもコピー）

それだけです。ウィンドウなし、設定なし、アカウント不要。

## インストール

### 方法 1：アプリをダウンロード

ほとんどのユーザーにとって、いちばん簡単なのは最新リリースをダウンロードすることです：

- [TypeNo for macOS をダウンロード](https://github.com/marswaveai/TypeNo/releases/latest)
- 最新の `TypeNo.app.zip` をダウンロード
- 解凍
- `TypeNo.app` を `/Applications` に移動
- TypeNo を起動

### macOS がアプリを破損と表示する場合

現在のリリースはまだ Apple の notarization（公証）を通していないため、ダウンロード後に macOS がアプリをブロックすることがあります。

次の手順を順番に試してください：

1. Finder で `TypeNo.app` を右クリックして **開く** を選ぶ
2. それでも macOS がブロックする場合は、Terminal で quarantine 属性を削除する：

```bash
xattr -dr com.apple.quarantine "/Applications/TypeNo.app"
```

3. もう一度 `TypeNo.app` を開く
4. **システム設定 → プライバシーとセキュリティ → このまま開く** が表示される場合はその方法も使えますが、すべての環境で表示されるわけではありません

TypeNo は今後のリリースで正式な Apple の署名と notarization に対応する予定です。

### 音声認識エンジンをインストール

TypeNo はローカル音声認識に [coli](https://github.com/nicepkg/coli) を使用します：

```bash
npm i -g @anthropic-ai/coli
```

### 初回起動

TypeNo には一度だけ次の2つの権限が必要です：
- **マイク** — 音声を録音するため
- **アクセシビリティ** — テキストをアプリに貼り付けるため

初回起動時にアプリが権限付与を案内します。

### 方法 2：ソースからビルド

自分でビルドしたい場合：

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
| 録音の開始/停止 | メニューバー → Record（`⌃R`） |
| ファイルの文字起こし | `.m4a`/`.mp3`/`.wav`/`.aac` をメニューバーアイコンにドラッグ |
| 終了 | メニューバー → Quit（`⌘Q`） |

## 設計思想

TypeNo がやることはひとつだけ：音声 → テキスト → ペースト。余計な UI なし、設定なし、構成不要。最速のタイピングは、タイピングしないこと。

## ライセンス

GNU General Public License v3.0
