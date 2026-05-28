# ARCHITECTURE.md

Authoritative spec for the current `DBIx::QuickORM` implementation under
`lib/`. This describes what the code does today, not aspirations. When a
future change deviates from what is written here, update this document in
the same change (and, per `AGENTS.md`, record the deviation as an addendum
section at the end).

Code-style and language-feature rules live in `STYLE_GUIDE.md`; this file
covers structure and behavior only.

## 1. Guiding principles

- **The database is canonical.** Table/column/index/key metadata is
  introspected from the live database. User-provided declarations fill
  gaps and win on conflict, but introspection is the source of truth.
- **One row per identity per connection.** A `RowManager` keeps at most
  one in-memory `Row` object per `(source, primary key)` within a single
  connection, via a weak-reference cache.
- **Transaction-aware row state.** Each row carries a stack of state
  layers keyed to transaction/savepoint nesting. Reads always see the
  "active" layer; commits merge layers downward, rollbacks discard them.
- **Hand-written SQL on `DBI`.** No `DBIx::Class`. SQL generation goes
  through a pluggable SQL builder (default backed by `SQL::Abstract`).
- **Dialect-isolated DB differences.** All flavor-specific SQL and
  behavior (introspection queries, savepoints, RETURNING support, async,
  DSN construction) lives behind a `Dialect` class.
- **Builder/DSL up front, plain objects after.** A declarative DSL builds
  configuration which compiles to immutable plain objects; runtime work
  happens on those objects, not the DSL.

## 2. Layer map

```
  DSL / builder            DBIx::QuickORM (exported functions, build stack, plugins, variants)
        |  compile()
        v
  config objects           ORM ── DB ── Dialect (class)
        |  ->connection
        v
  live connection          Connection ── dbh ── Dialect (instance)
                              |       \
                              |        \__ RowManager (dedup/cache)
                              |        \__ Transaction stack
                              v
  schema model             Schema ── Table/View ── Column        (+ Autofill)
                              |
  sources (Role::Source)   Table | View | Join | LiteralSource
                              |
  query layer              Handle (immutable builder) ── SQLBuilder ── STH (sync/Async/Aside/Fork)
                              |                                          |
                              v                                          v
  rows                     Row ── RowData (STORED/PENDING/DESYNC stack)   Iterator / Row::Async
                              |
  value conversion         Affinity + Role::Type (JSON, UUID, ...)
```

## 3. Builder / DSL layer — `DBIx::QuickORM`

`use DBIx::QuickORM;` imports a declarative DSL used to define ORMs,
databases, servers, schemas, tables, columns, links, plugins, and autofill
configuration. The package itself is the builder engine.

### Build stack

The DSL maintains a `STACK` of build frames, one per nesting level. Each
frame records what is being built (`building`), the target `class`, its
`meta`, active `plugins`, and any `alt` variant branches. Context-sensitive
directives (`host`, `user`, `dialect`, `column`, etc.) act on the current
frame, so the same function behaves differently by context. Most builder
functions are polymorphic on call shape — e.g. `db($name => sub {...})`
defines, `db($name)` fetches, `db('server.dbname')` references a server DB.

### Exported functions (by area)

- **ORM/DB/schema entry:** `orm`, `db`, `schema`, `server`, `table`,
  `tables`, `view`.
- **Connection config:** `driver`, `dialect`, `attributes`, `host`/
  `hostname`, `port`, `socket`, `user`/`username`, `pass`/`password`,
  `creds` (credential callback), `connect` (connection callback), `dsn`,
  `db_name`.
- **Schema/table/column:** `column`, `columns`, `omit`, `nullable`,
  `not_null`, `identity`, `affinity`, `type`, `sql`, `default`,
  `primary_key`, `unique`, `index`, `link`, `row_class`, `handle_class`.
- **Autofill:** `autofill`, `autotype`, `autohook`, `autoskip`, `autorow`,
  `autoname`.
- **Composition:** `plugin`, `plugins`, `meta`, `build_class`, `alt`.

### Compilation

