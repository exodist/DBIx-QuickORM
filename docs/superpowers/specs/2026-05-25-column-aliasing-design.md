# Column Name Aliasing (ORM name ≠ DB name)

**Status:** Approved design, pre-implementation.
**Branch:** `column-aliasing`
**Acceptance target:** un-skip and pass `t/remap.t`.

## Problem

A column's ORM-facing name should be allowed to differ from its name in the
database. Today the two are always identical: a field name is used verbatim as
a SQL column name on the way out, and DBI result keys are used verbatim as
in-memory field names on the way in. `t/remap.t` encodes the intended feature
and is currently `skip_all`'d with "ORM column names being different from DB
names not yet supported".

A previous experimental tree (`old2/`) attempted this by hooking
`_render_ident` deep inside `SQL::Abstract` with a package global; that code
was abandoned to `__END__` and never handled result-key remapping. We are not
reviving it.

## Guiding principle

The ORM alias is the **canonical user-facing identity** and the **in-memory
key**. The DB name is what SQL emits. Translation happens **only at the
SQLBuilder boundary**. Raw SQL strings a user passes in are **exempt** — humans
writing literal SQL use DB names; we do not rewrite SQL strings.

The database remains canonical: introspection still reads real DB names, and an
aliased column reconciles against its introspected counterpart by DB name.

## Scope

In scope:

- Per-column `db_name` (alias) on a single table/source.
- Outbound ORM→DB translation for: insert/update data keys, select field
  lists, RETURNING lists, upsert conflict/set keys, where-clauses, and
  `order_by`.
- Inbound DB→ORM remapping of result hashes (SELECT, RETURNING, and the
  `last_insert_id` path).
- Introspection/merge reconciliation matched on `db_name`.

Out of scope (see Follow-ups):

- Joins and any multi-source field qualification (`alias.field`).
- Cross-source name ambiguity.

Joins are handled in this branch only by a **croak-guard**: a join over a
component table that carries any aliased column (a column whose `db_name`
differs from its `name`) must croak with a clear "not yet supported" message,
rather than silently emitting wrong SQL.

## Design

### §1 Data model: `Column` gains `db_name`

`DBIx::QuickORM::Schema::Table::Column` mirrors the existing `Table` pattern:

```perl
# HashBase slots: add +db_name
sub name    { $_[0]->{+NAME}    //= $_[0]->{+DB_NAME} }
sub db_name { $_[0]->{+DB_NAME} //= $_[0]->{+NAME} }
```

Columns remain stored in `Table->{columns}` keyed by **ORM name** (canonical).
`merge`/`clone` already carry arbitrary slots via `%$self`, so `db_name`
propagates; confirm and add explicit handling only if needed.

### §2 DSL: `db_name` allowed in column scope

`DBIx::QuickORM::db_name` currently calls `_in_builder(qw{table db})`. Add
`column`, so `column my_id => sub { db_name 'id' }` records
`$frame->{meta}->{db_name}`.

### §3 Source lookups accept either name (load-bearing)

The Source role keeps columns ORM-keyed but resolves lookups by **either** ORM
or DB name, and exposes idempotent translators:

- `field_db_name($n)  -> db_name`  (idempotent: a db name maps to itself)
- `field_orm_name($n) -> orm_name` (idempotent)
- `has_field($n)`, `field_type($n)`, `field_affinity($n)` accept either name.

Rationale: `SQL::Abstract` is constructed with `bindtype => 'columns'`, so each
bind carries the column it rendered — which becomes a **DB name** after
outbound translation. Type deflate later looks that bind's field up via
`field_type`. If lookups accept the DB name too, the bind/type plumbing needs
**zero change**. Idempotence means double-translation and user-supplied DB
names are both safe.

Implementation: `Table` builds a secondary `db_name -> column` index at
compile/init. Validate `db_name` is **unique within a table** (else DB→ORM is
ambiguous) and croak on collision.

