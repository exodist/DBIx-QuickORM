# Pre-merge TODO — `audit-fixes-master`

Items to resolve (or consciously defer) before merging this branch.

Each item is a `##` section headed by a short kebab-case slug. Add new items by
appending another `## <slug>` section — do not use `#<number>` ids, they collide
with GitHub issue references.

Item template:

```
## <slug>

**Status:** open | deferred | done

<one-paragraph summary of the gap / task>

**Possible approach:** <short sketch, not a spec>

**References:** <files, commits, or external prior art>
```

---

## insert-retrieve-on-insert

**Status:** open (lower priority — a convenience/perf refinement, not a missing
capability; see the correction below)

On insert we correctly trust a caller-supplied primary key and only consult
`RETURNING` (Pg / SQLite 3.35+ / DuckDB / MariaDB-insert) or `last_insert_id`
(base MySQL, non-returning SQLite) for keys the caller did *not* supply — this
matches DBIx::Class's core behavior. For DB-side *computed* values (defaults,
sequences, triggers, `col => \'now()'`), the workaround is `insert_and_refresh`
/ `auto_refresh`.

**Correction (2026-07-05):** an earlier draft of this item claimed QuickORM's
refresh is `RETURNING`-only with "no non-returning follow-up fetch" — that is
wrong. `Handle::_insert_and_refresh` uses `RETURNING` when the dialect supports
it, and otherwise inserts and then calls `Row::refresh` (a PK-keyed re-`SELECT`)
— so the full row is re-read on **every** dialect, base MySQL included. The
QuickStart manual (commit 8c77581) documents this correctly; do NOT reverse it.
QuickORM's whole-row re-select is in fact *broader* than DBIx::Class's
`retrieve_on_insert` for a trigger that rewrites a **supplied non-key** column:
DBIC skips supplied plain values (`Storage/DBI.pm:2084-2099`), QuickORM's
re-select catches them.

So the remaining gap is small: DBIx::Class's `retrieve_on_insert` is a
**per-column, schema-declared, automatic** opt-in — it fires with no explicit
call and fetches only that one column (via `RETURNING`, else a targeted
follow-up `SELECT`). QuickORM's equivalent is **whole-row and explicit** (you
must call `insert_and_refresh` / set `auto_refresh`, and it refetches every
field). The only true limitation is shared by both: a trigger that rewrites a
*supplied plain primary key* cannot be recovered by a PK-keyed re-select (the
key we would search by is already stale).

**Possible approach (nice-to-have):** a per-column "retrieve on insert" flag
that automatically (a) adds the column to the `RETURNING` list, or (b) is picked
up by the post-insert refresh on non-returning dialects — without requiring an
explicit whole-row `insert_and_refresh`, and optionally fetching just the
flagged columns instead of the whole row.

**References:** commit 8d694aa (preserve supplied PKs on non-returning insert);
commit 8c77581 (QuickStart insert-readback wording — correct, keep);
`lib/DBIx/QuickORM/Handle.pm` `_insert` and `_insert_and_refresh`;
`lib/DBIx/QuickORM/Row.pm` `refresh` (PK-keyed re-select); DBIx::Class
`Storage/DBI.pm::insert` (supplied-value skip 2084-2099, follow-up SELECT
2198-2215) and the `retrieve_on_insert` attribute in `ResultSource.pm`.

---

## affinity-from-db-type-info

**Status:** open

`lib/DBIx/QuickORM/Affinity.pm` resolves a column's affinity from a static name
map (`%AFFINITY_BY_TYPE`, via `affinity_from_type`). Every time a database adds a
new type-name alias the map needs a code patch (e.g. a092f54 added
`int2/int4/int8/float4/float8/hugeint` plus DuckDB unsigned variants). We want to
stop patching for the standard families by falling back to the DB's own type
catalog — while keeping the map as the fast path.

**Desired behavior:** use the static name map whenever the type name is present
in it (unchanged, authoritative). ONLY when a type name is missing from the map,
query the connection for its type info, derive the affinity from the numeric
ODBC/SQL type code via a small *stable* code→affinity table (SQL_INTEGER /
BIGINT / SMALLINT / TINYINT / DECIMAL / NUMERIC / FLOAT / REAL / DOUBLE →
numeric; SQL_CHAR / VARCHAR / LONGVARCHAR / WCHAR / WVARCHAR / CLOB → string;
SQL_BINARY / VARBINARY / LONGVARBINARY / BLOB → binary; SQL_BOOLEAN / BIT →
boolean; SQL_TYPE_DATE / TIME / TIMESTAMP / INTERVAL → string), then cache the
discovered name→affinity so later lookups hit the map. Net: new standard
numeric/char/binary/date aliases no longer require an Affinity.pm patch.

**Possible approach:** on a name-map miss, resolve the numeric code via
`$dbh->type_info($name)`, or a per-connection `NAME→DATA_TYPE` map built once
from `$dbh->type_info_all`, or `column_info`'s `DATA_TYPE`, or a
`SELECT ... LIMIT 0` + `$sth->{TYPE}`; run it through the stable code→affinity
table and memoize. Cache per-connection or per-dialect, since one type name can
mean different things on different engines. Fall through to the existing
prefix heuristic / undef when the code is unknown.

**Caveats (observed while probing the drivers):** support is uneven — SQLite's
`$sth->{TYPE}` returns the declared type *string* (not a code) and its catalog
is only its ~5 storage classes; DuckDB/PostgreSQL/MySQL return codes, but exotic
vendor types (json, uuid, arrays, enums, struct/list/map) collapse to
`SQL_VARCHAR` or `0`/unknown. So this covers the standard numeric/char/binary/
date families patch-free; semantically rich vendor types still want an explicit
`Type` class, not just an affinity. The code→affinity table itself is small and
never needs patching.

**References:** `lib/DBIx/QuickORM/Affinity.pm` (`affinity_from_type`,
`%AFFINITY_BY_TYPE`); commit a092f54 (the type-alias churn this avoids); DBI
`type_info_all` / `type_info` / `column_info` `DATA_TYPE` / `$sth->{TYPE}` and
the `:sql_types` constants.
