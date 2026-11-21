# Codex Idle Update

Mac の ChatGPT デスクトップアプリで、Codex の作業が途切れるのを待って準備済みの更新を適用する非公式ツールです。

## 試作版を試す

対象は macOS 14 以降の Apple Silicon または Intel Mac です。「アプリケーション」フォルダに Codex を含む ChatGPT.app が必要です。

1. [リリース一覧](../../releases)から試作版の ZIP をダウンロードして展開します。
2. **Codex Idle Update.app** を「アプリケーション」フォルダに移して開きます。
3. **自動更新を有効にする**を選びます。macOS がバックグラウンド実行の許可を求めたら、アプリからシステム設定を開きます。
4. 停止するときは、アプリを開いて **自動更新を停止** を選びます。

試作版は Developer ID による署名と Apple の公証を行っていません。ダウンロードしたコピーを macOS が開けない場合は、署名・公証済みの配布版が必要です。

## 動作

macOS の LaunchAgent がログイン後に5分ごとにヘルパーを起動します。ヘルパーは ChatGPT の内蔵アップデーターが用意した新しいビルドが見つかった場合に、ローカルの実行状態を調べます。作業が落ち着くと通常終了を依頼し、内蔵アップデーターの処理が終わってから ChatGPT をバックグラウンドで開き直してビルド番号を確認します。

現行の ChatGPT の内部状態に依存します。期待するデータベースや作業状態を確認できなければ更新を延期します。最後の状態確認から終了要求までの短い間に新しい作業が入る可能性は残ります。

Apple Silicon Mac で ZIP の展開、アプリの起動、同梱ヘルパーによる更新準備と作業中の検出を確認済みです。新規環境での初回有効化から ChatGPT 本体の更新・再起動までと、Intel Mac での実行は未検証です。

## ビルド

macOS 上の Xcode Command Line Tools でビルドします。出力先には新規ファイルの絶対パスを指定します。

```sh
./distribution/build.sh "$PWD/Codex-Idle-Update-preview.zip"
```

配布用にビルドする場合は `DEVELOPER_ID_APPLICATION` に署名 ID を指定します。公開前の公証は [Apple の配布手順](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution/)に従って行います。

## ライセンス

[MIT License](LICENSE)
