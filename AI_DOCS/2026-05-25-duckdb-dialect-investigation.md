# DuckDB dialect — investigation (branch `duckdb`)

Status: **IMPLEMENTED** (branch `duckdb`). `lib/DBIx/QuickORM/Dialect/DuckDB.pm`
added, registered in `_dialect_for_driver`, covered by
`t/AI/dialect_duckdb.t` (provisions DuckDB via DBIx::QuickDB 0.000042's DuckDB
driver). Savepoints croak (nested txns unsupported). See "Implementation
notes" at the bottom.

The original investigation follows.

## Verdict

Adding a DuckDB flavor is straightforward. DuckDB is an embedded engine (file
or `:memory:`, no server) — architecturally closest to the SQLite dialect, so
`Dialect::DuckDB` can mirror `Dialect::SQLite` for most methods.

## Environment (as probed 2026-05-25)

- `DBD::DuckDB` 0.16 installed; `libduckdb.so` + `duckdb` CLI present.
- DuckDB engine **v1.3.0** (`SELECT version()`).
- Connect string: `dbi:DuckDB:dbname=:memory:` works (also a file path).
- **No** `DBIx::QuickDB::Driver::DuckDB` (QuickDB has SQLite/PostgreSQL/MySQL/
  MariaDB/Percona/MySQLCom only).

## Capabilities (empirically probed via DBD::DuckDB)

| Feature | Result |
|---|---|
| `RETURNING` on insert/update/delete | all supported |
| `INSERT … ON CONFLICT(pk) DO UPDATE SET … ` (upsert) | supported; base `upsert_statement` works unchanged |
| `$dbh->begin_work` / `commit` / `rollback` | supported (rollback verified) |
| `pragma_table_info(?)` | supported, **SQLite-compatible** columns (name, type, notnull, pk, cid) |
| `duckdb_constraints()` | supported — gives PRIMARY KEY, UNIQUE, and FOREIGN KEY rows with `constraint_column_names`, `referenced_table`, `referenced_column_names` (arrays) |
| `duckdb_indexes()` | supported (index_name, is_unique, sql) |
| `information_schema.tables` + `table_type` | supported; `BASE TABLE` vs `VIEW`, filter `table_schema = current_schema()` (='main') |
| datetime/date rendering | ISO `YYYY-MM-DD HH:MM:SS` / `YYYY-MM-DD` (reuse `DateTime::Format::SQLite`) |
| `BLOB` type | supported; `affinity_from_type('blob')` already → binary |
| `quote_identifier` | works |

## Gaps / risks

