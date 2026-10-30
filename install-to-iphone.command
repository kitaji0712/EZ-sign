#!/bin/bash
# 最新のコードを GitHub から取ってきて、ビルドし、つないでいる iPhone に入れて起動する。
# Finder でダブルクリックすると、ターミナルが開いて実行される（iPhone はケーブルでつないで、ロックを解除しておく）。
#
# このフォルダは GitHub と同じ状態に戻す（git reset --hard）。Xcode が書き換えた部分は消える。

# 途中で git reset がこのファイル自体を書き換えても動き続けるよう、全体を関数にしてから実行する
main() {
    set -euo pipefail
    trap 'echo; echo "失敗しました。上に出ているメッセージを Claude に貼ってください。"' ERR
    cd "$(dirname "$0")"

    local branch="claude/gifted-tesla-eq173c"
    local bundle_id="com.kitaji0712.ezsign"
    local app="build/Debug-iphoneos/EZSign.app"

    echo "== 1/4 最新のコードを取得"
    git fetch origin "$branch"
    git reset --hard "origin/$branch"
    git log --oneline -1

    echo
    echo "== 2/4 つないでいる iPhone を探す"
    # DEVICE_ID を指定すればその端末を使う。なければ、使える状態の端末のうち iPhone を優先して 1 台
    local device_id="${DEVICE_ID:-}"
    if [ -z "$device_id" ]; then
        local usable
        usable=$(xcrun devicectl list devices 2>/dev/null | grep -E 'available|connected' | grep -v 'unavailable' || true)
        device_id=$( { echo "$usable" | grep -i 'iphone' || true; echo "$usable"; } \
            | grep -Eo '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1 || true)
    fi
    if [ -z "$device_id" ]; then
        echo "iPhone が見つかりません。ケーブルでつなぎ、ロックを解除してから、もう一度ダブルクリックしてください。"
        xcrun devicectl list devices || true
        exit 1
    fi
    echo "使う端末: $device_id"

    echo
    echo "== 3/4 ビルド（初回は数分かかります）"
    xcodebuild -quiet -project EZSign.xcodeproj -target EZSign -configuration Debug -sdk iphoneos \
        -allowProvisioningUpdates SYMROOT="$PWD/build" build
    echo "ビルドできました: $app"

    echo
    echo "== 4/4 iPhone に入れて起動"
    xcrun devicectl device install app --device "$device_id" "$app"
    xcrun devicectl device process launch --device "$device_id" "$bundle_id" \
        || echo "（自動で起動できませんでした。iPhone のホーム画面から EZ Sign を開いてください）"

    echo
    echo "完了しました。iPhone で EZ Sign アプリを使ってください。"
}

main "$@"
exit
