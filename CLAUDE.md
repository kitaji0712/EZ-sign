# EZ Sign
Santek EZ Sign（NFC 給電の 4 色電子ペーパー、4.2 インチ 400×300）を iPhone から書き換えるアプリ。最終目標は机の上のタスク表示。いまは書き込みの確認用テストアプリの段階。

- 通信手順と出典は docs/PROTOCOL.md。手順は有志の解析結果なので、バイト列を推測で変えない。
- `Sources/EZSignCore/` は Foundation だけで書く（UIKit / SwiftUI / CoreNFC を import しない）。アプリにも同期フォルダとして同じファイルが入り、`swift test` で Linux / Mac からテストできる。
- `EZSign/` はアプリ本体（SwiftUI + Core NFC）。Swift 5 モード、iOS 17 以降。
- Xcode プロジェクトは同期フォルダ（objectVersion 77）なので、ファイルを足しても project.pbxproj を編集しなくてよい。
- クラウド環境には Xcode がない。Core は Docker の Swift イメージ（`mirror.gcr.io/library/swift:6.1-noble`）で `swift test`。アプリのビルドは CI（macOS）か利用者の Mac で確認する。
- 文字は内蔵の 5×7 ドットフォントで描き、アンチエイリアスしない（パネルは灰色を出せない）。
- 画面の文言・ログ・ドキュメントは日本語。
