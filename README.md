# ak4-punch

マネーフォワード クラウド勤怠Plus（旧AKASHI）へ出勤/退勤を自動打刻する常駐デーモン。
退勤はローカルのカレンダーAPI（sukesan）の最終業務イベントに追随し、休暇イベントを検知した日は打刻しません。

## 重要な前提

- AKASHI の打刻APIは「リクエスト受信時刻」で記録します（任意時刻の遡り登録は不可・実機検証済み）。そのため本ツールは「打刻したい時刻にAPIを呼ぶ」設計です。
- AKASHI は休暇申請日でも打刻を受理します。休暇日の誤打刻はカレンダーの休暇イベント検知で防ぎます。

## 必要要件

- Ruby 3.1+（開発は 3.4.10 で確認）、Bundler
- AKASHI 側で「公開API利用可否」を「利用する」に設定し、マイページでアクセストークンを発行
- カレンダーAPI sukesan が同一マシンで稼働していること（127.0.0.1 限定）
- Mac（launchd で常駐・pmset で自動起床）。電源接続での運用を推奨

## セットアップ

```bash
bundle install

# 1) 接続情報（機密）
cp .env.example .env
#   AK4_BASE_URL     … ログイン後URLのドメイン（通常 atnd.ak4.jp / AWJ系 atnd-awj.ak4.jp）
#   AK4_COMPANY_ID   … 企業ID
#   AK4_TOKEN        … マイページで発行したアクセストークン
#   SUKESAN_BASE_URL … 既定 http://127.0.0.1:3000
#   SUKESAN_API_KEY  … sukesan で発行した APIキー（64文字）

# 2) 動作設定（打刻時刻・揺らぎ・除外/休暇キーワード・除外日など）
cp config/config.example.yml config/config.yml

# 3) トークンを本ツール管理下に置く（token.json を作成し有効期限を確定）
bundle exec bin/punch refresh_token

# 4) 計画を確認（sukesan への GET のみ。AKASHI には触らない）
bundle exec bin/punch plan

# 5) pmset 自動起床を sudoers で許可（出力の1行を visudo で設置）
bundle exec bin/punch sudoers

# 6) LaunchAgent として常駐登録（出力の plist を設置して launchctl load）
bundle exec bin/punch launchd
```

> `.env` / `config/config.yml` / `config/token.json` は `.gitignore` 済みです。

## 日常運用

```bash
bundle exec bin/punch plan      # 当日（--date=YYYY-MM-DD）の打刻計画・休暇判定を表示
bundle exec bin/punch status    # 打刻状況を表示（--date=YYYY-MM-DD）
bundle exec bin/punch recheck   # 稼働中デーモンに当日計画の再チェックを要求（SIGUSR1）
```

- 休暇の入れ方: カレンダーに「休暇」等のキーワードを含む「終日 or 4時間以上」のイベントを入れるだけ。`schedule.exclude_dates` は補助として使えます。
- 誤って休暇イベントを入れて打刻が止まったら: カレンダーを修正 → `punch recheck`。打刻済みの分は AKASHI 側で手動削除してください。

## 仕組み

- 対象日判定: 平日のみ・日本の祝日はスキップ（`holiday_jp`）。除外日/追加出勤日は設定で調整。
- 休暇検知: タイトルが `calendar.leave_keywords`（既定: 休暇/有給/年休/全休/休み）に部分一致し「終日または `leave_min_duration_hours`（既定4時間）以上」のイベントがあれば、その日は打刻しない。
- 出勤 = 所定時刻（`work.clock_in`）＋揺らぎ（ウィンドウ分以内の乱数。日毎に1回決めて固定）。
- 退勤 = max(所定時刻, 最終業務イベントの終了時刻)＋揺らぎ。会食・懇親会など `calendar.exclude_keywords` に一致する末尾イベントは飛ばして判定。
- カレンダーを一定間隔（`refresh_interval_minutes`・既定15分）で再取得して会議の延長に追随し、退勤の打刻直前にも最終チェックする。
- 目標時刻から `late_grace_minutes`（既定10分）を超えて遅延したら打刻せずスキップ（スリープ寝過ごしでの誤時刻打刻ガード）。
- pmset の起床予約を自動管理: 当日の残り打刻分と翌営業日朝のぶんを予約し直す（sudoers 設定時。`manage_wake: false` で無効化可）。
- sukesan 停止・エラー時は所定退勤時刻へフォールバックし、復旧すれば次回再取得で追随。
- 打刻前に当日の同種打刻を確認し、あればスキップ（手動打刻との二重登録防止）。

## 手動・デバッグ用コマンド

```bash
bundle exec bin/punch clock_in              # 出勤(type=11)を打刻。clock_out は退勤(type=12)
bundle exec bin/punch clock_in --dry-run    # 送信せず動作予定のみ表示
bundle exec bin/punch clock_in --force      # 対象日判定・重複チェックを無視して即時打刻
bundle exec bin/punch clock_out --window 5  # 0〜5分のランダム待機後に打刻
```

デーモンを使わないレガシーな cron 運用向けには `punch crontab`（cron 行）と `punch schedule_wakes`（pmset 起床予約）が設定例を出力します。

## トークン

- 有効期限は「1ヶ月と1日」。期限が近づく（既定7日以内）と自動で再発行し `config/token.json` を更新します。
- 長期間実行しないと失効し、自動再発行もできなくなります。その場合はマイページで再発行 → `.env` を更新 → `config/token.json` を削除 → `bundle exec bin/punch refresh_token`。

## テスト

```bash
bundle exec rspec
```

`scripts/verify_stamped_at.rb` … 打刻API の `stampedAt` 挙動（受信時刻で記録）を実機で再確認する検証スクリプト。
