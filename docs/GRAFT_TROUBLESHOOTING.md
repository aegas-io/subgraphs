# Graft Troubleshooting

## "Unexpected null for non-null column" on graft init

### Symptom

Deploying a grafted subgraph fails immediately with:

```
ERRO Failed to start subgraph, code: SubgraphStartFailure,
error: store error: Unexpected null for non-null column,
component: SubgraphInstanceManager
```

The error fires within ~10ms of `Obtaining copy lock`, before any blocks/data are copied. `subgraphs.copy_state` stays empty. Same error every retry.

### Root cause

In `graph-node` (v0.38.0) `store/postgres/src/catalog.rs`, `histogram_bounds()` reads `pg_stats.histogram_bounds` into a struct `Bounds { bounds: Vec<i64> }` (non-nullable). `.optional()` only handles missing rows, not NULL columns.

PostgreSQL leaves `pg_stats.histogram_bounds` NULL when a table has too few rows / distinct values to build a histogram (typically tables with 1-2 rows). Any such entity table in the **source** subgraph aborts graft init.

`VidBatcher::load()` (called from `TableState::init()` in `copy.rs`) invokes `histogram_bounds()` for the `vid` column of every source table that needs copying — that's where the NULL is hit.

### Recipe to fix and retry

Assuming the source subgraph schema is `sgd<S>` (e.g. `sgd8`) and the destination is `sgd<D>` (e.g. `sgd15`). All commands assume the local docker stack with `postgres-perps` and `graph-node-perps`.

#### 1. Identify source tables missing histogram stats

```bash
docker exec postgres-perps psql -U graph-node -d graph-node -c \
  "SELECT tablename FROM pg_stats
   WHERE schemaname='sgd<S>' AND attname='vid' AND histogram_bounds IS NULL
   ORDER BY tablename;"
```

Also check for tables that have **no `pg_stats` row at all** (never analyzed):

```bash
docker exec postgres-perps psql -U graph-node -d graph-node -c \
  "SELECT c.relname FROM pg_class c
   JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'sgd<S>' AND c.relkind = 'r'
     AND NOT EXISTS (
       SELECT 1 FROM pg_stats s
       WHERE s.schemaname = n.nspname AND s.tablename = c.relname AND s.attname='vid'
     );"
```

#### 2. Inspect each affected table's schema

```bash
docker exec postgres-perps psql -U graph-node -d graph-node -c "\d sgd<S>.<table>"
```

Note every `NOT NULL` column. Entity tables always have at minimum: `vid` (auto), `block_range int4range`, `id text`, plus entity-specific NOT NULL columns.

#### 3. Insert 2 dummy rows per affected table

**Why 2 rows**: PostgreSQL needs `ndistinct − num_mcv ≥ 2` to compute `histogram_bounds`. New vids come from sequences so they're automatically distinct.

**Why `block_range = [2147483640, 2147483641)`**: graph-node's copy filter is `WHERE lower(block_range) <= target_block.number`. With `lower = 2147483640` (≈ `i32::MAX`), dummy rows are guaranteed to be excluded from any realistic graft window — they never copy into the destination.

**Why distinct `id` values (`_dummy_a`, `_dummy_b`)**: every entity table has a GIST exclusion constraint `(id, block_range)` forbidding overlapping ranges for the same id. Different ids sidestep this.

**Use `-i` flag on `docker exec`** — without it, psql heredoc input is silently discarded:

```bash
docker exec -i postgres-perps psql -U graph-node -d graph-node <<'SQL'
INSERT INTO sgd<S>.<table> (block_range, id, <other_not_null_cols>) VALUES
  ('[2147483640,2147483641)', '_dummy_a', <minimal_values>),
  ('[2147483640,2147483641)', '_dummy_b', <minimal_values>);
SQL
```

Minimal placeholder values per type: `'\x00'` for `bytea`, `0` for `numeric`, `'x'` for `text`.

Example (real one used on coti `sgd8`):

