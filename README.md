# ak4-punch

マネーフォワード クラウド勤怠Plus（旧AKASHI）に、平日の決まった時刻に出勤/退勤を自動打刻するCLIツール。

## 必要要件
- Ruby 3.1+（開発は 3.4.10 で確認）、Bundler
- 常時起動している端末（該当時刻に確実に cron が発火する環境）
- AKASHI 側で「公開API利用可否」を「利用する」に設定し、マイページでアクセストークンを発行

## セットアップ

```bash
bundle install

# 1) 接続情報（機密）
cp .env.example .env
#   AK4_BASE_URL   … ログイン後URLのドメイン（通常 atnd.ak4.jp / AWJ系 atnd-awj.ak4.jp）
#   AK4_COMPANY_ID … 企業ID
#   AK4_TOKEN      … マイページで発行したアクセストークン（有効期限「1ヶ月と1日」）

# 2) 動作設定
cp config/config.example.yml config/config.yml
#   出勤/退勤時刻、対象日（平日のみ・祝日スキップ・除外日・追加出勤日）、冪等性、トークンを調整

# 3) トークンを本ツール管理下に置く（token.json を作成し有効期限を確定）
bundle exec bin/punch refresh_token
```

> `.env` / `config/config.yml` / `config/token.json` は `.gitignore` 済みです。

## 使い方

```bash
bundle exec bin/punch clock_in             # 出勤(type=11)を打刻
bundle exec bin/punch clock_out            # 退勤(type=12)を打刻
bundle exec bin/punch clock_in --dry-run   # 送信せず動作予定だけ表示
bundle exec bin/punch clock_in --force     # 対象日判定・重複チェックを無視して即時打刻
bundle exec bin/punch clock_out --window 5 # 指定時刻から0〜5分のランダムな時刻に打刻
bundle exec bin/punch clock_out --random   # ランダム打刻ON（分数は設定値／既定5分）
bundle exec bin/punch status               # 本日の打刻状況を表示（--date=YYYY-MM-DD）
bundle exec bin/punch refresh_token        # トークンを再発行して保存
bundle exec bin/punch daemon               # カレンダー連動デーモンを起動（推奨・下記）
bundle exec bin/punch plan                 # 当日の打刻計画をドライラン表示（--date=YYYY-MM-DD）
bundle exec bin/punch recheck              # 稼働中デーモンに当日計画の再チェックを要求（休暇誤検知の復旧等）
bundle exec bin/punch launchd              # LaunchAgent の設定例を表示（推奨）
bundle exec bin/punch sudoers              # pmset 自動起床の sudoers 設定例を表示
bundle exec bin/punch crontab              # cron 設定例を表示（代替・レガシー）
```

動作:
1. 対象日判定 — 平日のみ・日本の祝日はスキップ（`holiday_jp`）。除外日/追加出勤日を設定で調整。
2. トークン自動更新 — 有効期限が閾値（既定7日）以内になったら自動で再発行し `config/token.json` を更新。
3. ランダム待機（任意） — ウィンドウ設定時は 0〜N分のランダム秒だけ `sleep` してから打刻（下記）。
4. 冪等な重複チェック — 打刻前に当日の打刻をGETし、同種があればスキップ（手動打刻・cron再実行との二重登録を防止）。
5. 打刻 — 出勤/退勤を実行時刻で記録。

### ランダム打刻
指定時刻から N 分以内のランダムな時刻に打刻できます。
AKASHI は記録時刻＝リクエスト到着時刻のため、cron は指定時刻（ウィンドウ先頭）に起動し、プロセスが 0〜N分の乱数秒だけ `sleep` してから打刻します（＝記録時刻の後ろ倒し）。

```yaml
# config/config.yml の work: に設定（既定 0＝指定時刻ちょうど、最大 30 分）
work:
  clock_out: "18:20"           # ウィンドウ先頭（cron 起動時刻）
  random_window_minutes: 5     # in/out 共通。→ 退勤は 18:20〜18:25 のどこか
  # clock_in_window: 0         # 出勤/退勤で別々にしたい場合は個別上書き
  # clock_out_window: 5
```

- コマンドラインでも上書き可: `--window N`（0で無効）/ `--random`（設定値、無ければ既定5分）。
- `--force` は手動確認向けにその場で即時打刻します（待機なし）。
- 待機中に Mac が再スリープしないよう、`crontab` 出力はウィンドウ有効時のみ `caffeinate -i` を前置します。

