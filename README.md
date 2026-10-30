# EZ Sign

電池のいらない NFC 電子ペーパー「EZ Sign」（Santek）を iPhone から書き換えて、机の上のタスク表示に使うためのアプリです。

いまは第 1 段階として、**iPhone から書き込めるかを確かめるテストアプリ**になっています。ボタンを押してかざすと、テスト画面（4 色の見本・細かい模様・時刻）を書き込み、各手順にかかった時間をログに残します。

## 必要なもの

- Mac と Xcode 16 以降
- Apple Developer Program（有料）。無料のアカウントでは NFC の機能が使えません
- iOS 17 以降の iPhone（iPhone XS / XR 以降）
- EZ Sign 4.2 インチ 4 色モデル

## 動かし方

1. リポジトリを取得して、作業ブランチに切り替えます。非公開リポジトリなので、先に [GitHub CLI](https://cli.github.com) の `gh auth login` で GitHub にログインしておきます。
   ```sh
   git clone https://github.com/kitaji0712/ez-sign.git
   cd ez-sign
   git checkout claude/gifted-tesla-eq173c
   ```
   更新があったら、このフォルダで `git pull` を実行します。
2. `EZSign.xcodeproj` をダブルクリックして Xcode で開きます（`Package.swift` はテスト用なので開かないでください）。
3. 署名のチームは **ARTIVATION CORP.（Team ID `4YKW4T3D7N`）** に設定済みです。左の一覧で一番上の `EZSign` → TARGETS の `EZSign` → **Signing & Capabilities** で、エラーが出ていないことだけ確認してください。
   - Xcode → Settings → Accounts で、ARTIVATION CORP. の「Certificates, Identifiers, & Profiles」が ✓ になっている必要があります（ⓧ ならチームの管理者に権限を付けてもらいます）。
   - 「Revoke certificate」と出たら、「Revoke Certificate」を押すと証明書が作り直されます。
4. iPhone をケーブルで Mac につなぎ、Xcode 上部の実行先で自分の iPhone を選んで ▶（⌘R）を押します。
5. 初めての場合は iPhone 側で次の設定が必要です。
   - 設定 → プライバシーとセキュリティ → **デベロッパモード** をオン（再起動を求められます）
   - アプリを開けないときは、設定 → 一般 → **VPN とデバイス管理** で自分の開発元を信頼

## 更新をかんたんに iPhone に入れる

Finder でリポジトリのフォルダを開き、**`install-to-iphone.command` をダブルクリック**します。ターミナルが開き、次を自動で行います。

1. GitHub から最新のコードを取得する（このフォルダを GitHub と同じ状態に戻す。Xcode が書き換えた部分は消える）
2. つないでいる iPhone を探す（ケーブルでつなぎ、ロックを解除しておく）
3. ビルドする（初回は数分）
4. iPhone に入れて起動する

途中で「失敗しました」と出たら、ターミナルに出ているメッセージを Claude に貼ってください。Mac で「codesign がキーチェーンにアクセスしようとしています」と出たら、ログインパスワードを入れて「常に許可」を押します。

## 試し方

1. アプリの「EZ Sign に書き込む」をタップします。
2. iPhone の上部（カメラのあたり）を、EZ Sign の NFC の位置（公式アプリで当てている場所）に当てます。アプリがまず通信が安定しているかを確かめ（位置確認）、OK なら書き込みを始めます。「完了」と出るまで動かさないでください（30 秒前後かかります）。
3. 結果を教えてください。
   - EZ Sign に表示された画面の写真
   - 「ログをコピー」で取ったログの全文

### 見るところ

| 確認すること | うまくいっていれば |
|---|---|
| 位置確認 | 通信が不安定なときは「もう一度タッチしてください」と出て、転送が始まらない |
| 書き込めたか | 下の赤い行の番号と時刻が、今回押したときのものになっている |
| 画素の並び | 文字が左右反転していない。左上に小さな赤い四角がある |
| 色 | 黒・白・黄・赤の見本がその色で出ている |
| 細かさ | 1 ピクセルの市松模様や細い横線がつぶれていない |
| 時間 | ログに描画完了までの秒数と、つなぎ直しにかかった時間が出ている |
| NDEF セッション（実験） | 「NDEF セッションで書き込む（実験）」で、パネルの NDEF の中身がログに出て、20 秒を過ぎても切れずに描画完了まで進むか |
| 描画中の待ち方 | 「POLL し続ける」（既定）で、接続から 20 秒を過ぎても切れずに「描画完了」まで進むか |

4.2 インチは `row-mirror` で正しく表示されることを実機で確認済みです。iPhone は約 20 秒で通信を打ち切るので、描画（約 24 秒）の待ち方を設定で選べます（`docs/PROTOCOL.md`）。

## 構成

| 場所 | 中身 |
|---|---|
| `EZSign/` | iPhone アプリ（SwiftUI と Core NFC） |
| `Sources/EZSignCore/` | 画像の変換と通信手順。Apple のフレームワークを使わないので Mac / Linux でテストできます。アプリにも同じファイルが組み込まれます |
| `Tests/EZSignCoreTests/` | `EZSignCore` のテスト |
| `Config/` | Info.plist と entitlements（NFC の設定） |
| `docs/PROTOCOL.md` | EZ Sign の通信手順と出典 |

テストはリポジトリの直下で実行します。

```sh
swift test
```

## 注意

EZ Sign の通信手順は公式に公開されたものではなく、有志の解析結果をもとにしています（`docs/PROTOCOL.md`）。パネルのファームウェアが変わると動かなくなるかもしれません。