```bash
docker exec -i postgres-perps psql -U graph-node -d graph-node <<'SQL'
INSERT INTO sgd8.affiliate_fee_collector (block_range, id, fee_collector) VALUES
  ('[2147483640,2147483641)', '_dummy_a', '\x00'),
  ('[2147483640,2147483641)', '_dummy_b', '\x00');
INSERT INTO sgd8.configuration (block_range, id, collateral, update_timestamp, update_transaction) VALUES
  ('[2147483640,2147483641)', '_dummy_a', '\x00', 0, '\x00'),
  ('[2147483640,2147483641)', '_dummy_b', '\x00', 0, '\x00');
INSERT INTO sgd8.fee_collector_share (block_range, id) VALUES
  ('[2147483640,2147483641)', '_dummy_a'),
  ('[2147483640,2147483641)', '_dummy_b');
INSERT INTO sgd8.sync_meta (block_range, id, global_version, versions_hash, deployed_at) VALUES
  ('[2147483640,2147483641)', '_dummy_a', 'x', 'x', 0),
  ('[2147483640,2147483641)', '_dummy_b', 'x', 'x', 0);
SQL
```

#### 4. ANALYZE each table

`VACUUM ANALYZE` inside `psql -c` errors with `VACUUM cannot run inside a transaction block`. Use plain `ANALYZE` (or run each `VACUUM ANALYZE` in its own `docker exec ... psql -c` call):

```bash
docker exec postgres-perps psql -U graph-node -d graph-node -c "ANALYZE sgd<S>.<table>;"
```

#### 5. Verify stats are populated

```bash
docker exec postgres-perps psql -U graph-node -d graph-node -c \
  "SELECT tablename, histogram_bounds IS NULL AS hb_null,
          array_length(histogram_bounds::text::int8[], 1) AS hb_len
   FROM pg_stats
   WHERE schemaname='sgd<S>' AND attname='vid'
     AND tablename IN ('<table1>','<table2>',...);"
```

Expect `hb_null = f` and `hb_len ≥ 2` for every previously-affected table.

#### 6. Trigger graft re-init

A failed deployment **won't auto-retry** when you redeploy the same IPFS hash — the assignment stays put. The reliable trigger is to restart graph-node:

```bash
docker restart graph-node-perps
```

Within seconds you should see in the logs:

```
INFO Initializing graft by copying data from sgd<S> to sgd<D>
INFO Obtaining copy lock ...
INFO Initialize data copy from <src_hash>[sgd<S>] to <dst_hash>[sgd<D>]
INFO Starting to copy `<Entity>` entities from "sgd<S>"."..." to "sgd<D>"."..."
... (one line per entity table) ...
INFO Finished copying data into <dst_hash>[sgd<D>]
INFO Copied 0 existing errors
INFO Scanning blocks [<graft_block+1>, ...]
```

#### 7. (Optional) Cleanup

The dummy rows are inert — they sit at block ~2.1B which no real chain reaches, and the live indexer allocates new vids via sequence so it never collides with them. You can leave them, or after the new subgraph stabilizes:

```sql
DELETE FROM sgd<S>.<table> WHERE id LIKE '_dummy%';
```

Don't `ANALYZE` again after deletion while another graft is still pending — that would re-expose the bug.

### Why not just patch graph-node

The real fix is upstream: change `Bounds.bounds` to `Option<Vec<i64>>` in `catalog::histogram_bounds()` and treat NULL as empty bounds. Requires building/running a fork. The workaround above lets you graft on stock v0.38.0.

### Useful commands during diagnosis

Find which `sgdN` schema a deployment hash maps to:

```bash
docker exec postgres-perps psql -U graph-node -d graph-node -c \
  "SELECT id, subgraph, name, network FROM public.deployment_schemas
   WHERE subgraph='Qm...';"
```

Inspect deployment metadata (latest block, graft target, health):

```bash
docker exec postgres-perps psql -U graph-node -d graph-node -c \
  "SELECT id, deployment, latest_ethereum_block_number,
          graft_base, graft_block_number, earliest_block_number,
          entity_count, health, failed
   FROM subgraphs.subgraph_deployment WHERE id IN (<S>,<D>);"
```

Check what graft init attempts have happened:

```bash
docker exec postgres-perps psql -U graph-node -d graph-node -c \
  "SELECT src, dst, queued_at, cancelled_at FROM public.active_copies ORDER BY queued_at;"
```

Confirm whether the copy ever progressed past init (a non-empty row means it got past the histogram_bounds call):

```bash
docker exec postgres-perps psql -U graph-node -d graph-node -c \
  "SELECT * FROM subgraphs.copy_state;"
```