New required Source-role methods: `field_db_name`, `field_orm_name`. Sources
without aliasing (`View`, `LiteralSource`, `Join`) provide identity/passthrough
defaults (Join's behavior is constrained by the croak-guard above).

### §4 SQLBuilder contract

`DBIx::QuickORM::Role::SQLBuilder` documents and (where practical) enforces:
a builder MUST emit DB names for all generated SQL and MUST return result
hashes keyed by ORM names, using the source's name maps. `SQL::Abstract` is the
default implementation; the requirement is part of the pluggable contract so
alternative builders honor it in terms of their own where/order syntax. The
coupling to `SQL::Abstract`'s internal structure stays quarantined in the one
module that already depends on `SQL::Abstract`.

### §5 SQL::Abstract builder translation

Inside `qorm_insert/update/select/delete/where/upsert`, before handing args to
`SQL::Abstract`:

- **Data hashes** (insert/update): translate top-level keys ORM→DB.
- **Field lists** (select) and **RETURNING lists**: translate each plain-scalar
  entry where `has_field`; leave refs/expressions untouched.
- **Upsert** conflict/set keys: translate.
- **Where structure**: recursive walker. Rule — *translate a hash key iff
  `source->has_field(key)`; always recurse into values; arrays recurse
  per-element; scalars and scalar-refs are left untouched.* Operators
  (`-and`, `-or`, `-not`, `>`, `-in`, …) never match a field name and pass
  through. Forward-compatible: new `SQL::Abstract` operators need no walker
  change. Idempotent via §3.
- **`order_by`**: a small dedicated walker. Shares the "translate scalar iff
  `has_field`, leave refs alone" rule, but note the field lives in the **value**
  for the `{ -asc => 'col' }` / `{ -desc => [...] }` form (opposite of where),
  so it is a distinct handler. Handles scalar, arrayref, and the
  asc/desc hash forms.

**Inbound remap-after:** one helper remaps a result hash's keys DB→ORM via
`field_orm_name` (idempotent; unknown columns such as `count(*) AS foo` pass
through). Applied to `fetchrow_hashref`/RETURNING results and to the insert
`last_insert_id` path, so row data lands ORM-keyed before merging with the
user's (already ORM-keyed) `$data`. No SELECT `AS` aliasing — keeps generated
SQL uniform across dialects and avoids per-dialect RETURNING-alias support
differences.

Delete the dead `__END__` `_render_ident` / `_expand_insert_value` block.

### §6 Introspection merge (DB-canonical)

Autofill/introspection produces columns keyed by DB name. Merge must match on
`db_name`: an introspected column named `id` reconciles into a user column
whose `db_name` is `id` (ORM name `my_id`), filling in DB-derived metadata while
the user's ORM name and explicit overrides win. Result: a single column, stored
ORM-keyed. Inspect `Schema/Autofill.pm` and `DBIx::QuickORM::Util`'s
`merge_hash_of_objs` for the exact seam; the merge needs to key columns by
`db_name` during reconciliation rather than by the user's hash key.

### §7 Joins croak-guard (this branch)

When a `Join` is constructed (or first queried) over a component table that has
any aliased column, croak with a clear, user-facing message stating that joins
over tables with aliased columns are not yet supported. This converts a silent
correctness trap into an explicit limitation. The full join implementation is a
follow-up (see `docs/superpowers/specs/column-aliasing-follow-ups.md`).

## Testing

- Un-skip `t/remap.t`. Adjust its assertions only where the chosen in-memory
  key shape differs from what it assumes — §1 keeps `row_data->{stored}`
  ORM-keyed, so changes should be minimal or none.
- Add coverage:
  - Where-clause with nested `-or`/`-and` and operators (`>`, `-in`) on aliased
    columns.
  - `order_by` on an aliased column (scalar, arrayref, `-desc` hash forms).
  - Update + `refresh` round-trip on an aliased column.
  - Aliased primary key.
  - Introspection-merge of an aliased column against an ephemeral DB
    (`DBIx::QuickDB`), confirming DB metadata fills in and the ORM name wins.
  - Croak-guard: a join over a table with an aliased column dies with the
    expected message.

## Risks

- **Where-walker / `SQL::Abstract` sync.** The walker tracks `SQL::Abstract`'s
  structure. Mitigated by the `has_field`-gated rule (unknown/operator keys
  pass through) and by quarantining the coupling to the single
  `SQLBuilder::SQLAbstract` module. Accepted.
- **Cross-cutting obligation.** Every future SQL surface and every alternative
  builder inherits the translation duty; the Role contract documents it.

## Follow-ups

Tracked in `docs/superpowers/specs/column-aliasing-follow-ups.md`.
</content>
</invoke>
