# けはい — 音だけの思い出帳

ポケットに入れておくだけで、子どもの笑い声・うた・おしゃべりが聞こえた瞬間の前後だけを残すアプリの試作です。
映像はなく、音だけ。ほかの音は端末の中ですぐ消え、どこにも送りません。

| 版 | 場所 | 状態 |
|---|---|---|
| ブラウザ版（ホーム画面に置ける） | `web/` → `docs/`（GitHub Pages） | 合成音で動作確認済み |
| iPhone アプリ（SwiftUI） | `ios/` | **まだ一度もビルドしていません**（下の「いまの検証状況」） |

## iPhone で試す（ブラウザ版）

1. iPhone の Safari で https://hoki-k.github.io/kehai/ を開く
2. 共有ボタン →「ホーム画面に追加」
3. ホーム画面の「けはい」を開いて「耳をすます」

ブラウザ版は、画面をロックしたりほかのアプリに切り替えたりすると、聴くのが止まる可能性が高いです（iPhone 実機では未確認）。
そのため画面を暗くする「ポケットモード」があります。

## iPhone アプリ（ネイティブ版）

画面を消してポケットに入れても聴きつづける版です。Mac と Xcode が必要です。

### 必要なもの

- Mac と Xcode 16 以降（プロジェクトが Xcode 16 の形式のため。Xcode 15 では開けません）
- iPhone（iOS 17 以降）と USB ケーブル
- Apple ID（無料のもので可）

### 入れ方

1. このリポジトリを Mac に clone して、`ios/Kehai.xcodeproj` をダブルクリックで開く
2. Xcode の「Settings…」→「Accounts」で Apple ID を追加する
3. 左の一覧で「Kehai」→ TARGETS の「Kehai」→「Signing & Capabilities」→ Team に自分の Apple ID を選ぶ
   - 「Bundle Identifier が使えない」と出たら、`jp.hoki.kehai` を `jp.hoki.kehai2` などに変える
4. iPhone を Mac につなぎ、iPhone の「設定」→「プライバシーとセキュリティ」→「デベロッパモード」をオンにする（再起動が入ります）
5. Xcode 上部の実行先で自分の iPhone を選び、▶（Run）を押す
6. 初回だけ、iPhone の「設定」→「一般」→「VPNとデバイス管理」で自分の Apple ID を信頼する

無料の Apple ID で入れたアプリは 7 日で開けなくなります。そのときはもう一度 ▶ を押してください。
ほかの人に配る（TestFlight）には、有料の Apple Developer Program への登録が必要です。

実行（Run）は Release 設定にしてあります。録音ファイルの解析が Debug だと遅いためです。

### ネイティブ版でやっていること

- 画面ロック中も聴きつづける（バックグラウンドオーディオ）。電話などで止まったら、終わったあと自動で再開を試みる
- マイクの雑音除去・自動音量調整はオフ（`AVAudioSession` の `.measurement` モード）。空気感をそのまま残すため
- AirPods などの Bluetooth マイクは使わない（音が細くなるため）。有線・USB のピンマイク受信機は「せってい」で選べる
- 直近 60 秒だけをメモリに置き、拾った瞬間だけを WAV（24kHz・16bit・モノラル）で保存。保存先は「ファイル」アプリの「このiPhone内」→「けはい」→「Moments」
- 再生中は、自分の再生音を拾わないよう検出を止める
- 「録音ファイルから拾う」: ピンマイクやボイスメモの録音、動画から瞬間を探す。長い録音でもメモリに載せきらないよう、2 回に分けて読む
- 長押しで 1 つずつ共有（AirDrop・LINE など）、「せってい」からまとめて書き出し

### いまの検証状況

- このリポジトリを作った環境では Swift をコンパイルできなかったため、iOS 版は**まだ一度もビルドしていません**。最初のビルドでエラーが出る可能性があります
- 検出ロジック（`ios/Kehai/Detection.swift`）はブラウザ版と同じ規則・同じ数値で移植しています。Mac で次を実行すると、ブラウザ版と同じ瞬間を拾うかを確かめられます

```sh
python3 test/gen.py test/test.wav          # 合成のテスト音（numpy が必要）
swiftc -O ios/Kehai/Detection.swift ios/Tools/main.swift -o /tmp/kehai-check
/tmp/kehai-check test/test.wav             # 「OK: matches the web version」なら一致
```

- 本物の子どもの声では、ブラウザ版・iOS 版とも未検証です
- 電池の減り方、画面ロック中にどれだけ長く聴きつづけられるかは未計測です

## ブラウザ版を直すとき

`web/kehai.html` を直して `sh web/build.sh` を実行すると、`docs/` が更新されます（GitHub Pages はここを公開）。
`web/kehai.html` は claude.ai の Artifact と同じファイルです。

```sh
python3 -m http.server 8765 &      # リポジトリ直下で
node test/file_test.js             # 録音ファイルから 4 つ（笑い声・うた・おしゃべり・大きな声）拾えるか
node test/live_test.js             # マイク入力の代わりにテスト音を流して確かめる（約 3 分半）
```

Playwright と Chromium が必要です。

## フォルダ

```
web/        ブラウザ版のソース（kehai.html 1 ファイル）と build.sh、service worker
docs/       GitHub Pages で公開するもの（build.sh が作る）
ios/        iPhone アプリ（Kehai.xcodeproj、Kehai/ にソース）
ios/Tools/  検出ロジックを Mac のターミナルで確かめる小さなプログラム
test/       テスト音の生成とブラウザでの自動テスト、アイコン生成
```