## カレンダー連動デーモン（推奨）

常駐デーモン（`punch daemon`）が、出勤は所定時刻＋揺らぎで、退勤はローカルのカレンダー連携システム sukesan の当日イベントに合わせて動的に打刻します。cron の固定時刻運用に代わる推奨方式です。

仕組み:
- 出勤 = 所定時刻(`work.clock_in`) + 揺らぎ（従来のウィンドウ機構。日毎に1回だけ乱数秒を決めて固定）。
- 退勤 = sukesan の「最後の業務イベントの終了時刻」に合わせる。末尾から会食・懇親会などの除外キーワードに一致するイベントを飛ばし、最後の業務イベントの終了時刻を採用。所定退勤時刻より早ければ所定時刻を採用（max 則）。ここにも退勤側の揺らぎを加算。
- `calendar.refresh_interval_minutes`（既定15分）ごとに sukesan を再取得して退勤目標を再計算。会議が延びれば目標も後ろ倒しに追随します。
- 退勤の打刻直前にも最終再取得を行い、直前の会議延長にも追随します（延長を検知したら打刻を延期し、新しい目標で改めて打刻。再取得に失敗した場合は現在の目標で打刻）。再取得間隔を広めに設定しても直前の延長を取りこぼしません。
- tick（`daemon.tick_seconds`）ごとに「目標時刻 <= 現在 <= 目標+`late_grace_minutes`」を判定して打刻。grace を過ぎた場合はスリープ寝過ごし等での誤時刻打刻を避けるため打刻せず警告します。
- sukesan が停止・エラーのときは所定退勤時刻＋揺らぎへフォールバックし、復旧すれば次回再取得で追随します。
- 対象日判定（平日/祝日/除外日/追加出勤日）・二重打刻の冪等チェックは従来どおりアプリ側で行います。

### セットアップ

```bash
# 1) sukesan で APIキー（64文字）を発行し .env に設定
#    SUKESAN_BASE_URL … 既定 http://127.0.0.1:3000（ループバック限定）
#    SUKESAN_API_KEY  … 発行したキー（機密）

# 2) config/config.yml の calendar: / daemon: を調整（除外キーワード等）

# 3) 計画の確認（AKASHI には触らず sukesan への GET のみ。未起動でもフォールバック表示で落ちない）
bundle exec bin/punch plan
bundle exec bin/punch plan --date=2026-07-13

# 4) スリープ自動起床を使うなら pmset を sudoers で許可（任意）
bundle exec bin/punch sudoers    # 出力の1行を sudo visudo -f /etc/sudoers.d/ak4-punch で設置

# 5) LaunchAgent として常駐登録
bundle exec bin/punch launchd    # 出力の plist を ~/Library/LaunchAgents/ へ設置し launchctl load
```

`punch plan` の出力では、取得イベント一覧（時刻・タイトル・採用/除外/対象外の判定）と、決定した出勤・退勤の目標時刻、フォールバックの有無を確認できます。

### 休暇の自動検知

カレンダーに休暇イベントがある日は、その日の打刻を丸ごとスキップします。AKASHI は休暇申請日でも打刻を受理してしまう（実機確認済み）ため、この検知が休暇日の誤打刻を防ぐ主手段です。

判定条件（両方を満たすイベントが1件でもあれば休暇日）:
- タイトルが `calendar.leave_keywords`（既定: 休暇/有給/年休/全休/休み）に部分一致
- 「終日イベント」または「継続時間が `calendar.leave_min_duration_hours`（既定4時間）以上」

継続時間の閾値は、短時間（例: 2時間）の「XX休み」のような中抜けイベントを休暇と誤検知しないためのものです。

動作:
- 計画時（起動時・日付変化時）に検知 → その日は打刻計画を作らず、翌営業日の起床予約のみ行います。
- 日中の再取得や退勤直前チェックで検知 → 以降の打刻を中止します（例: 朝の出勤打刻後に休暇イベントを入れた場合、退勤打刻は止まります）。
- 注意: 打刻済みの分は自動では取り消せません。AKASHI 側で手動削除してください。
- カレンダー取得に失敗した日は休暇判定できないため、通常営業日として動作します。