The DSL builds raw frames; `compile()` turns a frame into an object only
when needed (e.g. when `orm($name)` is called to fetch). `orm($name)`
returns a compiled `DBIx::QuickORM::ORM`; `db($name)` a `DBIx::QuickORM::DB`;
`schema($name)` a `DBIx::QuickORM::Schema`. Compiled results are cached per
variant.

### Variants — `alt`

`alt($variant => sub {...})` defines coexisting variant branches (e.g. a
PostgreSQL vs MySQL build of the same ORM). A variant is fetched with a
suffixed name such as `orm('name:variant')`.

### Quick interface — `quick`

`DBIx::QuickORM->quick(%params)` is a DSL-free shortcut for "I have a
database, give me rows as objects." It builds a `DB` + an autofill `ORM`
directly (no builder frames) and returns a live, introspected
`DBIx::QuickORM::Connection`. Params: `credentials => {dsn, user, pass,
attrs, dbd}` **xor** `connect => sub {...}`, optional `auto_types => [...]`
(type-class names registered via `qorm_register_type`), and an optional
`dialect` override. The dialect is detected from the `dsn` scheme or `dbd`,
or by probing a throwaway handle from the `connect` callback; `db_name` is
parsed from the dsn/handle (falling back to a generic name). The returned
connection keeps the ORM alive and reachable via `$con->orm`.

### Plugins — `DBIx::QuickORM::Plugin`

`Plugin` is a near-empty `HashBase` base class. Plugins are registered into
frames via `plugin`/`plugins` and run after a builder sub completes but
before the frame compiles: each plugin's `munge($frame)` may mutate frame
metadata. A plugin registered at one nesting level applies to all child
builds.

## 4. Compiled configuration objects

### `DBIx::QuickORM::ORM`

The compiled, runnable ORM. Holds a `DBIx::QuickORM::DB` (`db`), a
`DBIx::QuickORM::Schema` (`schema`) **or** a `Schema::Autofill` config
(`autofill`) — `init` enforces exactly one of schema/autofill — plus
optional `row_class`, `cache_class`, and `default_handle_class`. It lazily
creates and memoizes a single `DBIx::QuickORM::Connection` (`connection`).

Key methods: `connect` (new connection with a fresh `dbh`), `connection`
(lazy singleton), `reconnect`, `disconnect`, and `handle(...)` (shortcut to
`$orm->connection->handle(...)`).

### `DBIx::QuickORM::DB`

Stateless connection configuration. Holds `dialect` (a Dialect *class*),
`dbi_driver`, `attributes`, and either explicit `dsn`/`connect` callback or
the pieces to build a DSN (`host`/`socket`, `port`, `user`, `pass`,
`db_name`). `init` requires a dialect and forbids both `socket` and `host`.
Default DBI attributes include `RaiseError`, `PrintError`, `AutoCommit`, and
`AutoInactiveDestroy`.

- `dsn` returns an explicit DSN or asks the dialect class to build one.
- `new_dbh` creates a fresh `DBI` handle, via the `connect` callback if
  given, otherwise `DBI->connect` with the DSN. It does **not** retain the
  handle — connection lifecycle belongs to `Connection`.

## 5. Connection lifecycle — `DBIx::QuickORM::Connection`

A `Connection` owns one live `DBI` handle and everything tied to it:

- `dbh` — the live handle, created via `$orm->db->new_dbh`.
- `dialect` — a Dialect **instance** built around the `dbh` (and reblessed
  to a vendor-specific subclass where applicable; see §8).
- `schema` — a per-connection clone of the ORM schema (autofilled from the
  live DB when the ORM uses autofill).
- `manager` — the `RowManager` (default `RowManager::Cached`).
- `transactions` — the active transaction/savepoint stack (§13).
- `pid` — the PID at creation, for fork detection.
- Async bookkeeping: `in_async`, `asides`, `forks` (weakened).
- `default_sql_builder`, `default_handle_class`, `default_internal_txn`.

### Reconnect and fork safety

`reconnect` disconnects the old handle and obtains a fresh one from
`$orm->db->new_dbh`, updating `pid`. If the recorded `pid` differs from the
current process (a fork happened), `InactiveDestroy` is set on the old
handle before disconnect so a child does not tear down a parent's
connection. `auto_retry` reconnects when `$dbh->ping` fails and retries the
operation.

