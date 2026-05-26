# Column Aliasing — Follow-ups

**Status: all items below are now implemented on the `column-aliasing` branch.**
Joins are alias-aware (the croak-guard is removed), cross-source ambiguity is
handled by qualifying with the alias, and `unique`/`index` column references are
translated during introspection merge. This file is retained as the record of
what the follow-up work covered.

Deferred from the initial column-aliasing branch (see
`2026-05-25-column-aliasing-design.md`). The initial branch shipped single-source
aliasing plus a croak-guard that made joins over aliased columns fail loudly.
This file records what the follow-up handled to lift that guard.

## 1. Joins / multi-source field qualification

Joins do not use bare field names; they use `alias.field` protos.

- `Join::_field_source` (`lib/DBIx/QuickORM/Join.pm`) splits a proto on `.`,
  resolves which component table owns the field, and delegates
  `field_type`/`field_affinity`/`has_field` to that table.
- `Join::fields_to_fetch` emits `alias.col AS "alias.col"` and the flat fetched
  row is later fractured back into per-table rows keyed by those `alias.field`
  labels.

What aliasing requires here:

- **`field_db_name`/`field_orm_name` on `Join` must be alias-aware.** Proto
  `t1.my_id` must translate to `t1.id` *against t1 specifically*, and back.
  The single-table translators are flat `name <-> db_name` maps; the join
  versions must split the `alias.` prefix, dispatch to the component, translate,
  and re-join.
- **Select label vs SQL column diverge.** `Join::fields_to_fetch` currently uses
  the same string (`$_`) for both the rendered SQL column and the `AS` label.
  Once `name != db_name` these must split: SQL column = `alias.<db_name>`,
  label = `alias.<orm_name>`, so the row-fracture and downstream ORM keys still
  line up.
- **Where-walker is already compatible** (translate key iff `has_field`), but
  relies on the join's `field_db_name` returning the `alias.<db>` form.

## 2. Cross-source name ambiguity

The DB→ORM inbound remap assumes `db_name` is unique within the source (the
single-table branch validates this). In a join, two component tables can each
have a DB column `id`; results are disambiguated only by the `alias.` prefix, so
the inbound remap must become alias-aware as well. Same root problem as #1 —
handle together.

## 3. Lifting the croak-guard

The initial branch croaks when a join is built/queried over a component table
with any aliased column. Once #1 and #2 are implemented, remove that guard and
add join-specific tests:

- Join two aliased tables; select, where, and order_by across both using ORM
  names; confirm correct DB names in generated SQL and correct ORM keys in
  results.
- Ambiguous bare field (same db column name in two components) resolves via the
  alias prefix.
- Multi-alias of the same table within one join.
- Row-fracture correctness with aliased columns.

## 4. Unique / index column references under introspection merge

`Schema::Table::merge` re-keys columns and translates the primary key to ORM
names, but does not translate the column references inside `unique` constraints
or `index` definitions. For a non-aliased schema this is a no-op; for an
aliased column that participates in a unique constraint or index discovered via
introspection, those references stay in database names. This does not croak
(init does not validate unique/index column names against the column set), but
it is incomplete. When implementing, translate the `unique` keys
(`column_key`-fingerprinted) and index column lists through the same
`db_to_orm` map `merge` already builds.

## 5. Other surfaces to re-audit when lifting the guard

- Any query surface added after the initial branch must be checked for the same
  ORM→DB / DB→ORM obligation (the SQLBuilder contract documents this).
- Links/relations that build joins implicitly inherit the join requirements
  above.
</content>
