# Octetly

macOS の LAN スキャナ。SwiftUI + AppKit、SwiftPM パッケージ (実行ファイル 1 つ)。
Swift 6.2 / macOS 14 以上、swiftLanguageModes は .v6 (strict concurrency)。

機能と設計判断は README.md に書いてある。ここには作業手順だけを置く。

## ビルドと実行

```shell
swift build
swift run Octetly
```

よく使うタスクは `.jj-menu.yaml` に入れてある (`jj-menu` で開く)。ARP/NDP キャッシュの
生ダンプと、ローカルネットワーク権限の設定を開く項目もそこにある。

**Claude Code のサンドボックス下では `swift build` が通らない。** SwiftPM は
マニフェストのコンパイルを自前の `sandbox-exec` の中で実行するが、それを入れ子に
できず `sandbox_apply: Operation not permitted` で落ちる。`/sandbox` で解除するか、
ユーザーに実行を依頼すること。

## テスト

テストターゲットは無い。ロジックを検証したい時は、対象のソースを直接 `swiftc` に
渡してスクラッチのハーネスと一緒にコンパイルする。

```shell
swiftc -swift-version 6 -o /tmp/check \
  Sources/octetly/Network/IPv4.swift Sources/octetly/Network/ScanRange.swift \
  <ハーネス>/main.swift
```

`Bundle.module` を参照するファイル (`grep -rn 'Bundle.module' Sources/` で確認) はこの方法では
通らない。その関数だけ除いたコピーを作るか、対象から外す。

ネットワークの計測を A/B する時は**実行の間に冷却を挟む**。掃引を連続で走らせると
経路側にスロットルされ、条件と無関係に検出数が変動して比較が成立しない。判定は
`ping` の並列掃引との同時刻比較で行う。

## 生成データ

`Sources/octetly/Resources/oui.csv` は IEEE の 3 レジストリを統合した生成物
(5.4 万行)。手で編集しない。更新は:

```shell
python3 scripts/update-oui.py
```

レビューやコードリーディングでは対象から外すこと。

## 課題管理

`_issues/<YYYYMMDD>-<概要>/ISSUE.md`。`.gitignore` に入れてあるのでコミットされない。
