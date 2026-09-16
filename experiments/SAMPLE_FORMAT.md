# Ace Pro 2サンプルのメディア構造

対象は`VID_20260911_105443_032.mp4`（16,127,264,292 bytes）1本。
同じ撮影モード以外への一般化を目的としない。
元MP4、GPX、マークへの書き込みは検証処理に含めない。
公開用の解析記録では、ffprobeの素材パスをリポジトリルート起点の`artifacts/fixtures/sample/`配下の例に置き換えている。
そのパスに素材を同梱していることを意味しない。

## MP4の構成

```text
MP4
├─ ftyp
├─ mdat                    映像、音声、タイムコードのサンプル
├─ moov                    トラックの目次とメタデータ
│  ├─ udta/AMBA
│  ├─ udta/nail            プレビューに関連する独自領域
│  ├─ trak                 HEVC / hvc1
│  ├─ trak                 AAC
│  └─ trak                 tmcd
└─ inst                    53,603,811 bytesの独自領域
```

映像は2688×1520、60000/1001 fps、HEVC Mainで73,413フレーム。
音声はAAC-LC、48 kHz、ステレオ。
タイムコードは30000/1001のレートで、録画全体を覆う1サンプルを持つ。
映像の長さは1224.773550秒。
AVFoundationとFFmpegが返す音声の長さは異なり、コンテナ、トラック、実表示時間を混同しない。

内部の作成日時は2026-09-11T01:54:43Zで、日本時間の10:54:43に相当する。
ファイル名の日時と一致するが、実世界の時計とのずれがゼロであることの証明にはならない。
タイムコードの`10:30:56:12`はこの日時と異なるので、撮影日時の代用にしない。

マーク48件のうち、時計補正なしでこの動画内に入るのは11:07:44.754の1件。
動画内の位置は781.754秒で、前10秒から後60秒の希望範囲は`[771.754, 841.754)`秒となる。
GPXには20,225点あり、この範囲を覆う。

## inst領域の内部

ExifToolの`ProcessInsta360`を参照した読み取りでは、末尾の識別子とディレクトリによりレコードの所在を取得できる。
MP4の3トラックには列挙されない。
1つの`inst`の内部に、複数種類のレコード群がある。

| レコード | 大きさ | 読み取れる内容 |
| --- | ---: | --- |
| `0x000` | 250 bytes | レコードのディレクトリ |
| `0x101` | 1,192 bytes | 機種、ファームウェア等。ExifToolでAce Pro 2と認識 |
| `0x200` | 688,168 bytes | プレビュー画像 |
| `0x300` | 24,496,320 bytes | 20-byte記録が1,224,816件。加速度と角速度の時系列 |
| `0x400` | 1,175,280 bytes | 16-byte記録が73,455件。露出の時系列 |
| `0x900` | 3,523,824 bytes | 本検証では未解釈 |
| `0xa00` | 35 bytes | 本検証では未解釈 |
| `0xb00` | 22,831,443 bytes | 本検証では未解釈 |

合計とbox長の差には、ディレクトリ、フッター、間隙などがある。
この表を独自領域の全バイトを意味付けした仕様とは扱わない。
加速度と角速度の識別はExifToolでも確認し、巨大な時系列は同ツールの既定制限に従って先頭20,000件の抽出にとどめた。
記録総数はレコードの大きさから計算している。
生のタイムスタンプの単位や映像とのオフセットは、別途照合が必要である。

このサンプルの独自領域は、録画ファイルに対応する時系列をまとめて格納していると考えられる。
複数ファイルに分かれた録画で、各ファイルの領域が互いに重複するか、各ファイルの範囲だけを持つかは未確認。

## 切り出しで保持する対象

映像と音声は、選択範囲の圧縮済みパケットをコピーできる。
独自領域は別途の取り扱いが必要で、`map`相当の全ストリーム選択ではコピーされない。
ライブラリのメタデータ辞書も、未知のboxの内容をすべて表現してはいない。

`inst`を未加工のまま保管することは可能だが、短いMP4に付けた場合に有効であることとは異なる。
再利用には、少なくとも動画とセンサーの時間原点、範囲、参照位置、レコード索引の整合性を確認する必要がある。
未解釈のレコードがある状態では、全情報を正しく再構成する方式を保証しない。
ユーザーが選択した方式は、独自領域を未加工の別ファイルに退避する方法である。
`archive-metadata.mjs`は`mdat`のサンプル本体を除くboxを保存し、原本の識別情報と各領域のオフセット、ハッシュをmanifestに記録する。
MP4の全体を復元するバックアップとは異なり、元の動画サンプルや、`mdat`内にある元のタイムコードサンプルも退避対象には含まれない。
切り出したMP4のタイムコードの保持は、別に検証する。

