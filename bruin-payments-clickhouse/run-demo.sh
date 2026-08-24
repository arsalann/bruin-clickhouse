#!/usr/bin/env bash
#
# Runs the payments pipeline as if it had been on its one-minute schedule for the
# last little while, so the dashboard has something to show.
#
#   ./bruin-payments-clickhouse/run-demo.sh          # 30 minutes of traffic
#   ./bruin-payments-clickhouse/run-demo.sh 60       # an hour of it
#
# The pipeline is scheduled every minute, so a demo means replaying a sequence of
# one-minute windows in order. They have to be consecutive and in chronological
# order: restatements reference the three preceding windows, which is what
# exercises the lookback.
#
# A short block on the previous UTC day is also replayed, so both halves of
# serving_realtime_risk are populated -- the live day, and sealed history where
# the non-additive KPIs are available.

set -euo pipefail

MINUTES="${1:-30}"
HISTORY_MINUTES=10

cd "$(dirname "$0")/.."
CFG="bruin-payments-clickhouse/docker/bruin-local.yml"
PIPELINE="bruin-payments-clickhouse/pipeline.yml"

# All windows are whole UTC minutes, derived from a single anchor captured once.
# Reading the clock per window would let the sequence drift forward as the replay
# runs, skipping minutes and breaking the restatement chain, since a restatement
# references the three windows immediately before its own.
ANCHOR_EPOCH=$(python3 -c "
import datetime
t = datetime.datetime.now(datetime.timezone.utc).replace(second=0, microsecond=0)
print(int(t.timestamp()))
")

anchor_minus() {  # anchor_minus <minutes-before-anchor>
  python3 -c "
import datetime
t = datetime.datetime.fromtimestamp($ANCHOR_EPOCH, datetime.timezone.utc)
print((t - datetime.timedelta(minutes=$1)).strftime('%Y-%m-%d %H:%M'))
"
}

run_window() {  # run_window "<YYYY-MM-DD HH:MM>" [--full-refresh]
  bruin run "$PIPELINE" \
    --config-file "$CFG" \
    --apply-interval-modifiers \
    ${2:-} \
    --start-date "$1:00" \
    --end-date "$1:59.999999" \
    >/dev/null
}

# Keep the live-day block inside today, so a run just after UTC midnight does not
# quietly spill into yesterday.
minutes_since_midnight=$(python3 -c "
import datetime
t = datetime.datetime.fromtimestamp($ANCHOR_EPOCH, datetime.timezone.utc)
print(t.hour * 60 + t.minute)
")
if [ "$MINUTES" -gt "$minutes_since_midnight" ]; then
  MINUTES="$minutes_since_midnight"
  echo "Trimmed the live-day block to $MINUTES minute(s) to stay inside today (UTC)."
fi

echo "==> Bootstrapping (full refresh; creates the tables)"
# time_interval issues its delete before the table exists, so the very first run
# has to be a full refresh.
first_history=$(anchor_minus $((24 * 60 + HISTORY_MINUTES)))
run_window "$first_history" --full-refresh

echo "==> Replaying $HISTORY_MINUTES minute(s) on the previous UTC day (sealed history)"
for i in $(seq $((24 * 60 + HISTORY_MINUTES - 1)) -1 $((24 * 60))); do
  run_window "$(anchor_minus "$i")"
done

echo "==> Replaying $MINUTES minute(s) up to now (the live day)"
for i in $(seq "$MINUTES" -1 1); do
  printf '\r    minute %s/%s' "$((MINUTES - i + 1))" "$MINUTES"
  run_window "$(anchor_minus "$i")"
done
printf '\n'

echo "==> Result"
bruin query --config-file "$CFG" --connection clickhouse-default --query "
SELECT
    if(is_today = 1, 'today (live, from the minute rollup)', 'earlier (sealed, from the daily KPI table)') AS source,
    min(txn_date)                                   AS from_date,
    sum(txns)                                       AS authorizations,
    round(sum(approved) / sum(txns), 4)             AS approval_rate,
    sum(approved_volume)                            AS approved_volume_usd,
    if(max(unique_cards) IS NULL, 'not additive - null by design', 'available') AS unique_cards
FROM bruin_payments.serving_realtime_risk
GROUP BY is_today
ORDER BY is_today"

echo
echo "Next: dac serve --dir bruin-payments-clickhouse --config $CFG --open"