### Query/mutation entry points

`Connection` exposes row-level operations that build a `Handle` and route
results through the `RowManager` state methods, including `by_id`, `all`,
`one`, `count`, `iterate`, `insert`, `update`, `delete`, and `vivify`, plus
the `state_*_row` methods the query layer calls to materialize/cache rows
(`state_select_row`, `state_insert_row`, `state_update_row`,
`state_delete_row`, `state_vivify_row`).

## 6. Schema model

### `DBIx::QuickORM::Schema`

Holds named `Table`/`View` objects (`tables`) and pending link specs
(`_links`). At `init` it resolves links and, for autofilled tables, calls
`define_autorow`. Provides `table`/`maybe_table`/`add_table`, plus `clone`
and `merge` (used to combine introspected and user-declared schemas).

Link resolution collects link specs from the schema and its tables, uses
`column_key` to match against unique constraints on both sides, and creates
bidirectional `DBIx::QuickORM::Link` objects in each table's `links`.

### `DBIx::QuickORM::Schema::Table`

Holds `columns` (keyed by name), `primary_key` (arrayref of column names),
`unique`, `indexes`, `links`, optional `row_class`/`row_class_autofill`,
`is_temp`, and both `name` and `db_name` (each falling back to the other).
`merge` combines columns, unique constraints, links, indexes, and primary
keys with another table.

`Table` consumes `Role::Source` (§9): `source_db_moniker` returns `db_name`,
`source_orm_name` returns `name`, and `field_type`/`field_affinity`/
`has_field`/`fields_to_fetch`/`fields_to_omit`/`fields_list_all` delegate to
its columns (with omitted columns excluded from the default fetch set).

### `DBIx::QuickORM::Schema::Table::Column`

Holds `name`, `order`, `nullable`, `identity`, `generated`, `omit`,
`sql_default`, `perl_default`, `type`, and `affinity`. `type` is either a
`SCALAR` ref holding a raw SQL type string, or a type object consuming
`Role::Type`. `affinity($dialect)` is computed lazily and cached: from the
SQL type string via `affinity_from_type` (validated), or from the type
object via `qorm_affinity`.

`generated` is true for database-computed columns (stored or virtual
`GENERATED ALWAYS AS` columns). Generated columns participate in fetches
(they appear in `fields_to_fetch` and in RETURNING lists), but the row and
handle layers refuse to write them: the handle silently drops them from
`INSERT` / `UPDATE` data hashes, and the row's `field` setter and `update`
croak. Detection happens at autofill time in each dialect — see §8.

### `DBIx::QuickORM::Schema::View`

A subclass of `Table` that overrides `is_view` to return true; otherwise
identical.

## 7. Introspection & Autofill — `DBIx::QuickORM::Schema::Autofill`

Autofill bridges live-database introspection (performed by the dialect, §8)
with user declarations, implementing the "database is canonical" rule.

It holds: `types` (SQL-type-string → type object, indexed exact/upper/lower),
`affinities` (affinity → callbacks), `hooks` (named lifecycle callbacks),
`autorow` (generate row accessors?), and `skip` (nested skip rules).

- **Hooks.** A fixed set of valid hook names exists (`pre_table`,
  `post_table`, `table`, `pre_column`, `post_column`, `column`, `columns`,
  `index`, `indexes`, `primary_key`, `unique_keys`, `links`,
  `field_accessor`, `link_accessor`). `is_valid_hook` validates a name;
  `hook($name, $args, $seed)` threads a seed value through every registered
  callback (each called with the args plus `autofill => $self`).
- **`process_column`** maps an introspected column's SQL type to a type
  object (looking up `types` by exact/upper/lower, then falling back to
  affinity callbacks), replacing the raw type and updating affinity.
- **`skip`** lets users exclude tables/columns from autofill without writing
  full hooks.
- **`define_autorow($row_class, $table)`** generates per-column field
  accessors (each calling `$row->field($name, @_)`) and per-link accessors
  (singular for unique links, pluralized otherwise; calling `$row->obtain`
  or `$row->follow`), with accessor names customizable via the
  `field_accessor`/`link_accessor` hooks.

