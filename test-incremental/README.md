# Bug report: ClickHouse delete-and-replace strategies drop rows when an interval is rerun

## Summary

Bruin's ClickHouse `time_interval` materialization loses data when it refreshes
the same interval a second time. The same failure is also present in the
ClickHouse `delete+insert` strategy. Both paths delete existing rows and then
attempt to insert the same data block again.

The first run correctly loads the new row. The second run succeeds according to
Bruin, but its `DELETE` removes the existing interval row and ClickHouse
deduplicates the identical replacement `INSERT`. The target is left without the
row.

**Status:** confirmed for `time_interval` and `delete+insert`; a separate
timestamp-granularity defect is also confirmed below.

**Related issue:** [bruin-data/bruin#2396](https://github.com/bruin-data/bruin/issues/2396)
tracks the original `time_interval` reproduction.

## Environment

| Item | Value |
| --- | --- |
| Bruin CLI | `v0.11.682` |
| Environment | `default` |
| Connection | `clickhouse-default` |
| Pipeline | `test-incremental` |
| Target table engine | `SharedMergeTree` |
| Incremental strategy | `time_interval`, `event_date`, `date` granularity |

## Expected and actual behavior

After resetting the source and target to rows `row_1` through `row_5`, the test
inserts the genuinely new source row below:

```text
event_date: 2026-07-16
row_id:     row_7
amount:     77
```

| Step | Expected July 16 target result | Actual July 16 target result |
| --- | --- | --- |
| First incremental run | `row_7` | `row_7` |
| Second run with the identical interval and source | `row_7` | no rows |

After the failure, `bug_test_seed` still contains `row_7`, while
`bug_test_incremental` contains only the baseline July 11–15 rows.

## Why a newly inserted primary key is still affected

`row_7` is not a duplicate primary key when it is first added to
`bug_test_seed`. The problem is not primary-key deduplication. It is ClickHouse
deduplicating the **data block** produced by the second `INSERT ... SELECT`
against the block produced by the first run.

| Step | Target table | ClickHouse insert-deduplication history |
| --- | --- | --- |
| Before the first run | no `row_7` | no block for `row_7` |
| First run INSERT | adds `row_7` | records the inserted block |
| Second run DELETE | removes `row_7` | retains the block record |
| Second run INSERT | skips the identical block | still retains the block record |

The first run therefore works: its block has never been inserted before. The
second run produces the same block, so ClickHouse treats it as a retry and
skips it. The preceding DELETE has removed the target row, but it does not
clear ClickHouse's insert-deduplication history. The target is consequently
left empty for that interval.

The earlier two-row observation and the single-new-row reproduction are the
same bug. The earlier block contained `row_7` and `row_8`; the minimal
reproduction block contains only `row_7`. In both cases, the second run emits
the same block as the first run and is deduplicated.

## Minimal terminal reproduction

These commands reset **only** `bug_test_seed` and `bug_test_incremental` in the
test pipeline. Run them from the workspace root. The current `bruin query`
INSERT client reports `EOF` after ClickHouse accepts the write; the immediate
SELECT is therefore required before continuing.

```bash
cd /Users/bear/conductor/workspaces/bruin-clickhouse/seattle

bruin validate test-incremental

# Reset seed and target to rows row_1 through row_5.
bruin run \
  --full-refresh \
  --start-date 2026-07-11T00:00:00.000Z \
  --end-date 2026-07-15T23:59:59.999999999Z \
  --environment default \
  test-incremental

# Check the final table
bruin query \
  --connection clickhouse-default \
  --query "SELECT * FROM bug_test_incremental;"


# Add a source row whose primary key is new in both tables.
# This currently prints EOF despite successfully inserting the row.
bruin query \
  --connection clickhouse-default \
  --query "INSERT INTO bug_test_seed (event_date, row_id, amount) VALUES (toDate('2026-07-16'), 'row_7', 77);"

# Check the seed table to see the newly inserted row
bruin query \
  --connection clickhouse-default \
  --query "SELECT * FROM bug_test_seed;"

# First July 16 refresh: row_7 appears in the target.
bruin run \
  --start-date 2026-07-16T00:00:00.000Z \
  --end-date 2026-07-16T23:59:59.999999999Z \
  --push-metadata \
  --apply-interval-modifiers \
  --environment default \
  test-incremental/assets/bug_test_incremental.sql

# Check the final table to see the new row loaded
bruin query \
  --connection clickhouse-default \
  --query "SELECT * FROM bug_test_incremental;"

# Second, identical July 16 refresh: row_7 disappears from the target.
bruin run \
  --start-date 2026-07-16T00:00:00.000Z \
  --end-date 2026-07-16T23:59:59.999999999Z \
  --push-metadata \
  --apply-interval-modifiers \
  --environment default \
  test-incremental/assets/bug_test_incremental.sql

bruin query \
  --connection clickhouse-default \
  --query "SELECT 'seed' AS table_name, event_date, row_id, amount FROM bug_test_seed WHERE row_id = 'row_7' UNION ALL SELECT 'target' AS table_name, event_date, row_id, amount FROM bug_test_incremental WHERE row_id = 'row_7' ORDER BY table_name;"
```

## SQL comparison

The asset query correctly restricts input to the requested interval:

```sql
SELECT
    event_date,
    row_id,
    amount
FROM bug_test_seed
WHERE event_date BETWEEN toDate('{{ start_date }}') AND toDate('{{ end_date }}')
```

For July 16, Bruin renders and ClickHouse executes these two statements, in
order:

```sql
DELETE FROM bug_test_incremental
WHERE event_date BETWEEN '2026-07-16' AND '2026-07-16';

INSERT INTO bug_test_incremental
SELECT
    event_date,
    row_id,
    amount
FROM bug_test_seed
WHERE event_date BETWEEN toDate('2026-07-16') AND toDate('2026-07-16');
```

Render them locally with:

```bash
bruin render \
  --start-date 2026-07-16T00:00:00.000Z \
  --end-date 2026-07-16T23:59:59.999999999Z \
  --apply-interval-modifiers \
  test-incremental/assets/bug_test_incremental.sql

bruin render \
  --raw-query \
  --start-date 2026-07-16T00:00:00.000Z \
  --end-date 2026-07-16T23:59:59.999999999Z \
  --apply-interval-modifiers \
  test-incremental/assets/bug_test_incremental.sql
```

`system.query_log` confirms that those exact DELETE and INSERT statements both
finish without a query-level exception:

```bash
bruin query \
  --connection clickhouse-default \
  --query "SELECT event_time, type, query_kind, query_id, read_rows, written_rows, exception_code, exception, query FROM system.query_log WHERE event_time >= now() - INTERVAL 10 MINUTE AND type = 'QueryFinish' AND positionCaseInsensitive(query, 'bug_test_incremental') > 0 AND query_kind IN ('Delete', 'Insert') ORDER BY event_time, query_id;"
```

## Root cause evidence

`system.part_log` is the decisive evidence, because `system.query_log` still
reports one written row for the deduplicated second INSERT.

```bash
bruin query \
  --connection clickhouse-default \
  --query "SELECT event_time_microseconds, event_type, query_id, part_name, rows, deduplication_block_ids, mutation_ids, error, exception FROM system.part_log WHERE database = currentDatabase() AND table = 'bug_test_incremental' AND event_time >= now() - INTERVAL 10 MINUTE ORDER BY event_time_microseconds;"
```

Captured results for the minimal reproduction:

| Event | Result |
| --- | --- |
| First INSERT | Created one-row part `all_2_2_0`; no error |
| Second DELETE | Mutation `0000000001` marked `all_2_2_0` deleted |
| Second INSERT | Attempted part `all_3_3_0`; error `389`, `The part was deduplicated` |

The first and second insert attempts have the same ClickHouse deduplication
block IDs. ClickHouse therefore accepts the second INSERT at the query level
but does not create a replacement part.

This is expected ClickHouse behavior for repeated data blocks on MergeTree
tables, but it is incompatible with Bruin's delete-and-replace implementations
of `time_interval` and `delete+insert`. ClickHouse deduplication is based on
data blocks, not the target table primary key. See [Deduplicating inserts on retries](https://clickhouse.com/docs/guides/developer/deduplicating-inserts-on-retries)
and [the lightweight DELETE documentation](https://clickhouse.com/docs/sql-reference/statements/delete).

## Bruin implementation and requested fix

`/Users/bear/Github/bruin/pkg/clickhouse/materialization.go` renders ClickHouse
`time_interval` as a lightweight DELETE followed by `INSERT INTO <target>
<asset query>`. `delete+insert` creates a temporary table, deletes target rows
for its incremental key, then runs `INSERT INTO <target> SELECT * FROM
<temporary table>`. Neither replacement INSERT sets an insert-deduplication
option or token.

For both ClickHouse delete-and-replace strategies, the generated replacement
INSERT must not be deduplicated against the prior successful refresh of the
same data. Evaluate generating the statement with:

```sql
INSERT INTO target SETTINGS insert_deduplicate = 0 SELECT ...
```

An equivalent per-refresh token is also possible, provided retry semantics are
defined and tested.

Please add `SharedMergeTree` regression tests that:

1. starts with a source containing one new primary-key row for one date;
2. refreshes that exact interval twice through `time_interval` and through
   `delete+insert`; and
3. asserts the target row remains after both runs in each case.

## Follow-up: other ClickHouse strategy tests

The following isolated assets use the same `bug_test_seed` source, but write to
separate target tables. This prevents one strategy's target state from affecting
another's result.

| Asset | Materialization | Test result |
| --- | --- | --- |
| `strategy_append.sql` | `append` | Exact rerun is block-deduplicated; a rerun after new source data duplicates previously appended rows. |
| `strategy_delete_insert.sql` | `delete+insert` | Confirmed data loss on exact rerun; this is the same defect as `time_interval`. |
| `strategy_truncate_insert.sql` | `truncate+insert` | Passed the tested exact-rerun and changed-source cases. It replaces the **entire** table, not one interval. |
| `strategy_time_interval_timestamp.sql` | `time_interval`, `timestamp` | Fails before inserting because the generated DELETE compares `DateTime` to an ISO `T` timestamp string. |
| `strategy_merge_unsupported.sql` | `merge` | Explicitly unsupported for `clickhouse.sql` at runtime. |

### Reproducible comparative test

Run from the workspace root. This resets only the named test tables in this
pipeline. The known `bruin query` INSERT `EOF` behaviour applies: each INSERT
below is accepted by ClickHouse despite the CLI error, so verify the source
rows before running an asset.

```bash
cd /Users/bear/conductor/workspaces/bruin-clickhouse/seattle

bruin validate test-incremental

# Reset the source and every strategy target to rows row_1 through row_5.
bruin run \
  --full-refresh \
  --start-date 2026-07-11T00:00:00.000Z \
  --end-date 2026-07-15T23:59:59.999999999Z \
  --environment default \
  test-incremental

# Seed one row for each first-run scenario. The command currently prints EOF
# after ClickHouse has performed the insert.
bruin query \
  --connection clickhouse-default \
  --query "INSERT INTO bug_test_seed (event_date, row_id, amount) VALUES (toDate('2026-07-20'), 'append_a', 201), (toDate('2026-07-21'), 'delete_insert_a', 211), (toDate('2026-07-22'), 'truncate_insert_a', 221), (toDate('2026-07-23'), 'timestamp_a', 231);"

bruin query \
  --connection clickhouse-default \
  --query "SELECT event_date, row_id, amount FROM bug_test_seed WHERE row_id IN ('append_a', 'delete_insert_a', 'truncate_insert_a', 'timestamp_a') ORDER BY event_date;"
```

Run each asset once, then rerun the exact same command for `append`,
`delete+insert`, and `truncate+insert`:

```bash
bruin run --start-date 2026-07-20T00:00:00.000Z --end-date 2026-07-20T23:59:59.999999999Z --apply-interval-modifiers --environment default test-incremental/assets/strategy_append.sql

bruin run --start-date 2026-07-21T00:00:00.000Z --end-date 2026-07-21T23:59:59.999999999Z --apply-interval-modifiers --environment default test-incremental/assets/strategy_delete_insert.sql

bruin run --start-date 2026-07-22T00:00:00.000Z --end-date 2026-07-22T23:59:59.999999999Z --apply-interval-modifiers --environment default test-incremental/assets/strategy_truncate_insert.sql

# Expected runtime support-boundary error, not a data test.
bruin run --start-date 2026-07-24T00:00:00.000Z --end-date 2026-07-24T23:59:59.999999999Z --apply-interval-modifiers --environment default test-incremental/assets/strategy_merge_unsupported.sql
```

The timestamp-granularity variant fails on its **first** incremental attempt:

```bash
bruin run \
  --start-date 2026-07-23T00:00:00.000Z \
  --end-date 2026-07-23T23:59:59.999999999Z \
  --apply-interval-modifiers \
  --environment default \
  --verbose \
  test-incremental/assets/strategy_time_interval_timestamp.sql
```

Then test changed-source behaviour for the applicable strategies:

```bash
# Again, verify this write with SELECT because the CLI reports EOF.
bruin query \
  --connection clickhouse-default \
  --query "INSERT INTO bug_test_seed (event_date, row_id, amount) VALUES (toDate('2026-07-20'), 'append_b', 202), (toDate('2026-07-21'), 'delete_insert_b', 212), (toDate('2026-07-22'), 'truncate_insert_b', 222);"

# Rerun the same three commands for dates July 20, 21, and 22 above.

bruin query \
  --connection clickhouse-default \
  --query "SELECT row_id, count() AS copies FROM strategy_append WHERE event_date = toDate('2026-07-20') GROUP BY row_id ORDER BY row_id;"

bruin query \
  --connection clickhouse-default \
  --query "SELECT 'delete_insert' AS strategy, row_id, count() AS copies FROM strategy_delete_insert WHERE event_date = toDate('2026-07-21') GROUP BY row_id UNION ALL SELECT 'truncate_insert' AS strategy, row_id, count() AS copies FROM strategy_truncate_insert WHERE event_date = toDate('2026-07-22') GROUP BY row_id ORDER BY strategy, row_id;"
```

### Captured results

| Strategy and scenario | Observed target result | Assessment |
| --- | --- | --- |
| `append`, first run | `append_a` once | Passed as an append. |
| `append`, exact rerun | `append_a` remains once | ClickHouse deduplicated the identical insert block; this is not a general idempotency guarantee. |
| `append`, then add `append_b` and rerun | `append_a` twice; `append_b` once | Expected consequence of appending the whole reprocessed interval. Do not use `append` for interval replacement. |
| `delete+insert`, first run | `delete_insert_a` once | Passed. |
| `delete+insert`, exact rerun | no July 21 rows | **Defect:** target rows are deleted and identical replacement block is deduplicated. |
| `delete+insert`, then add `delete_insert_b` and rerun | `delete_insert_a` and `delete_insert_b` once each | Changed block is accepted, so the target recovers. This confirms the failure is block-content dependent. |
| `truncate+insert`, exact rerun | `truncate_insert_a` once | Passed in this environment. |
| `truncate+insert`, then add `truncate_insert_b` and rerun | both rows once | Passed in this environment. Its destructive whole-table semantics remain intentional. |
| `time_interval`, timestamp granularity, first incremental run | no July 23 row; run fails | **Separate defect:** generated timestamp literal is not accepted by ClickHouse `DateTime`. |
| `merge`, first incremental run | no run | Expected unsupported-strategy error. |

### ClickHouse evidence

The exact append rerun and exact `delete+insert` rerun both produced an
attempted `NewPart` with error `389`, `The part was deduplicated`. The crucial
difference is that `delete+insert` has first executed lightweight DELETE
mutations, while append has not. Therefore append leaves its already-present
row visible, whereas `delete+insert` leaves an empty interval.

The exact `truncate+insert` rerun also used the same deduplication block IDs,
but ClickHouse created a new part with error `0` after the truncate. This is an
observation from this `SharedMergeTree` test, not a claim that the strategy is
safe for interval replacement.

Inspect the part-level result after reproducing with:

```bash
bruin query \
  --connection clickhouse-default \
  --query "SELECT database, table, event_type, part_name, rows, error, exception, deduplication_block_ids, mutation_ids FROM system.part_log WHERE table LIKE 'strategy_%' AND event_time >= now() - INTERVAL 30 MINUTE ORDER BY event_time_microseconds;"
```

For timestamp granularity, Bruin renders this DELETE before any INSERT:

```sql
DELETE FROM strategy_time_interval_timestamp
WHERE event_timestamp BETWEEN '2026-07-23T00:00:00.000000'
  AND '2026-07-23T23:59:59.999999';
```

ClickHouse returns code `53`:

```text
Cannot convert string '2026-07-23T00:00:00.000000' to type DateTime
```

`merge` reaches the ClickHouse materializer but fails before executing SQL:

```text
materialization strategy merge is not supported for materialization type table and asset type clickhouse.sql
```

### Additional requested fixes and tests

1. Apply the replacement-insert deduplication fix to both `time_interval` and
   `delete+insert` for ClickHouse, and cover each with a same-input rerun test.
2. Render ClickHouse `time_interval` timestamp bounds in a `DateTime`-accepted
   form (for example, use a space instead of `T`, or an explicit `toDateTime` /
   `toDateTime64` conversion), then add a first incremental-run test.
3. Document `merge` as unsupported for ClickHouse where strategy support is
   presented, or implement it separately.
