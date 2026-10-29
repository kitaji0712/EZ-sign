# EZ Sign の通信手順

Santek EZ Sign（NFC モデル）は ISO 14443-4（ISO-DEP）のタグとして動きます。画像の書き込みは ISO 7816-4 形式の APDU だけで完結します。

この手順は公式資料ではありません。次の 2 つの有志の実装をもとにしています。

- [fossasia/magic-epaper-app PR #688](https://github.com/fossasia/magic-epaper-app/pull/688): 2.13 インチ用の Android 実装。手順の出どころ
- [nThanksForAllTheFish/ezsign-nfc](https://github.com/nThanksForAllTheFish/ezsign-nfc)（MIT）: PC/SC リーダーで 4.2 インチ・2.9 インチの動作を実機で確認（2026-10-24）

## 手順

| 順番 | コマンド | APDU | 備考 |
|---|---|---|---|
| 1 | SELECT | `00 A4 04 00 07 D2 76 00 00 85 01 01` | NFC Forum Type 4 の NDEF アプリ |
| 2 | VERIFY | `00 20 00 01 04 20 09 12 10` | 固定の 4 バイト鍵。失敗したら 300 ms 待って 1 回だけ再試行 |
| 3 | SELECT | 1 と同じ | |
| 4 | INIT | `00 D1 00 00 00` | 書き込み開始。応答に機種情報（TLV） |
| 5 | DATA × N | `F0 D2 <番号 2 バイト> <長さ> <最大 250 バイト>` | 番号は 0 から順に |
| 6 | REFRESH | `F0 D4 85 80 00` | 描画開始 |
| 7 | POLL（繰り返し） | `F0 DE 00 00 01` | 応答の 1 バイト目が `00` なら完了。REFRESH の 1.5 秒後から 0.2 秒おき |

成功時の状態語は `90 00` です。

このアプリでは手順 1 の前に、独自の「位置確認」として SELECT を 8 回（0.1 秒おき）送り、すべて `90 00` が返ったときだけ書き込みを始めます。当てる位置がずれていて電力や通信が不安定なまま、約 25 秒の描画に入らないようにするためです。公式アプリの確認方法は分かっていません。

## 画像の形式

- 1 画素 2 ビット。バイトの上位ビットから詰めます
- 色の番号: `0` 黒、`1` 白、`2` 黄、`3` 赤
- 画素の並び順は機種で違います（`Sources/EZSignCore/PanelModel.swift`）

| 機種 | 解像度 | フレームバッファ | DATA の数 | 並び順 | 描画時間（PC で計測） |
|---|---|---|---|---|---|
| 4.2 インチ | 400×300 | 30,000 バイト | 120 | 行優先・左右反転（`row-mirror`） | 約 24 秒 |
| 2.9 インチ | 296×128 | 9,472 バイト | 38（最後は 222 バイト） | 列優先（`col`） | 約 20 秒 |
| 2.13 インチ | 250×128 | 8,000 バイト | 32 | 列優先・左右反転（`col-mirror`） | — |

## INIT の応答

タグ・長さ・値の並びです。4.2 インチの実機の例（ezsign-nfc）:

- `A0`: `F0 07 20 02 58 01 90`。`01 90`（= 400）が幅で、機種の判別に使います
- `C0`: シリアル番号（ASCII）
- `C1`: UID

## iPhone（Core NFC）での注意

- `NFCTagReaderSession` を `.iso14443` で使います。entitlements の `com.apple.developer.nfc.readersession.formats` は `TAG` だけにします。
- Info.plist の `com.apple.developer.nfc.readersession.iso7816.select-identifiers` に `D2760000850101` を入れると、iOS が検出時にその AID を SELECT し、`NFCISO7816Tag` として渡してくれます。
- NFC の機能は有料の Apple Developer Program でしか使えません（無料の Personal Team では不可）。
- 1 つのセッションは約 60 秒まで、タグとの接続は約 20 秒までという報告があります（[Apple Developer Forums](https://developer.apple.com/forums/thread/802895)）。4.2 インチは転送と描画で 25〜30 秒かかります。ただし公式アプリは iPhone で 30 秒以上かけて書き込めているので、何らかの方法で続けられるはずです。テストアプリは、接続が切れたら同じセッションでつなぎ直して POLL を続けます。実際にどうなるかは実機のログで確かめます。
