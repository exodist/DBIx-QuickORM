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

**Status:** open

On insert, we correctly trust a caller-supplied primary key and only consult
`RETURNING` (Pg / SQLite 3.35+ / DuckDB / MariaDB-insert) or `last_insert_id`
(base MySQL, non-returning SQLite) for keys the caller did *not* supply — this
matches DBIx::Class's core behavior. The gap is DB-side *computed* column values
that the caller did not (or cannot) supply: defaults, sequences, and columns set
to a literal SQL expression (e.g. `col => \'now()'`). DBIx::Class pulls these
back into the in-memory row via a per-column `retrieve_on_insert` attribute,
using `RETURNING` where available and falling back to a follow-up PK-keyed
`SELECT` on non-returning storages. QuickORM's only analog is whole-row
`auto_refresh` / `insert_and_refresh`, which is `RETURNING`-only; we have no
per-column opt-in and no non-returning follow-up fetch, so on base MySQL a
DB-computed non-key column comes back stale in memory.

**Possible approach:** add a per-column flag (retrieve-on-insert style) that (a)
forces the column into the `RETURNING` list even when a value was supplied, and
(b) falls back to a PK-keyed `SELECT` after insert on dialects without insert
`RETURNING`. Note the shared, unavoidable limitation: a trigger that rewrites a
*supplied plain primary key* cannot be recovered by a PK-keyed re-select (the
key we would search by is already stale) — DBIx::Class has this same limitation,
so it is out of scope for the bridge.

**References:** commit 8d694aa (preserve supplied PKs on non-returning insert);
`lib/DBIx/QuickORM/Handle.pm` `_insert` (RETURNING vs `last_insert_id` branches);
DBIx::Class `Storage/DBI.pm::insert` (per-column classification 2066-2107,
`last_insert_id` branch 2182-2196, follow-up SELECT 2198-2215) and the
`retrieve_on_insert` attribute in `ResultSource.pm`.
