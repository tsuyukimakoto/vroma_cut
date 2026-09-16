# 第三者ライセンス

## 自作部分

特記のないアプリ、テスト、ビルドスクリプト、文書は[MIT License](LICENSE)で提供します。
以下の第三者コードとライセンス文書自体には、MIT Licenseを適用しません。

## FFmpeg

アプリはFFmpeg 8.0.3のlibavformat、libavcodec、libavutilを静的リンクします。
著作権はFFmpegの各著作者に帰属します。
利用構成のライセンスはLGPL-2.1-or-laterです。

- [公式ソース](https://ffmpeg.org/releases/ffmpeg-8.0.3.tar.xz)
- SHA-256: `6136812ea6d4e68bdba27e33c2a94382711cdf4f8602ffef056ff792bd6f9818`
- [LGPL 2.1全文](licenses/LGPL-2.1.txt)
- [FFmpegのライセンス説明](https://ffmpeg.org/legal.html)
- ビルド設定：[scripts/build-libav.sh](scripts/build-libav.sh)

GPL、nonfree、外部ライブラリの自動検出を無効にし、MOV/MP4、HEVC、AACとローカルファイルの処理に必要な機能を有効にします。
FFmpegのソースコード自体は変更しません。
取得したソースと生成物はGit管理外の`.build/`に置きます。
アプリにはFFmpegのライセンス全文、上流のLICENSE.md、この文書と自作部分のLICENSEを同梱します。

このリポジトリではビルド済みアプリを配布しません。
静的リンクしたバイナリを再配布する場合は、ライセンス表示だけでなく、対応するライブラリのソースや、変更したライブラリで再リンクできる材料と手順の提供など、LGPL第6条に従う必要があります。
このビルド手順だけでバイナリ再配布の条件をすべて満たしたとは扱わないでください。
コーデックに関する特許の扱いは、著作権ライセンスとは別です。

## ExifTool由来の診断コード

`experiments/inspect-insta.mjs`は、ExifToolの`QuickTimeStream.pl`にある`ProcessInsta360`を参考に、JavaScriptでディレクトリとレコードを読み取る診断用に書き換えたコードです。
プレビューやセンサー値の完全な抽出、書き換え機能は含みません。
アプリのビルドには組み込まれません。

- 上流著作権：Copyright 2003–2026, Phil Harvey
- JavaScriptへの変更：Copyright 2026, Makoto Tsuyuki（2026-09-11）
- [参照元](https://github.com/exiftool/exiftool/blob/master/lib/Image/ExifTool/QuickTimeStream.pl)
- [上流の利用条件](https://github.com/exiftool/exiftool/blob/master/README)：Perlと同じ条件（Artistic LicenseまたはGPL）

この診断ファイルはGPL-2.0-or-laterで提供します。
[GPL 2.0全文](licenses/GPL-2.0.txt)を同梱しています。
