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

`Tests/OctetlyTests/` に swift-testing のテストがある。対象は入力を解釈する純粋な
ロジック (`ScanRange` / `IPv4` / `OUIDatabase`) だけで、UI とネットワーク I/O は
入っていない。

```shell
swift test
```

これはリリースビルドの門番でもある (`.github/workflows/release.yml` の test job)。
テストを消す・落としたまま放置するとリリースが出せなくなる。

UI やネットワークに触るコードを `swift test` から検証する手段は無い。手元で
1 ファイルのロジックだけ試したい時は、対象のソースを直接 `swiftc` に渡して
スクラッチのハーネスと一緒にコンパイルする方法も使える。

```shell
swiftc -swift-version 6 -o /tmp/check \
  Sources/octetly/Network/IPv4.swift Sources/octetly/Network/ScanRange.swift \
  <ハーネス>/main.swift
```

バンドルされたリソースを参照するファイル (`grep -rn 'BundledResource' Sources/` で確認) は
この方法では通らない。その関数だけ除いたコピーを作るか、対象から外す。

ネットワークの計測を A/B する時は**実行の間に冷却を挟む**。掃引を連続で走らせると
経路側にスロットルされ、条件と無関係に検出数が変動して比較が成立しない。判定は
`ping` の並列掃引との同時刻比較で行う。

## 配布物

`swift run` / `swift build` が作るのは .app バンドルではない。配布する .app は
`scripts/make-app.sh` が組み立てる (universal バイナリ + リソース + AppIcon.png から
起こした .icns + `packaging/Info.plist`)。dmg は `scripts/make-dmg.sh`。署名と公証は
`.github/workflows/release.yml` が行い、手元では署名なしの .app ができる。

version の出どころは**リポジトリ直下の `VERSION` ファイル 1 つ**。`Info.plist` の
`CFBundleShortVersionString` は make-app.sh がここから埋める。

### リソースの参照は `BundledResource` を通す

**`Bundle.module` を直接呼ばないこと。** SwiftPM が生成するアクセサは、リソース
バンドルを `Bundle.main.bundleURL` の直下 (= `Octetly.app/` の直下) に探しに行く。
.app の最上位には `Contents` 以外を置けない (置くと署名が壊れる) ので、バンドル版では
そこに置きようがない。**見つからない時は nil ではなく `fatalError` なので、素朴に
書くと配布版が起動時に落ちる。**

そのため make-app.sh はリソースバンドルの中身を `Contents/Resources` に展開し、
`BundledResource.url(forResource:withExtension:)` が `Bundle.main` を先に、
`Bundle.module` を後に見る。`swift run` では前者が空振りして後者が当たる。

**バンドル版と `swift run` で挙動が変わる**箇所は他にもある
(`OctetlyApp.swift` の `applyDockIcon` は Info.plist の有無で分岐する)。
片方でしか確認しない変更を入れないこと。

## 生成データ

`Sources/octetly/Resources/oui.csv` は IEEE の 3 レジストリを統合した生成物
(5.4 万行)。手で編集しない。更新は:

```shell
python3 scripts/update-oui.py
```

レビューやコードリーディングでは対象から外すこと。

## 課題管理

`_issues/<YYYYMMDD>-<概要>/ISSUE.md`。`.gitignore` に入れてあるのでコミットされない。
