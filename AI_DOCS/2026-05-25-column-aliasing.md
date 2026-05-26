# Column Name Aliasing (ORM name ≠ DB name)

## What and why

`t/remap.t` encoded an intended feature — letting a column use one name in the
ORM and a different name in the database — and was `skip_all`'d as "not yet
supported". This task implements that feature: a column may declare a `db_name`
distinct from its ORM `name`, and the ORM uses the ORM name everywhere a human
touches it while emitting the database name in all generated SQL.

The full design and the deferred-work notes live in
`docs/superpowers/specs/2026-05-25-column-aliasing-design.md` and
`docs/superpowers/specs/column-aliasing-follow-ups.md`.

## Guiding principle

The ORM name is the canonical user-facing identity and the in-memory key. The
database name is what SQL emits. Name translation happens only at the SQL
builder boundary. Literal SQL strings a caller passes are never rewritten —
humans writing raw SQL use database names.

The database stays canonical: introspection reads real database names, and an
aliased column reconciles against its introspected counterpart by database
name.

## Key decisions

- **Translate at the SQL builder boundary, not via `SQL::Abstract` internals.**
  An earlier experimental tree hooked `_render_ident` inside `SQL::Abstract`
  with a package global and never handled result-key remapping; that approach
  was abandoned and is not revived. Instead the builder rewrites field names in
  the data/where/field-list/order-by/returning structures it is handed, before
  passing them to `SQL::Abstract`, and the `Role::SQLBuilder` contract requires
  any builder to emit database names and return ORM-keyed rows. The coupling to
  `SQL::Abstract`'s where/order structure is quarantined in the one module that
  already depends on `SQL::Abstract`.

- **Sources resolve fields by either name; translation is idempotent.**
  `field_db_name`/`field_orm_name` accept either the ORM or the database name
  and return the requested direction unchanged when given a name already in that
  form. `has_field`/`field_type`/`field_affinity` accept either name. This is
  load-bearing: `SQL::Abstract` is built with `bindtype => 'columns'`, so each
  bind carries the (now database) column it rendered; type deflate looks that
  name up via `field_type`, which still resolves because lookups accept database
  names. The bind/type plumbing needed no change.

- **Where-walker rule: translate a hash key iff the source recognizes it.**
  Operators (`-and`, `-or`, `>`, `-in`, …) never match a field name and pass
  through, so new `SQL::Abstract` operators need no walker change. Operator
  values and value arrays under a field key are left as-is.

- **Inbound remap via a single chokepoint.** `RowManager::parse_params` remaps
  fetched rows from database names to ORM names for every row-creating path
  (insert/update/select/delete); idempotence makes this safe even for data that
  is already ORM-keyed (e.g. insert input merged with `RETURNING`). The
  `data_only` select paths, which bypass `parse_params`, remap at the fetch
  site.

- **Introspection merge matches on `db_name`.** `Schema::Table::merge` re-keys
  the introspected columns (keyed by database name) onto the user's ORM names by
  matching `db_name`, and translates the primary key to ORM names, so the merged
  table is uniformly ORM-keyed with introspected metadata filling gaps and the
  user's overrides winning.

- **Joins are guarded, not implemented** (initial branch). Joins use
  `alias.field` protos and need alias-aware translation on top of every
  primitive; the initial branch croaked over aliased columns rather than
  emitting wrong SQL. This was lifted in the follow-up below.

## Rejected alternatives

- **`SQL::Abstract` render hook** (the old approach): fragile, depends on
  internals and a global, and never solved result remapping.
- **Translate in the Handle layer above the builder:** spreads translation
  across many call sites; easy to miss one. Centralizing in the builder keeps
  one chokepoint and matches the pluggable-builder contract.
- **Store the database→ORM map as a normal Table slot:** broke the structural
  comparison in `t/autofill.t` and risked staleness across merge/clone. The map
  is built lazily and dropped in `init`, matching the existing lazy-cache
  pattern for the field lists.

## Follow-ups (completed)

The deferred work has since been implemented on this branch:

- **Joins are alias-aware.** `Join::field_db_name`/`field_orm_name` thread the
  `alias.` prefix through per-component translation; `fields_to_fetch` emits
  database names so the flat row is remapped before `fracture`. The croak-guard
  is removed. A pre-existing bug in `_field_source`'s bare-field branch was
  fixed, and `has_field` is guarded against unknown protos (the where-walker
  now calls it with operator keys). Cross-source ambiguity is handled by
  qualifying with the alias; a bare field resolves to the first component.
- **`unique`/`index` under introspection merge.** `Schema::Table::merge`
  translates unique-constraint column lists (and their `column_key` keys) and
  index column lists through the same `db_to_orm` map used for columns and the
  primary key. This metadata remains stored-only (not consumed by the query
  layer), so the translation is for consistency.

Originally tracked in `docs/superpowers/specs/column-aliasing-follow-ups.md`.
</content>