誤登録時の復旧（誤って休暇イベントを入れて打刻が止まった場合）:

```bash
# 1) カレンダーのイベントを修正（削除 or タイトル変更）
# 2) 稼働中デーモンに再チェックを要求（当日を再取得・再判定して計画を作り直す）
bundle exec bin/punch recheck
```

`punch plan` でも休暇検知の結果を事前確認できます（「休暇検知: イベント『X』（終日）→ この日は打刻しません」と表示されます）。

### スリープ対策（デーモンによる自動起床）

`daemon.manage_wake: true` かつ `punch sudoers` の設定済みなら、デーモンが計画確定/変更のたびに残りの打刻予定について「目標時刻 - `wake_lead_minutes`」の一回限り pmset 起床を予約し直します（`sudo -n pmset schedule ...`）。sudoers 未設定でパスワードが要る場合は当日中は自動起床を無効化し、警告ログを出してデーモンは動作を続けます。

- 自動起床を使わない場合は `manage_wake: false` にし、常時電源接続＋スリープ無効での運用を推奨します。

---

## スケジューリング（cron + pmset）（代替・レガシー）

> 常駐デーモン（上記）の利用を推奨します。以下は cron による固定時刻運用（退勤のカレンダー連動なし）で、デーモンを使わない場合の代替手段です。

打刻したい時刻に cron で起動します。`crontab` コマンドが PATH を自動解決した cron 行と、Mac を起こす pmset コマンドを出力します。

```bash
bundle exec bin/punch crontab   # 設定例を出力（下記を貼り付け／実行）
crontab -e                      # 出力された PATH 行＋2行を貼り付け
```

出力例（出勤 9:30 / 退勤 18:00・平日のみ。祝日/除外日/二重打刻はアプリ側でスキップ）:
```cron
PATH=/Users/you/.rbenv/versions/3.4.10/bin:/usr/bin:/bin
30 9 * * 1-5 cd /path/to/ak4-punch && bin/punch clock_in  >> /path/to/ak4-punch/punch.log 2>&1
0 18 * * 1-5 cd /path/to/ak4-punch && bin/punch clock_out >> /path/to/ak4-punch/punch.log 2>&1
```

### スリープ対策（pmset で自動起床）
cron はスリープ中に過ぎた時刻を後追い実行しません（＝変な時刻に打刻される事故がない安全側）。
そのため、打刻時刻に Mac を起こしておきます。

`pmset repeat` は起床予約を1つしか持てないため、朝・夕の2回を起こすには「一回限り予約(`pmset schedule`)」を使います。
`schedule_wakes` が、平日のみ（祝日/除外日を除外）で出勤/退勤の少し前に起こす予約コマンドを出力します。

```bash
bundle exec bin/punch schedule_wakes --days 10   # 10営業日分の予約コマンドを出力
# 出力された「sudo pmset schedule cancelall」→ 各「sudo pmset schedule wake ...」を実行
pmset -g sched                                    # 予約確認
```

- 一回限り予約は消化されると減るため、時々（残数を `pmset -g sched` で見つつ）再実行して補充します。
- 手動補充が面倒なら、フル自動化（一度だけ sudoers に pmset を許可し、打刻後に次の起床を自動再予約）も可能です（別途セットアップ）。

補足（Apple Silicon / ノート）:
- 電源接続＋蓋オープンが確実。蓋を閉じてバッテリーだと深いスタンバイで起床しないことがあります。
- 電源OFF からの起動は Apple Silicon では非対応（スリープ→起床のみ）。
- cron が macOS のセキュリティで動かない場合は、システム設定 > プライバシーとセキュリティ > フルディスクアクセス で `/usr/sbin/cron` を許可。

## トークンについて
- 有効期限は「1ヶ月と1日」。本ツールは期限が近づくと自動再発行します。
- 長期間実行しないと失効し、自動再発行もできなくなります。その場合はマイページで再発行 → `.env` を更新 → `config/token.json` を削除 → `bundle exec bin/punch refresh_token`。

## テスト
```bash
bundle exec rspec
```

## 検証用スクリプト
`scripts/verify_stamped_at.rb` … 打刻API の `stampedAt` 挙動を実機確認する Phase 0 用スクリプト（stdlibのみ）。
