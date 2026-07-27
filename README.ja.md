# Cairn 跡

**コーディングエージェントは、あなたが別の場所を見ている間に仕事を終えます。Cairnは終わった場所に小さな石をひとつ残します。**

Codex、Hermes、Claude Code、OpenClawの完了したターンのための、静かな
ネイティブmacOSコンパニオン。ターンが終わると、Cairnはシステム通知や
注意を争うウィンドウの代わりに、フローティングノートとして結果を残します。
ノートをクリックすると、そのターンが走っていた正確なターミナルタブへ
連れて戻ります。

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)

[![CI](https://github.com/quentinzhang/cairn/actions/workflows/ci.yml/badge.svg)](https://github.com/quentinzhang/cairn/actions/workflows/ci.yml)
[![Website](https://img.shields.io/badge/website-GitHub%20Pages-1A9E8A.svg)](https://quentinzhang.github.io/cairn/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/macOS-14%2B-lightgrey)

- **Dockアイコンなし、通知なし、フォーカス奪取なし。** Cairnはメニューバーに
  住み、非アクティブのパネルを自分で描きます。キーボードを奪うことは
  ありません。
- **コントロールはひとつ。** 3つの川石を積んだ小さな石積み:クリックで
  キューを開閉し、ドラッグで静かな隅へ。置いた場所は覚えています。
- **1セッション1ノート。** 同じセッションの後のターンは、新しいノートを
  積まず既存のノートを更新します。最大50セッション、一度に見えるのは6件。
- **エージェント別の色。** Codexはティール、Hermesはヴァイオレット、
  Claude Codeはテラコッタ、OpenClawはブルー。
- **あなたのMacの言語を話します。** 英語・簡体字中国語・日本語に対応し、
  アプリ内で切り替えるか、システム設定に従うかを選べます。
- **跡をたどる。** ノートをクリックすると、そのターンが走っていた場所へ
  戻ります:正確なTerminal/iTerm2セッション、ホストアプリのウィンドウ、
  Codexデスクトップのターンなら `codex://threads/<session_id>` で
  正確な会話を再び開きます。
- **ローカルのみ。** アカウントなし、サーバーなし、テレメトリなし。唯一の
  ネットワークリクエストは、1日1回、または**アップデートを確認**を選んだ
  ときのGitHub Releasesの確認です。

Cairnはエージェントと統合しません——**ディレクトリを読むだけ**です。
JSONファイルを書けるものなら何でもノートを残せるので、新しいランタイムへの
対応にアプリの変更は不要です。[inboxプロトコル](docs/inbox-protocol.md)を
参照してください。

---

## インストール

[Releases](https://github.com/quentinzhang/cairn/releases/latest)から公証済みの
`.dmg`をダウンロードするか、ビルドします:

```bash
git clone https://github.com/quentinzhang/cairn.git
cd cairn
./Scripts/build_app.sh
open dist/Cairn.app
```

macOS 14以降が必要です。ビルドにはXcode 16以降。取得すべき依存関係は
ありません——システムフレームワークとPython 3 / Node.js標準ライブラリのみです。

次に、使っているエージェントを接続します。各インストーラーは既存の設定に
ハンドラーを1つだけマージし、他のすべてを保持します。`uninstall`で同じ
ハンドラーだけを正確に取り除けます。

```bash
python3 Scripts/install_codex_hook.py install       # Codex CLI・デスクトップアプリ
python3 Scripts/install_claude_hook.py install      # Claude Code
python3 Scripts/install_openclaw_plugin.py install  # OpenClaw
python3 Scripts/install_hermes_plugin.py            # Hermes
```

エージェントごとの注意点:

- **Codex** — Codex内で `/hooks` を実行し、新しいグローバルhookを信頼して
  ください。信頼されていないhookはCodexが実行しません。
- **Claude Code** — 中断されたターンやAPI失敗では `Stop` が発火しないため、
  ノートは生成されません。
- **OpenClaw** — インストーラーは会話アクセスの有効化と管理対象Gatewayの
  再起動の前に確認します。`--allow-conversation-access --restart-gateway` で
  事前に両方に同意できます。Desktopや非管理の環境では手動再起動が必要な
  場合があります。
- **Hermes** — 最終的なアシスタント出力を生成するDesktop、CLI、Gatewayの
  ターンをカバーします。

接続したどのエージェントでも、ターンを完了すればノートが現れます。
Cairnのメニューの**アップデートを確認**はいつでも使えます——Cairnが
あなたなしにアップデートをダウンロード・インストールすることはありません。

## ノートが届かないとき

ブリッジは意図的に静かに失敗します——完了hookは、それが動くエージェントを
決して壊してはならないからです。だから、その沈黙を説明することだけを仕事に
するツールがあります:

```bash
python3 Scripts/cairn_doctor.py        # --probe でテストノートをエンドツーエンドで追跡
```

実際にインストールされている各ランタイムについて、原因と直し方を指名します:
移動したチェックアウトを指すhook、リンク済みだが無効なプラグイン、inboxに
詰まった不正なペイロード、ノートを奪う2つ目のアプリコピー。出力はissueに
そのまま貼って安全です:ノート本文なし、プロンプトなし、チェックアウト外の
絶対パスなし。

## プライバシー

各ブリッジが完了したターンから抽出するのはちょうど2つ——**最後のアシスタント
メッセージと直近のユーザープロンプト**——で、残りはすべて破棄します。
推論トレースなし、ツール呼び出しなし、ファイル内容なし。

ノートはホームディレクトリ内の2つの平文ファイルにあり、モードは `0700`、
暗号化されていません——シェル履歴と同じように扱ってください:

```
~/Library/Application Support/Cairn/inbox/            ターンごとに1ファイル、読み取り時に削除
~/Library/Application Support/Cairn/completions.json  直近50セッション
```

コアのキューにはmacOSのプライバシー権限が**一切**不要です。アクセシビリティと
オートメーションは、跡たどりを正確にする任意の強化で、メニューバーの
**アクセス**からアプリごとに許可します。権限がなければ、アプリのアクティブ化、
次いでFinderを開く、へと静かに格下げされるだけです。完全な削除方法を含む
詳細は[SECURITY.md](SECURITY.md)を参照してください。

## そのほかのすべて

[`docs/inbox-protocol.md`](docs/inbox-protocol.md)に対してプロデューサーを
書いてください——CIパイプライン、長いビルド、別のエージェントランタイム。
最短版は1行です:

```bash
echo "All 214 tests passed." | python3 Scripts/cairn_save.py --source ci --prompt "nightly build"
```

## 意図的にノートを残す

```bash
python3 Scripts/install_agent_skills.py install
```

Claude CodeとCodexに `cairn-save` スキルをインストールします。どちらかの
エージェントに「Cairnに保存して」と頼むか、`/cairn-save` を実行すると、
意図的な結論ノートを公開します——自動のStop hookキャプチャとは別物で、
保存した場所へ跡をたどって戻れます。

## 開発

```bash
swift build && swift test                     # アプリ本体
/usr/bin/python3 Tests/protocol_roundtrip.py  # すべてのブリッジをプロトコルに照合
./Scripts/build_app.sh                        # dist/Cairn.app をパッケージ
```

プロトコルテストとSwiftテストは
[`docs/inbox-protocol.md`](docs/inbox-protocol.md)の両端を固定しています。
片方を変えれば、もう片方が文句を言うはずです。デザインシステムは装飾ではなく
構造です——色、半径、時間のすべてが
[`Sources/Cairn/DesignSystem.swift`](Sources/Cairn/DesignSystem.swift)で一度だけ
定義され、[`docs/design-system.md`](docs/design-system.md)に文書化されています。
意図的なブランド変更の後は `./Scripts/generate_app_icon.sh` でFinderアイコンを
再生成してください。

リリースはすべてのテストを実行し、ローカルで署名・公証し、タグを打ち、
DMGをアップロードします:

```bash
CAIRN_NOTARY_PROFILE="cairn-notary" ./Scripts/release.sh --version 0.7.0
```

セットアップと復旧については[リリースガイド](docs/releasing.md)を参照して
ください。

## 境界

- 信頼されたユーザーレベルhookを持つCodex CLI/Appセッション、ユーザーレベル
  `Stop` hookを持つClaude Codeセッション、プラグインが有効なHermes・OpenClaw
  セッションをカバーします。
- アプリが受け取るのは最終結果のみ——ストリーミングの進捗やツールログは
  ありません。
- ローカルに保持されるのは直近50セッション。それより古い履歴はなく、
  マシン間の同期もありません。
- macOS 14以降のみ。inboxプロトコルは移植可能ですが、このアプリは
  移植可能ではありません。

## コントリビューション

バグ報告、他ランタイムのプロデューサー、跡たどりの修正、すべて歓迎します。
[CONTRIBUTING.md](CONTRIBUTING.md)から始め、何かを提出する前にdoctorを
実行してください。

## ライセンス

Apache-2.0 — [LICENSE](LICENSE)を参照してください。

コードはオープンです。ただし**「Cairn」という名称、跡のワードマーク、
ストーンマーク**はコードとともにライセンスされません——[NOTICE](NOTICE)を
参照してください。フォークは自由です。改変したビルドを公開する場合は、
公式リリースと区別できるよう、独自の名前とアイコンを付けてください。
あなたのツールをCairnと互換、あるいはCairn inboxプロトコルの実装として
説明することは、いつでも問題ありません。
