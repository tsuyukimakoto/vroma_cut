# Vroma Cut

- このユーザーの制作物のbundle identifier、UTTypeなどの逆ドメイン形式のidentifierは`com.tsuyukimakoto`配下に置く。所有を確認していないドメインを推測で使わない
- このアプリのbundle identifierは`com.tsuyukimakoto.vroma.cut`、プロジェクト書類のUTTypeは`com.tsuyukimakoto.vroma.cut.project`
- 製品はSwift主体とし、libavの接続だけをCで実装する。Node.jsとFFmpeg実行バイナリを製品の依存にしない
- 原本は変更せず、自動削除しない。独自領域は原本ごとに未加工の別ファイルへ退避し、復元やメーカーソフトでの再利用を保証しない
- このAGENTS.mdとPackage.swiftがあるリポジトリルートを、編集とビルドの起点にする。個人の絶対パスや別のチェックアウトを正本として固定しない