## 8. Dialects — `DBIx::QuickORM::Dialect`

A `Dialect` isolates all database-flavor-specific SQL and behavior. It holds
`dbh` and `db_name` (and `dbi_driver` on the MySQL branch).

Inheritance tree:

```
Dialect
├── Dialect::SQLite
├── Dialect::PostgreSQL
└── Dialect::MySQL
    ├── Dialect::MySQL::MariaDB
    ├── Dialect::MySQL::Percona
    └── Dialect::MySQL::Community
```

### Responsibilities (overridable contract)

- **Driver/version:** `dbi_driver`, `db_version` (and MySQL-only
  `db_vendor`).
- **Introspection:** `build_schema_from_db`, `build_tables_from_db`,
  `build_columns_from_db`, `build_table_keys_from_db` (PK/unique/links),
  `build_indexes_from_db`. Each flavor uses its own catalog queries —
  SQLite `pragma_*`, PostgreSQL `information_schema`/`pg_*`, MySQL
  `information_schema`/`STATISTICS`.
- **DDL generation:** `build_table_sql_from_schema`.
- **Transactions/savepoints:** `start_txn`, `commit_txn`, `rollback_txn`,
  `create_savepoint`, `commit_savepoint`, `rollback_savepoint`, `in_txn`.
- **Feature flags:** `supports_returning_insert`/`_update`/`_delete`,
  `supports_type`, `quote_binary_data`.
- **Async:** `async_supported`, `async_cancel_supported`,
  `async_prepare_args`, `async_ready`, `async_result`, `async_cancel`.
- **Upsert/DSN:** `upsert_statement`, `dsn`, `dsn_socket_field`.

### Selection

The dialect *class* is chosen explicitly in the builder via `dialect 'Name'`
(loaded under the `DBIx::QuickORM::Dialect::` namespace) and stored on the
`DB`. When a `MySQL` dialect *instance* is constructed, its `init` calls
`db_vendor` (probing `@@version_comment`, `version()`, and `SHOW VARIABLES`)
and **reblesses** itself into the matching `MySQL::MariaDB`/`Percona`/
`Community` subclass, then re-runs `init` for validation. If the vendor
cannot be resolved it warns and runs as the base `MySQL` dialect.

### Flavor notes

- **SQLite:** full RETURNING; no async; standard savepoints.
- **PostgreSQL:** full RETURNING; full async (`pg_async`/`pg_ready`/
  `pg_result`/`pg_cancel`); native `UUID`; `BYTEA` binary.
- **MySQL (base):** no RETURNING; async prepare/ready but no cancel; socket
  field differs by driver (`mysql_socket`/`mariadb_socket`).
- **MariaDB:** RETURNING on INSERT/DELETE but **not** UPDATE.
- **Percona / Community:** behave as base MySQL (validation only).

## 9. Source abstraction — `Role::Source`

A "source" is anything queryable. `Role::Source` requires
`source_db_moniker` (SQL table name / `table AS alias` / literal SQL),
`source_orm_name` (`'TABLE'`, `'VIEW'`, `'JOIN'`, `'LITERAL'`), `row_class`,
`primary_key`, `field_type`, `field_affinity`, `has_field`,
`field_is_generated`, `fields_to_fetch`, `fields_to_omit`,
`fields_list_all`. It provides `cachable` (true when the source has a
non-empty primary key).

Implementations:

- **`Schema::Table` / `Schema::View`** — the common case (§6).
- **`Join`** — a synthetic multi-table source (§15).
- **`LiteralSource`** — a blessed scalar ref wrapping raw SQL; `field_*`
  return permissive defaults, `fields_to_fetch` is `['*']`, and it is not
  cachable.

## 10. Query layer

### `DBIx::QuickORM::Handle`

An **immutable** fluent query builder. Mutating-looking methods return a new
`Handle` (a clone); calling such a method in void context croaks. The
constructor/`handle`/`clone` parse a flexible mix of positional and named
args: `Source`, `Row`, `SQLBuilder`, `Connection`, a `\%where` hashref, an
`\@order_by` arrayref, an integer `limit`, a table-name string, and named
pairs (`where`, `fields`, `omit`, `order_by`, `limit`, ...).

