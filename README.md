# ak4-punch

マネーフォワード クラウド勤怠Plus（旧AKASHI）へ出勤/退勤を自動打刻する常駐デーモン。
出勤はローカルのカレンダーAPI（sukesan）の最初の業務イベントの開始までに、退勤は最終業務イベントの終了に追随して打刻し、
休暇イベントを検知した日は打刻しません。

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

# 1) 接続情報（機密。他ユーザーが読めない権限で作成する）
install -m 600 .env.example .env
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

# 6) LaunchAgent として常駐登録（plist 設置と launchctl 登録・起動を自動実行）
bin/daemonctl install
```

> `.env` / `config/config.yml` / `config/token.json` は `.gitignore` 済みです。
> `.env` にはアクセストークン・APIキー・Webhook URL が入るため、他ユーザーが読めない権限（600）で作成してください（`config/token.json` は本ツールが 600 で作成します）。

## 日常運用

```bash
bundle exec bin/punch plan      # 当日（--date=YYYY-MM-DD）の打刻計画・休暇判定を表示
bundle exec bin/punch status    # 打刻状況を表示（--date=YYYY-MM-DD）
bundle exec bin/punch recheck   # 稼働中デーモンに当日計画の再チェックを要求（SIGUSR1）
bin/daemonctl status            # デーモンの稼働状態・ログ末尾・起床予約を表示
bin/daemonctl restart           # デーモンを再起動（start/stop/log もあり）
```

- 設定変更の反映: `.env` / `config/config.yml` を変更したら `bin/daemonctl restart`。デーモンは起動時に一度だけ設定を読むため、`punch recheck` は当日計画を作り直すだけで設定は再読込しません。
- 休暇の入れ方: カレンダーに「休暇」等のキーワードを含む「終日 or 4時間以上」のイベントを入れるだけ。`schedule.exclude_dates` は補助として使えます。
- 誤って休暇イベントを入れて打刻が止まったら: カレンダーを修正 → `punch recheck`。打刻済みの分は AKASHI 側で手動削除してください。

## 仕組み

- 対象日判定: 平日のみ・日本の祝日はスキップ（`holiday_jp`）。除外日/追加出勤日は設定で調整。
- 休暇検知: タイトルが `calendar.leave_keywords`（既定: 休暇/有給/年休/全休/休み）に部分一致し「終日または `leave_min_duration_hours`（既定4時間）以上」のイベントがあれば、その日は打刻しない。
- 出勤 = 打刻締切 − 揺らぎ（ウィンドウ分以内の乱数。日毎に1回決めて固定）。打刻締切 = min(所定時刻（`work.clock_in`）＋ウィンドウ, 最初の業務イベントの開始時刻)。移動・私用など `calendar.clock_in_exclude_keywords` に一致する先頭イベントは（連続していても）飛ばして判定する。予定がない日の打刻範囲は所定時刻〜所定時刻＋ウィンドウで、従来と変わらない。
- 退勤 = max(所定時刻, 最終業務イベントの終了時刻)＋揺らぎ。会食・懇親会など `calendar.exclude_keywords` に一致する末尾イベントは飛ばして判定。
- 揺らぎの向きは出勤と退勤で逆（出勤は締切から手前、退勤は基準から後ろ）。どちらも日付と種別から決まる固定値なので、再取得のたびに目標がぶれることはない。
- `daemon.morning_wake_at`（例 `"07:45"`）は、翌営業日にMacを起こす時刻と出勤アンカーの下限を兼ねる。この時刻より前に始まる予定は出勤の締切に採用しない（スリープ中で間に合わない時刻に打刻目標を置かない・深夜の予定を掴んで日付変更直後に打刻しないため）。早朝の予定に合わせたい場合はこの値を早める。未設定なら従来どおり翌営業日の所定出勤時刻に起床し、下限もかからない。
- カレンダーを一定間隔（`refresh_interval_minutes`・既定15分）で再取得して会議の追加・キャンセル・延長に追随する（出勤・退勤とも。打刻済みの分は作り直さない）。退勤は打刻直前にも最終チェックする。出勤は打刻直前の再取得を行わない（早すぎる出勤打刻は実害が小さく、sukesan の呼び出しを増やさないため）。
- 出勤目標の更新で新しい目標が現在時刻以前になる場合（例: 9:20 に 9:00 開始の会議が入った）は更新せず、既存の目標を維持する。過去の目標に置き換えると grace 超過と判定され、出勤が恒久的にスキップされてしまうため。
- 打刻失敗は目標+`late_grace_minutes`（既定10分）の窓内で tick 毎にリトライ。窓を超えたら諦める（寝過ごし時は打刻せずスキップ＝誤時刻打刻ガード）。
- pmset の起床予約を自動管理（add-only 方式）: 当日の残り打刻分と翌営業日朝（`daemon.morning_wake_at` と所定出勤時刻の早い方）のぶんを、毎回 `pmset -g sched` を読んで不足している起床だけ追加する（sudoers 設定時。`manage_wake: false` で無効化可）。`cancelall`/`cancel` は使わない。これらはマシン全体の一回限り起床予約を消してしまい、pmset は予約の所有者を区別できないため、同居する他の pmset 利用デーモン（capital-arena の仮想取引デーモン）の起床予約まで壊してしまうため。何も消さないので他デーモンと共存でき、逆に他デーモンの `cancelall` で自分の予約が消えても次のポーリングで再追加され自己回復する。
- sukesan の通信エラー・HTTP 5xx は一過性とみなし、2秒→4秒のバックオフで計3回まで試行して瞬断を吸収する（HTTP 4xx は設定ミス等の恒久エラーとして即失敗）。
- それでも取得できない場合は所定時刻（出勤は所定＋ウィンドウの締切、退勤は所定退勤時刻）へフォールバックし、復旧すれば次回再取得で追随。日中の再取得だけが失敗した場合は所定時刻へ巻き戻さず、直近の打刻目標をそのまま維持する。
- 打刻前に当日の在席状態（最終打刻）を確認し、既に済んでいればスキップ（手動打刻との二重登録防止）。日跨ぎ勤務で前営業日の退勤が当日日付に記録されても、当日の出勤後は退勤を正しく打刻する。

## 通知（任意）

`.env` に `SLACK_WEBHOOK_URL`（Slack Incoming Webhook）を設定すると、異常時のみ通知します
（打刻の寝過ごしスキップ / リトライ失敗 / トークン再発行失敗 / sukesan 障害フォールバック）。未設定なら無効です。
`SLACK_MENTION`（例: `<@U04XXXXXX>`）を設定すると通知の先頭にメンションを付けます（任意）。

送信に失敗した通知はメモリに保持し、以降の tick で自動再送します（スリープ明け直後で Wi-Fi 未接続でも取りこぼしません）。
未打刻のまま日付を跨いだ場合も、翌朝の最初の tick で「未打刻のまま日付が変わりました」と通知します。

日中の定期再取得の失敗は、打刻目標を直近の値のまま維持するだけで実害がないため、
連続失敗が `calendar.refresh_failure_notify_threshold`（既定3回）に達するまで通知しません（ログには毎回残ります）。
スリープ中の一時起床（DarkWake）では Wi-Fi が繋がらず sukesan が Google に到達できないことがあり、
その一過性の失敗で鳴らさないための閾値です。判定は経過時間ではなく連続失敗回数で行います
（スリープする前提では「起床直後に1回失敗」だけで長時間扱いになってしまうため）。
起動時・日付変化時の取得失敗は所定時刻フォールバック＋休暇判定不能という実害があるため、1回目から通知します。

## 手動・デバッグ用コマンド

```bash
bundle exec bin/punch clock_in              # 出勤(type=11)を打刻。clock_out は退勤(type=12)
bundle exec bin/punch clock_in --dry-run    # 送信せず動作予定のみ表示
bundle exec bin/punch clock_in --force      # 対象日判定・重複チェックを無視して即時打刻
bundle exec bin/punch clock_out --window 5  # 0〜5分のランダム待機後に打刻
```

## トークン

- 有効期限は「1ヶ月と1日」。期限が近づく（既定7日以内）と自動で再発行し `config/token.json` を更新します。
- 長期間実行しないと失効し、自動再発行もできなくなります。その場合はマイページで再発行 → `.env` を更新 → `config/token.json` を削除 → `bundle exec bin/punch refresh_token`。

## テスト

```bash
bundle exec rspec
```

`scripts/verify_stamped_at.rb` … 打刻API の `stampedAt` 挙動（受信時刻で記録）を実機で再確認する検証スクリプト。
