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
bundle exec bin/punch crontab              # cron 設定例を表示
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

## スケジューリング（cron + pmset）

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
