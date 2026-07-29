<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/cairn-mark-dark.svg">
  <img src="docs/assets/cairn-mark.svg" width="72" alt="">
</picture>

# Cairn

**すべてのタスクを、たどれる跡に。**

コーディングエージェントは、あなたが別の場所を見ている間に仕事を終えます。<br>
Cairn は終わった場所に小さなノートを残します——開けば、来た道へ戻れます。

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)

[![CI](https://github.com/quentinzhang/cairn/actions/workflows/ci.yml/badge.svg)](https://github.com/quentinzhang/cairn/actions/workflows/ci.yml)
[![Website](https://img.shields.io/badge/website-GitHub%20Pages-1A9E8A.svg)](https://quentinzhang.github.io/cairn/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-14%2B-lightgrey)
![Architecture](https://img.shields.io/badge/architecture-Apple%20Silicon-lightgrey)

### [⬇︎ macOS版をダウンロード](https://github.com/quentinzhang/cairn/releases/latest)

</div>

---

## 一般ユーザー向け

### できること

あなたのコーディングエージェント——たとえば **Codex** や **Claude Code**——が
ターンを終えると、デスクトップの小さな石積み（3つの川石）のそばにノートがそっと
現れます。

- **さえぎらない。** Dockアイコンなし、システム通知なし、キーボードを奪う
  ウィンドウもなし。Cairnは終わったことを伝えるだけで、応答を求めません。
- **つみかさなる。** 1セッション1ノート、エージェントごとの色。同じエージェントが
  同じプロジェクトで残したノートはひとつの積み重ねにまとまります。直近50セッション
  を記憶します。
- **跡をたどる。** ノートを開けば、そのターンが走っていた場所へ戻ります——正確な
  Terminal / iTerm2のタブ、ホストアプリのウィンドウ、あるいはCodexの会話そのもの。
- **あなただけのもの。** アカウントなし、サーバーなし、テレメトリなし。すべては
  このMacの中にとどまります。

### インストール

1. [Releases](https://github.com/quentinzhang/cairn/releases/latest) から公証済みの
   `.dmg` をダウンロードし、**Cairn** をアプリケーションフォルダへドラッグします。
2. 起動します。初回起動時に、CairnがこのMacにインストール済みのコーディング
   エージェントを検出して一覧にします——現在対応しているのは **Codex**、
   **Claude Code**、**OpenClaw**、**OpenCode**、**Hermes** です。
3. 使っているものそれぞれで**接続**をクリックし、最後に**Cairn を使いはじめる**を
   押します。

セットアップはこれだけです——**ターミナルも、スクリプトの実行も、設定ファイルの
編集も不要です。** 接続はそのエージェント向けのCairn連携を1つ導入し、無関係な設定を
保ちます。**切断**はCairnの連携だけを取り除きます。*確認が必要*と表示された行は、
同じクリックが修復になります。ウィンドウはCairnのメニューの**アプリ**からいつでも
開き直せます。

Apple Silicon搭載MacとmacOS 14以降が必要です。

いくつかのエージェントには、接続後にもう一歩だけ必要なものがあります。Cairnは
その行に直接それを書きます:

| エージェント | 接続したあと |
| --- | --- |
| **Codex** | Codex内で `/hooks` を一度実行し、Cairnのハンドラーを信頼してください——信頼されていないhookをCodexは実行しません。 |
| **Claude Code** | 追加の操作は不要です。（中断されたターンやAPI失敗では `Stop` が発火しないため、ノートは生成されません。） |
| **OpenClaw** | 最終メッセージを読んでよいかを一度だけ確認し、その後は管理対象Gatewayを自動で再起動します。 |
| **OpenCode** | すでに起動していた場合はOpenCodeを再起動してください。 |
| **Hermes** | すでに起動していた場合はHermesを再起動してください。 |

### 日々の使いかた

- **石積み**はデスクトップに置かれます。クリックでキューを開閉し、ドラッグで
  静かな隅へ。置いた場所は覚えています。
- **⌃⌥⌘C** で、どのアプリからでもノートを表示・非表示にできます——これは既定の
  ショートカットで、設定で自由に変更できます。
- **ノートを開く**と来た道をたどって戻ります。
- **ノートはひとりでに整う**——エージェントごとに色分けされ、エージェントと
  プロジェクトごとにひとつに積み重なります。

### 利用上の境界

- Cairnが受け取るのは最終結果のみで、ストリーミングの進捗やツールログは受け取りません。
- ローカルに保持されるのは直近50セッションだけです。それより古い履歴はなく、
  マシン間の同期もありません。
- Apple Silicon搭載MacのmacOS 14以降のみ対応します。

## ソースから開発する

以下のコマンドはすべてリポジトリのルートから実行します。インストール済みCairn内の
スクリプトには依存しません。

各コマンド、ランタイムhook、インストーラー、共有モジュール、リリースツールについては、
[Scriptsリファレンス](Scripts/README.md)を参照してください。

### ビルドして実行する

```bash
git clone https://github.com/quentinzhang/cairn.git && cd cairn
swift build && swift test                     # Swift実行ターゲットをコンパイルしてテスト
/usr/bin/python3 Tests/protocol_roundtrip.py  # すべてのブリッジをプロトコルに照合
./Scripts/build_app.sh                        # dist/Cairn.appを組み立てて署名
open dist/Cairn.app                           # 完全なローカルAppを起動
```

ビルドにはXcode 16以降が必要です。取得すべき依存関係はありません——システム
フレームワークとPython 3 / Node.js標準ライブラリのみです。

`swift build` が生成するのは `.build/` 内のSwift実行ファイルとSwiftPMリソースであり、
macOS Appの組み立ては行いません。`Scripts/build_app.sh` はreleaseビルドを実行し、
OpenCodeを含むすべてのブリッジとランタイムプラグインを `dist/Cairn.app` にコピーし、
Appリソースとentitlementsを追加して完成したbundleに署名します。

### ノートが届かないときの診断

ブリッジは意図的に静かに失敗します——完了hookは、それが動くエージェントを決して
壊してはならないからです。ソースツリーには、その沈黙を説明するツールがあります:

```bash
python3 Scripts/cairn_doctor.py
```

実際にインストールされている各ランタイムについて、原因と直し方を指名します:
移動した場所を指すhook、リンク済みだが無効なプラグイン、inboxに詰まった不正な
ペイロード、ノートを奪う2つ目のアプリコピー。`--probe` を付ければテストノートを
エンドツーエンドで追跡できます。出力にノート本文やプロンプトは含まれず、ホーム
ディレクトリは `~` に短縮されます。issueへ貼る前に、診断用に残るAppとcheckoutの
パスを確認してください。

### プライバシーと保存

各ブリッジが完了したターンから残すのはちょうど2つ——**最後のアシスタントメッセージ
と直近のユーザープロンプト**——で、残りはすべて破棄します。推論トレースなし、
ツール呼び出しなし、ファイル内容なし。

ノートはホームディレクトリ内に平文で保存されます——シェル履歴と同じように
扱ってください:

```
~/Library/Application Support/Cairn/inbox/            ターンごとに1ファイル、読み取り時に削除
~/Library/Application Support/Cairn/completions.json  直近50セッション
```

キュー自体にはmacOSのプライバシー権限が**一切**不要です。アクセシビリティと
オートメーションは、跡たどりを正確にする任意の強化で、**アクセス**からアプリごとに
許可します。なければ、クリックはアプリのアクティブ化、次いでFinderへと静かに
格下げされるだけです。ネットワークリクエストは1日1回のGitHub Releases確認のみ。
完全な削除方法を含む詳細は[SECURITY.md](SECURITY.md)を参照してください。

### inboxプロトコルを拡張する

Cairnはエージェントと統合しません——**ディレクトリを読むだけ**です。CIパイプライン、
長いビルド、別のエージェントランタイムは、
[`docs/inbox-protocol.md`](docs/inbox-protocol.md)に対してプロデューサーを書けます。
ソースツリーから使う最短版は1行です:

```bash
echo "Build completed successfully." | python3 Scripts/cairn_save.py \
  --source ci --prompt "nightly build"
```

### 接続スクリプトと意図的な保存

接続ウィンドウが行うことは、checkoutから直接実行できます:

```bash
python3 Scripts/cairn_connect.py status              # 何を検出し、何が繋がっているか
python3 Scripts/cairn_connect.py connect claude      # codex · claude · openclaw · opencode · hermes · skills
python3 Scripts/cairn_connect.py disconnect claude
```

`skills` はボタンのない唯一の対象です。接続すべきエージェントではなくCairnの機能
だからです——Claude CodeとCodexに `cairn-save` スキルをインストールします。どちらか
のエージェントに「Cairnに保存して」と頼むか、`/cairn-save` を実行すると、意図的な
結論ノートを公開し、保存した場所へ跡をたどって戻れます——ターン終了時の自動
キャプチャとは別物です。

個別のインストーラー（`install_*.py`）は今も存在し、今も動きます。
`cairn_connect.py` はそれらを動かしている層です。

### 初回起動、デザイン、リリース

初回起動の流れは一度しか起きないため、最もテストしづらい部分です。
`python3 Scripts/cairn_reset.py` はそれを巻き戻します——全エージェントを切断し、
キュー・設定・プライバシー許可を消し、アプリ自体は残すので、次の起動がまた
初回起動になります。既定では計画を表示するだけで何も変更せず、`--yes` で実行します。
`--keep-permissions` で許可を残せます。

プロトコルテストとSwiftテストは[`docs/inbox-protocol.md`](docs/inbox-protocol.md)の
両端を固定しています。片方を変えれば、もう片方が文句を言うはずです。デザイン
システムは装飾ではなく構造です——色、半径、時間のすべてが
[`Sources/Cairn/DesignSystem.swift`](Sources/Cairn/DesignSystem.swift)で一度だけ
定義され、[`docs/design-system.md`](docs/design-system.md)に文書化されています。
意図的なブランド変更の後は `./Scripts/generate_app_icon.sh` でFinderアイコンを
再生成してください。

リリースはすべてのテストを実行し、ローカルで署名・公証し、タグを打ち、DMGを
アップロードします:

```bash
CAIRN_NOTARY_PROFILE="cairn-notary" ./Scripts/release.sh --version 0.7.0
```

セットアップと復旧については[リリースガイド](docs/releasing.md)を参照してください。

## コントリビューション

バグ報告、他ランタイムのプロデューサー、跡たどりの修正、すべて歓迎します。
[CONTRIBUTING.md](CONTRIBUTING.md)から始め、何かを提出する前にdoctorを実行して
ください。

## ライセンス

Apache-2.0 — [LICENSE](LICENSE)を参照してください。第三者コンポーネントには
それぞれのライセンスが適用されます。詳細は
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)を参照してください。

コードはオープンです。ただし**「Cairn」という名称、跡のワードマーク、ストーン
マーク**はコードとともにライセンスされません——[NOTICE](NOTICE)を参照してください。
