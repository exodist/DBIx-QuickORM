# Batch schema introspection (branch `batch-introspection`)

Status: **IMPLEMENTED** (branch `batch-introspection`).

## Task

Schema introspection issued **one query per table** for columns, indexes, and
keys — plus extra per-table helper queries (SQLite ran ~9 queries/table). For a
database of N tables that is O(N) round trips. The task: sweep each metadata
kind for the whole database in a **single query**, building the same internal
representation, for every dialect (SQLite, DuckDB, PostgreSQL, MySQL).

## Approach

The per-table builder methods (`build_columns_from_db`,
`build_indexes_from_db`, `build_table_keys_from_db`) were kept, but their data
**source** changed. Each `build_tables_from_db` now:

1. Slurps the table list (one query, fully fetched before anything else so no
   statement handle is left active across the batch queries).
2. Runs one **sweep** per metadata kind, grouping rows by table in Perl.
3. Loops the tables, passing each table's pre-fetched rows into the builders via
   new params (`column_rows`, `index_rows`, `key_rows`, etc.).

The builder bodies are otherwise unchanged, so hook firing order/parity and the
resulting schema objects are identical. Each builder keeps a single-table
fallback (`_query_*`) that runs its original per-table query when called without
pre-fetched rows, preserving the documented standalone contract.

Result: query count is now **O(1) in table count** (constant per database).
Verified byte-identical ORM output vs `master` on two schemas (a normal one and
an adversarial one: no-PK tables, multiple unique constraints, composite /
self-referential / multi-column FKs, standalone unique indexes, views, temp
tables, generated columns, WITHOUT ROWID, AUTOINCREMENT/serial) for all four
engines. Round trips on the test schemas dropped: SQLite 48/55→10, DuckDB
31/43→5, PostgreSQL 20/23→5, MySQL 18/24→6. Full suite (1152 tests) passes.

## Per-dialect decisions

- **PostgreSQL / MySQL** (easy): drop the per-table `WHERE table_name = ?`,
  keep the schema/catalog scope, group by table in Perl. PostgreSQL prefetch is
  keyed by `(schema, table)` so the `search_path`-winning schema's rows are used
  per resolved table, matching the prior collision resolution. The keys sweeps
  gained a deterministic `ORDER BY ... conname, oid` (PostgreSQL) so multi-FK
  link order is stable (the old per-table query had none).

- **SQLite**: the `pragma_*` table-valued functions are joined **laterally**
  against `sqlite_master` / `sqlite_temp_master` so one statement iterates all
  tables (`FROM sqlite_master m JOIN pragma_table_xinfo(m.name) x`). This works
  for `pragma_table_xinfo`, the nested `pragma_index_list` +
  `pragma_index_info`, and `pragma_foreign_key_list`. Primary key and
  rowid-alias detection are derived from the pre-fetched xinfo rows
  (`_pk_from_xinfo`, `_rowid_alias_from`) instead of extra per-table queries.
  The xinfo/index/fk sweeps are keyed by `(is_temp, name)`: a temporary object
  shadows a permanent one of the same name and the unqualified pragma calls
  resolve to the temp object, so without the temp-flag dimension both catalog
  sweeps would pile rows under one key and double PK/index/FK column lists. DDL
  (`_fetch_all_ddl`) stays keyed by bare name, permanent-first, matching
  `_table_ddl`.

- **DuckDB**: DuckDB does **not** support SQLite-style lateral `pragma_*` joins
  (parser error), so columns come from `duckdb_columns()` (a whole-database
  function) mapped into the `pragma_table_info` shape the builder expects:
  `cid = column_index - 1`, `notnull = !is_nullable`, `dflt_value =
  column_default`, and `pk` filled from the primary-key columns found in the
  shared `duckdb_constraints()` sweep (duckdb_columns has no pk flag). Keys and
  indexes share that one `duckdb_constraints()` sweep; secondary indexes come
  from `duckdb_indexes()`; generated columns come from one `duckdb_tables()` DDL
  sweep parsed by `_parse_generated`. All sweeps are scoped to
  `current_schema()`, matching the table-list scope.

## Notes

- The only behavior differences from `master` are bugfix-direction: DuckDB's
  per-table queries used to merge metadata from same-named tables in *other*
  schemas (the sweeps now scope to `current_schema()`), and the SQLite
  temp-shadow doubling described above is avoided. Both are cases single-schema
  tests could not observe; they were found by adversarial review.
- Verified with throwaway golden / round-trip-count harnesses (byte-identical
  introspected schema on two schemas across all four engines; O(1) round trips
  in table count). Those harnesses are not committed to the repo.