Final Cut Pro標準の手ブレ補正について、Appleは連続フレームの画素を解析する方式を説明している。
このサンプルの`inst`を標準機能が読むという根拠は確認できていない。
GyroflowとFinal Cut Pro用プラグインによる利用経路はあるが、このサンプルでの対応は未検証。
Insta360はAceシリーズのGyroflow利用をFreeFrame Videoモードに限定して説明している。

## 検証用コード

コードは製品エンジンではなく、このサンプルの制約を調べるための実験用である。
保存先は原本と分離する。
`copy-range.c`は3ストリーム、単一のタイムコードサンプル、非ドロップフレームを想定し、一般素材用には使わない。
`promote-mdta.mjs`は末尾に32-bitの`moov`を持つ制御下の出力だけを受け付ける。

| ファイル | 役割 |
| --- | --- |
| `InspectAsset.swift` | Chrovaと同じAPIで日時とトラックを読み取る |
| `inspect-container.mjs` | boxの位置と長さ、GPXの期間、対応マークを確認する |
| `inspect-insta.mjs` | 独自領域のディレクトリと既知レコードの件数を確認する |
| `copy-range.c` | libavによるパケットコピー、タイムコード再構成、出力パケットのSHA-256照合 |
| `promote-mdta.mjs` | 映像データを移動せずmovie直下のQuickTimeメタデータを配置する |
| `archive-metadata.mjs` | 元のboxを別ファイルへ退避し、原本と退避先のハッシュを照合する |
| `archive-metadata.test.mjs` | 未知box、64-bit長、重複退避、破損、入力切断の検証 |

退避の試験と自動テストは以下で実行する。
成功時は`archivedBytes`と原本のSHA-256を返し、退避先にmanifestが作成される。
同じ原本の再実行は保存済みデータを照合してから`reused: true`を返す。

```sh
node --test experiments/archive-metadata.test.mjs
node experiments/archive-metadata.mjs "$SOURCE_MP4" "$ARCHIVE_ROOT"
```

検証で使用したFFmpegは公式の8.0ソース。
tar.xzのSHA-256は`b2751fccb6cc4c77708113cd78b561059b6fa904b24162fa0be2d60273d27b8e`。
これは使用ソースの識別値であり、署名検証の代わりではない。
構成は`--disable-everything --disable-autodetect --disable-doc --disable-programs --enable-ffprobe --enable-demuxer=mov --enable-muxer=mp4 --enable-protocol=file --enable-parser=hevc,aac --enable-decoder=hevc,aac --disable-network`。
エンコーダーを有効化しない構成で、切り出しコードはlibavを直接リンクする。

ビルドディレクトリを`FFBUILD`、展開したソースを`FFSOURCE`、作業ディレクトリを`LAB`に設定した場合の例。
各変数は実際の絶対パスに設定する。

```sh
cc -O2 -I"$FFBUILD" -I"$FFSOURCE" experiments/copy-range.c \
  "$FFBUILD/libavformat/libavformat.a" \
  "$FFBUILD/libavcodec/libavcodec.a" \
  "$FFBUILD/libavutil/libavutil.a" -lm -o "$LAB/copy-range"
"$LAB/copy-range" "$SOURCE_MP4" "$LAB/cut.mp4" \
  771437333 841841000 2026-09-11T02:07:34.437333Z 1
node experiments/promote-mdta.mjs "$LAB/cut.mp4" "$LAB/final.mp4"
swift experiments/InspectAsset.swift "$LAB/final.mp4"
```

この範囲の映像は4,220パケット、音声は3,300パケット。
コードが出力する`MATCH`は出力前後の圧縮済みペイロードと件数の一致を示す。
タイムコードの`VERIFIED`は再生成したカウンタ値の一致を示し、元サンプルのバイト列一致は意味しない。
試験出力には独自領域が含まれず、全情報保持の合格結果ではない。

## 一次資料

- [ExifToolのInsta360解析コード](https://github.com/exiftool/exiftool/blob/master/lib/Image/ExifTool/QuickTimeStream.pl)
- [FFmpeg 8.0のMP4 muxer](https://github.com/FFmpeg/FFmpeg/blob/n8.0/libavformat/movenc.c)
- [AppleのQuickTimeメタデータ配置](https://developer.apple.com/documentation/quicktime-file-format/metadata_atoms_and_types)
- [Final Cut Proの標準手ブレ補正](https://support.apple.com/guide/final-cut-pro/correct-shaky-video-verbacf92b/mac)
- [Insta360の撮影モードとGyroflow対応](https://onlinemanual.insta360.com/acepro2/en-us/operation-tutorials/shoot-preview/shooting-parameters/stabilization)
- [Gyroflow Toolbox](https://github.com/latenitefilms/GyroflowToolbox)