1. **No SAVEPOINT** — `SAVEPOINT`/`RELEASE`/`ROLLBACK TO` are parser errors,
   and a nested `BEGIN` errors ("cannot start a transaction within a
   transaction"). QuickORM's nested `txn` goes through
   `Connection.pm` `create_savepoint` (around line 518), so on DuckDB nested
   txns would croak. Top-level txns work fine. **This is the open decision:**
   croak (honest, mirrors async-on-SQLite) vs no-op emulate (wrong "rollback
   to savepoint" semantics).
2. **No `last_insert_id`** — moot. With `supports_returning_insert => 1` and a
   PK, Handle.pm (~1832-1853) uses the RETURNING path and never calls
   `last_insert_id`. Verified.
3. **No QuickDB driver** — can't fold DuckDB into the `do_for_all_dbs` matrix
   without writing `DBIx::QuickDB::Driver::DuckDB` (separate dist). Embedded, so
   the integration test should connect directly via DBI to a temp file, like
   the SQLite-backed `t/AI/*` tests.
4. **No `pragma_foreign_key_list` / `pragma_index_list`** — use
   `duckdb_constraints()` / `duckdb_indexes()` instead.
5. `:memory:` disconnect emits a harmless "failed to save checkpoint" warning —
   tests should use a temp file, not `:memory:`.

## Implementation plan (when greenlit)

- **New** `lib/DBIx/QuickORM/Dialect/DuckDB.pm`, `parent DBIx::QuickORM::Dialect`:
  - `dbi_driver => 'DBD::DuckDB'`; `db_version` via `SELECT version()`.
  - `datetime_formatter => 'DateTime::Format::SQLite'` (verify it parses
    DuckDB's ISO output).
  - `supports_returning_{insert,update,delete} => 1`.
  - `async_supported`/`async_cancel_supported => 0`; `async_*` croak (copy
    SQLite). `version_search => 0`; `fallback/oldest/latest_ver => 1`.
  - `dsn` → `dbi:DuckDB:dbname=<db_name>` (file or `:memory:`), copy SQLite shape.
  - `start_txn`/`commit_txn`/`rollback_txn` → `begin_work`/`commit`/`rollback`.
  - `create_savepoint`/`commit_savepoint`/`rollback_savepoint` → per the
    pending decision.
  - Introspection:
    - `build_tables_from_db` → `information_schema.tables` (current_schema),
      split BASE TABLE / VIEW.
    - `build_columns_from_db` → `pragma_table_info(?)` (reuse SQLite logic).
    - `build_table_keys_from_db` → `duckdb_constraints()` for PK/unique/FK.
    - `build_indexes_from_db` → `duckdb_indexes()` (+ synthesise the PK index
      like SQLite does).
- **Edit** `lib/DBIx/QuickORM.pm`: `_dialect_for_driver` add
  `return 'DuckDB' if $driver =~ m/^DuckDB$/i;`; add DuckDB to the dialect POD
  list.
- **New** `t/AI/dialect_duckdb.t`: `skip_all unless eval { require DBD::DuckDB }`,
  connect to a temp-file DSN, round-trip insert/RETURNING/update/upsert and
  assert introspection (columns, PK, unique, FK link, view).
- **dist.ini**: add `DBD::DuckDB` to `[Prereqs / RuntimeSuggests]`; add to the
  `t/00-report.t` module list.

## Effort

One ~200-line dialect (mostly introspection SQL), small edits to
`DBIx/QuickORM.pm` + `dist.ini`, one direct-DBI test file. Moderate.

## Implementation notes (what actually shipped on this branch)

- **Transactions use raw SQL, not `begin_work`.** DBD::DuckDB 0.16 has a bug:
  `begin_work`/`commit` works repeatedly, but after a `$dbh->rollback` the next
  `begin_work` dies with "cannot start a transaction within a transaction" —
  DBI's `rollback` doesn't clear DuckDB's engine transaction state. Manual
  `BEGIN TRANSACTION` / `COMMIT` / `ROLLBACK` via `$dbh->do` is reliable across
  sequential commits and rollbacks. So `start_txn`/`commit_txn`/`rollback_txn`
  issue those statements and the dialect tracks its own `in_txn` flag (DBI's
  `AutoCommit` stays at its default and does not reflect the manual txn).
- **Savepoints croak** ("does not support savepoints"). Nested ORM `txn`s go
  through `create_savepoint` and therefore croak; top-level txns work.
- **Introspection:** columns via `pragma_table_info`; PK/unique/FK via
  `duckdb_constraints()` (DBD::DuckDB returns LIST columns as Perl arrayrefs);
  tables/views via `information_schema.tables` + `table_type`. `build_indexes`
  reports PK + unique only (DuckDB has no stable secondary-index-column fn).
- **DuckDB is NOT in the `do_for_all_dbs` matrix.** It rejects `SERIAL` and has
  no implicit auto-increment, so the shared `postgresql.sql`/`sqlite.sql`
  schemas do not load; and savepoint-based nested-txn tests don't apply.
  Folding DuckDB into that matrix is a separate task: author per-test
  `duckdb.sql` schemas (use `CREATE SEQUENCE` + `DEFAULT nextval(...)` for PKs)
  and make the transaction tests savepoint-aware. Until then DuckDB is covered
  by the dedicated `t/AI/dialect_duckdb.t`.
- **`last_insert_id`** is unsupported by DBD::DuckDB but unused — insert goes
  through the RETURNING path.
