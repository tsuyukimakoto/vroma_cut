# ビルドとテスト

コマンド例はリポジトリルートで実行します。
生成物と手元の素材はGit管理外の`.build/`と`artifacts/`に置きます。

## ビルド

macOS 15以降のApple Silicon Macと、Swift 6を含むXcodeを使用します。
Xcodeの初回設定を済ませ、Command Line Toolsを選んでください。
`xcrun swift --version`で選択したツールチェーンを確認できます。
Intel MacとUniversalビルドは未検証です。

```sh
./scripts/build.sh
open '.build/Vroma Cut.app'
```

初回はHTTPSでFFmpeg 8.0.3を取得し、固定したSHA-256を照合します。
SHA-256は取得内容の一致を検査するもので、PGP署名の検証とは異なります。
依存ライブラリの設定、ツールチェーン、CPU、SDKが変わると再ビルドします。
ビルドログは`.build/libav-build/`に保存します。
並列数は`VROMA_BUILD_JOBS`（既定値4）で指定できます。
依存ライブラリを強制的に再ビルドする場合は`VROMA_REBUILD_LIBAV=1 ./scripts/build.sh`を実行します。

取得済みの公式ソースを利用する場合は、次のように指定します。
同じSHA-256の検査が適用され、指定したファイルがなければ停止します。

```sh
./scripts/build.sh artifacts/ffmpeg-8.0.3.tar.xz
```

手順を分ける場合は、`./scripts/build-libav.sh`、`./scripts/build-app.sh`の順で実行します。
アプリは`.build/Vroma Cut.app`に生成し、ad-hoc署名を付けます。
配布用署名や公証は行いません。
アプリ実行時にNode.jsやFFmpegコマンドを呼び出すことはありません。

## 通常のテスト

```sh
./scripts/test.sh
```

依存ライブラリを準備してから`swift test`を実行します。
実素材を指定しなければ、素材が必要な6件はスキップします。
通常テストが通ったことと、実素材の書き出しを検証したことは区別してください。
CIはApple SiliconのmacOSでビルド、通常テスト、アプリ署名の検査を行います。
ビルド済みアプリやライブラリのアップロードは行いません。

## 実素材テスト

実素材テストは開発者向けの任意検証で、通常のビルド、利用、ソース公開の必須条件には含めません。
撮影動画、GPX、マークCSVはリポジトリに含めていません。
解析記録の`experiments/evidence/`はテスト素材の代わりにはなりません。
以下の例では、手元の素材を`artifacts/fixtures/`の下に配置します。
環境変数では別の保存先も指定できます。
原本は変更しません。

| 環境変数 | 素材と検証 |
| --- | --- |
| `VROMA_SAMPLE_DIR` | サンプルMP4、GPX、マークCSVがあるフォルダ。48マーク、20,225測位点、所定の日時を検査 |
| `VROMA_EXPORT_SOURCE`と`VROMA_EXPORT_ROOT` | 所定のサンプルMP4と出力先。パケット、日時、固定ハッシュ、キャンセルを検査 |
| `VROMA_FULL_DECODE=1` | 上記書き出しで全フレームのデコード検査を有効化 |
| `VROMA_BOUNDARY_SOURCE` | 対応する動画の末尾まで切り出し計画を作成 |
| `VROMA_VIDEO_FOLDER`と`VROMA_GPX` | 複数の候補を持つ動画群とGPX。切り出し計画と読み取り量を検査 |
| `VROMA_SPLIT_FOLDER` | `VID_20260911_080012_025.mp4`と`026.mp4`があるフォルダ。境界をまたぐ再生、結合、全デコードを検査 |
| `VROMA_QUEUE_SOURCE` | 対応する動画。2件の連続書き出しで名前の重複とmanifestを検査 |

サンプル専用テストは別の動画では期待値が一致しません。
`VROMA_SAMPLE_DIR`には対象のMP4、GPX、CSVをそれぞれ1ファイルずつ置いてください。

```sh
VROMA_SAMPLE_DIR="$PWD/artifacts/fixtures/sample" \
VROMA_EXPORT_SOURCE="$PWD/artifacts/fixtures/sample/VID_20260911_105443_032.mp4" \
VROMA_EXPORT_ROOT="$PWD/artifacts/test-exports" \
./scripts/test.sh

VROMA_SPLIT_FOLDER="$PWD/artifacts/fixtures/split" \
./scripts/test.sh --filter realSplitRecordingPlaysAndExportsAcrossBoundary
```

サンプルの書き出し結果は指定した出力先に残ります。
分割境界と待ち行列のテストはシステムの一時フォルダに出力し、終了時に削除します。

## 調査用コード

`experiments/`のMJSと診断用Cは製品コードとは別です。
MJSを実行する場合だけNode.jsを用意します。

```sh
node --test experiments/archive-metadata.test.mjs
```

[サンプルの構造](../experiments/SAMPLE_FORMAT.md)はFFmpeg 8.0で行った解析記録で、アプリが利用する版とは区別しています。
実素材の日時、名前、ハッシュは記録とテストの期待値として残しています。