Attributes include `connection`, `source`, `sql_builder`, `where`, `row`
(when set, the WHERE derives from the row's primary key — and vice versa),
`order_by`, `limit`, `fields`, `omit`, the execution-mode flags `async` /
`aside` / `forked` (mutually exclusive), `auto_refresh`, `data_only`, and
`internal_transactions` (implicit per-statement transactions, default on).

- **Refining:** `where`/`and`/`or`, `order_by`, `limit`, `fields`, `omit`,
  `all_fields`, `data_only`, `sync`/`async`/`aside`/`forked`,
  `auto_refresh`/`no_auto_refresh`, `internal_transactions`.
- **Joining:** `join`/`left_join`/`right_join`/`inner_join`/`full_join`/
  `cross_join` build a `Join` source and return a `Handle` over it (§15).
- **Fetching:** `one` (exactly one, croak on >1), `first`, `all` (sync),
  `iterator` (lazy, async-capable), `count`, `iterate` (callback per row),
  `by_id`/`by_ids` (primary-key lookup with cache hit).
- **Mutating:** `insert`/`insert_and_refresh`, `upsert`/`upsert_and_refresh`,
  `update`, `delete`, `vivify` (build a pending row without inserting).
  Mutations route through the connection's `state_*_row` methods so the
  `RowManager` cache stays correct (including PK-change invalidation).

In async mode, fetchers return a `DBIx::QuickORM::Row::Async` (single row)
or an `Iterator` whose readiness tracks the async statement.

### `DBIx::QuickORM::Iterator`

A lazy, caching iterator: a `generator` coderef yields one item per call and
returns undef when exhausted. `next`/`first`/`last`/`list` walk and cache
results; an optional `ready` coderef supports async readiness checks.

### `DBIx::QuickORM::Row::Async`

A transparent placeholder for a row from an async query. `ready` checks the
async statement and materializes the real `Row` (via the connection's
`state_*_row` method); `swapout` replaces itself with the real row; an
`AUTOLOAD` delegates method calls to the materialized row. Marks itself
invalid if the query yields no row.

## 11. Row and the row-state model

### `DBIx::QuickORM::Row` (with `Role::Row`)

A `Row` wraps a single `RowData` object (`row_data`) and exposes typed,
lazily inflated field access:

- **Field access:** `field`/`raw_field` (get/set a single field; setting
  writes to PENDING; getting prefers PENDING, then STORED, fetching from the
  DB on demand if absent), `fields`/`raw_fields`, and the layer-specific
  `stored_field`/`pending_field` (and `raw_*` variants).
- **Inflation/deflation:** typed columns inflate on first access via the
  type's `qorm_inflate` and deflate via `qorm_deflate`; `conflate_args`
  assembles the `(field, value, source, dialect, affinity)` context.
- **State queries:** `in_storage`/`is_stored`, `is_valid`/`is_invalid`,
  `is_desynced`, `has_pending`, `field_is_desynced`, `check_sync`,
  `check_pk`.
- **Mutation:** `insert`, `save` (update when PENDING exists), `update`,
  `delete`, `refresh`, `discard` (drop PENDING/DESYNC), `force_sync` (clear
  DESYNC), `insert_or_save`, `clone`.
- **Relationships (via `Role::Row`):** `follow` (Handle for related rows),
  `obtain` (the single related row for a unique link), `insert_related`,
  `siblings`, plus primary-key helpers and `display`.

`Role::Row` supplies the shared interface and defaults; `Row` sets
`track_desync` true.

### `DBIx::QuickORM::Connection::RowData`

The state engine behind every row. Constants name the layers:

- **STORED** — last known database values (confirmed DB state).
- **PENDING** — local unsaved changes.
- **DESYNC** — fields whose STORED was refreshed while PENDING still held a
  change to them (a conflict marker).
- **TRANSACTION** — the `Transaction` that owns a given state layer (undef at
  base level).

`RowData` holds a `stack` of state dicts ordered by transaction nesting,
plus `connection`, `source`, and an `invalid` reason. The `active` method
computes the visible layer: starting from the bottom, it discards layers
owned by rolled-back transactions, merges committed layers downward, and
stops at the first still-open transaction (or the base layer). A row whose
every layer belongs to a rolled-back transaction becomes invalid (e.g. a row
inserted inside a transaction that rolled back).

State transitions go through `change_state`: when the incoming state shares
the active layer's transaction (or neither is in a transaction) it merges in
place via `_merge_state`; otherwise it pushes a new layer. Merging replaces
STORED field-by-field, sets DESYNC where a refreshed STORED value differs
from a field that has PENDING changes, and folds PENDING/DESYNC forward.
Field comparison uses the source's type (`qorm_compare`) or its affinity
(`compare_affinity_values`).

## 12. RowManager — dedup / cache

`DBIx::QuickORM::RowManager` is the per-connection row-identity manager
holding a reference to the connection's `transactions` stack. It builds state
dicts (`_state`, stamping the current transaction) and vivifies rows
(`_vivify`, choosing the row class from the source, then connection schema,
then `DBIx::QuickORM::Row`). Its operations — `select`, `insert`, `update`,
`delete`, `vivify`, `invalidate` — translate a database result into the
right STORED/PENDING/DESYNC transition on a new or existing row via
`change_state`. The base class does no caching (`does_cache` is false).

`DBIx::QuickORM::RowManager::Cached` (the default) adds a weak-reference
cache keyed `source_orm_name → cache_key → row`, where `cache_key` joins
primary-key values with `chr(31)` (escaped). On `select`/`insert`/`update`
it looks up an existing row by PK and, on a hit, mutates that same object's
state rather than creating a duplicate — this is both the dedup and the cache
mechanism. PK changes move the cache entry; weak refs let GC drop entries
automatically. Caches are per-connection and per-source, never global.

## 13. Transactions & savepoints

`Connection->txn` opens a transaction or, when one is already open, a
savepoint. The connection's `transactions` arrayref is the stack; each entry
is a `DBIx::QuickORM::Connection::Transaction`:

- The first `txn` calls the dialect's `start_txn` (and refuses to proceed if
  a transaction is already open outside the ORM's control); nested `txn`s
  create a uniquely named savepoint (`SAVEPOINT_<pid>_<counter>`).
- Each `Transaction` holds an `id`, optional `savepoint` name, success/fail/
  completion callbacks, a `result` (undef = active, true = committed, false =
  rolled back), `errors`, and caller `trace`. Parent/root fail callbacks can
  be attached at open time.
- A `finalize` closure pops the stack and issues the matching dialect call
  (`commit_savepoint`/`rollback_savepoint` for savepoints, `commit_txn`/
  `rollback_txn` for the root), then fires callbacks via `terminate`.
- `commit`/`rollback` (`abort` is an alias) set the result and, for
  block-managed transactions, exit via the `QORM_TRANSACTION` label.
- `DESTROY` rolls back any transaction that falls out of scope still active.

Transaction state flows into the row-state model: row state layers are
stamped with the owning transaction, so `RowData->active` reflects commits
and rollbacks automatically (§11).

## 14. Types & affinity

### `DBIx::QuickORM::Affinity`

Maps SQL types to one of four **affinities** — `string`, `numeric`,
`binary`, `boolean` — and provides value semantics. Exports include
`valid_affinities`, `validate_affinity`, `affinity_from_type` (normalizes a
type string — lowercase, strip `(...)`, resolve common aliases/prefixes —
to an affinity), and `compare_affinity_values` (affinity-appropriate
comparison: xor for boolean, numeric `==`, string/binary `eq`).

### `Role::Type` and type classes

`Role::Type` is the inflate/deflate contract, requiring `qorm_inflate`,
`qorm_deflate`, `qorm_compare`, `qorm_affinity`, and `qorm_sql_type`; an
optional `qorm_register_type` hooks a type into the autotype system.

- **`Type::JSON`** — affinity `string`; inflates JSON text to a Perl ref,
  deflates a ref to JSON, compares canonically; picks `jsonb`/`json` then
  falls back to `longtext`/`text`. Registers the `json`/`jsonb` type names.
- **`Type::UUID`** — affinity depends on storage (`string` for native/text
  UUID, `binary` for 16-byte binary); validates and normalizes both forms;
  `new` mints a uuid7; `qorm_sql_type` uses native `uuid` or `VARCHAR(36)`.
  Registers the `uuid` type name.

Type/affinity flow into columns (§6), comparisons (§11), and field
inflation on rows (§11).

## 15. Links & joins

### `DBIx::QuickORM::Link`

A directed relationship between column sets on two tables: `local_table`/
`local_columns`, `other_table`/`other_columns`, `unique` (is the other side
a 1:1 unique key?), a `key` (`column_key` of the local columns), and
`aliases`. `parse` builds a `Link` from an existing object, a hash spec, or
a scalar-ref table reference (validating tables and inferring `unique`
against schema constraints); `merge`/`clone` combine and copy links. Schema
link resolution (§6) produces a `Link` for each direction.

### `DBIx::QuickORM::Join`

A synthetic `Role::Source` (and `Role::Linked`) representing a multi-table
join. It tracks join `components` (each an aliased table with its `link`,
`from`, and join `type`), assigns aliases (`a`, `b`, ...), and builds the
`FROM ... JOIN ... ON ...` SQL via `source_db_moniker`. `join`/`left_join`/
`right_join`/`inner_join` add components and return a cloned `Join`.
`fields_to_fetch` emits alias-qualified `a.col AS "a.col"` selectors, and
`fracture` splits a fetched row into per-component data (dropping all-NULL
components).

### `DBIx::QuickORM::Join::Row`

Wraps a joined result. At construction it `fracture`s the row data and
builds the per-component sub-rows through the connection's `RowManager`,
indexing them `by_alias` and `by_source`. Field accessors split an
alias-qualified name (`a.col`) and delegate to the right sub-row; sync/
discard/refresh/save/delete fan out to all sub-rows. Mutating methods that
have no well-defined join semantics (`insert`, `update`, `follow`, etc.) are
not implemented and croak.

### `Role::Linked`

Provides link resolution and caching for sources that expose `links`:
`resolve_link` accepts a `Link`, a spec hash/array, or a name and resolves it
(via `from` for joins), while `_link_from_name` lazily builds and queries an
indexed cache (`by_table`, `by_alias`, `by_table_key`, `by_table_alias`),
merging duplicate links and erroring on genuine ambiguity.

## 16. SQL building

`Role::SQLBuilder` is the generation contract: `qorm_select`, `qorm_insert`,
`qorm_update`, `qorm_delete`, `qorm_where`, `qorm_and`, `qorm_or` (plus the
provided `qorm_where_for_row`, which uses a row's primary-key hashref).

`DBIx::QuickORM::SQLBuilder::SQLAbstract` is the default, extending
`SQL::Abstract`. It is constructed with `bindtype => 'columns'` and wraps the
parent's `select`/`insert`/`update`/`delete`/`where`, taking `source => ...`
plus standard params, deriving the table/join text from
`source->source_db_moniker`, and returning `{statement, bind, source}` where
each bind is a structured `{param, value, type, field}` (with `limit`
appended as a `LIMIT ?` bind). `qorm_upsert` builds an INSERT plus
dialect-specific conflict handling; `qorm_and`/`qorm_or` produce `-and`/`-or`
structures.

## 17. Statement handles & async

`Role::STH` is the iteration contract shared by all handles (`next`,
`result`, `ready`, `done`, `set_done`, `clear`, `got_result`, `only_one`,
plus `connection`/`source`/`dialect`); it provides default `cancel_supported`
(false) and `cancel` (croak). `Role::Async` extends it for asynchronous
handles, providing `wait` (poll `ready` until true) and a `DESTROY` that
cancels or drains an unfinished async handle.

- **`STH`** — synchronous. Wraps a prepared `sth`, exposes `next`/`result`,
  enforces `only_one`/`no_rows`, and supports an `on_ready` callback.
- **`STH::Async`** — extends `STH`; `result` blocks on the dialect's
  `async_result`, `ready` polls `async_ready`, `cancel` uses `async_cancel`
  when supported; cleanup via `connection->clear_async`.
- **`STH::Aside`** — extends `STH::Async` for connection implementations that
  manage async queries out-of-band; cleanup via `connection->clear_aside`.
- **`STH::Fork`** — runs the query in a forked child and streams JSON
  (result, then one object per row) back over an `Atomic::Pipe` with zstd
  compression (`Atomic::Pipe->pair(compression => 'zstd')`), so rows are
  compressed on the wire and more fit before the pipe buffer fills. Each
  row is one `write_message`; the reader pulls with `read_message`
  (non-blocking for readiness, blocking to fetch). Supports cancel (drop the
  pipe, TERM the child); cleanup via `connection->clear_fork`.

## 18. Utilities — `DBIx::QuickORM::Util`

Shared helpers (exported on request): `load_class` (dynamic require with
optional namespace prefix and `+`-absolute handling), `find_modules`
(`Module::Pluggable`-based discovery), `merge_hash_of_objs` /
`clone_hash_of_objs` (object-aware deep merge/clone used by schema, link, and
join composition), `column_key` (`join ', ' => sort @cols` — the canonical
column-set fingerprint used for keys and uniqueness), `parse_conflate_args`
(normalizes the flexible argument shapes accepted by type inflate/deflate,
deriving affinity from the source when absent), and `debug`.

`Object::HashBase` is the object base used throughout (see
`STYLE_GUIDE.md`).

---

This document reflects the implementation at version `0.000020`. Append
deviation addenda below as the architecture evolves.

## Addendum: Column name aliasing (ORM name ≠ DB name)

A column may use one name in the ORM and a different name in the database. The
ORM name is the canonical user-facing identity and the in-memory key; the
database name is what SQL emits.

- **Schema.** `Schema::Table::Column` carries both `name` (ORM) and `db_name`,
  each defaulting to the other (mirroring `Schema::Table`). `Schema::Table`
  stores columns keyed by ORM name, validates `db_name` uniqueness within a
  table, and resolves columns by either name. The source interface gains
  `field_db_name` / `field_orm_name` (both idempotent; unknown names pass
  through), and `has_field` / `field_type` / `field_affinity` accept either
  name.

- **SQL builder boundary.** Name translation happens only in the SQL builder.
  Builders must emit database names in all generated SQL — translating
  insert/update data keys, select field lists, returning lists, upsert
  conflict/set columns, where-clauses, and order-by from ORM names via the
  source — and callers restore ORM names on fetched rows via `qorm_row_to_orm`.
  The where-clause walker translates a hash key only when the source recognizes
  it as a field, so logic/comparison operators pass through and the rule
  survives new `SQL::Abstract` operators. Literal SQL a caller passes is never
  rewritten.

- **Read path.** `RowManager::parse_params` remaps fetched rows (database names
  → ORM names) for every row-creating path; `data_only` select paths remap at
  the fetch site. Type deflate continues to work unchanged because field
  lookups accept the database names carried on binds.

- **Skip when nothing diverges.** Each source exposes a cached
  `source_has_aliases` (true only when some column's ORM name differs from its
  database name; a join ORs its components). The per-query outbound translation
  (`_translate_params`) and the per-row inbound remaps (`parse_params`,
  `qorm_row_to_orm`) short-circuit when it is false, so a schema with no aliases
  pays effectively nothing for the feature.

- **Introspection.** The database stays canonical. `Schema::Table::merge`
  reconciles an introspected column (keyed by database name) with a user column
  by matching `db_name`, producing one ORM-keyed column whose database-derived
  metadata fills gaps and whose ORM name and explicit overrides win; the primary
  key is translated to ORM names.

- **Joins.** Joins translate aliased names through their `alias.field` protos:
  `field_db_name`/`field_orm_name` split the alias, translate the field against
  that component table, and re-attach the alias; `fields_to_fetch` emits
  database names in the SELECT so the flat row is remapped back to ORM names by
  the normal fetch path before it is fractured into per-component rows. Join ON
  clauses use link columns, which are database names already. A bare (unaliased)
  field resolves to the first component that has it; qualify with the alias to
  disambiguate.
