# Code Review Findings

## P1: Rowless updates that change an aliased primary key corrupt the identity cache

Affected code: `lib/DBIx/QuickORM/Handle.pm` lines 2056-2063 and 2096-2098.

When a cache-aware update is run without a row object, `Handle::update` first selects the primary key fields into `$rows` and later derives `$old_pk` and `$new_pk` from those fetched hashes:

```perl
$old_pk = $changes_pk_fields ? [ map { $row->{$_} } @$pk_fields ] : undef;
$new_pk = $changes_pk_fields ? [ map { $fetched->{$_} } @$pk_fields ] : undef;
```

After this branch's aliasing changes, the SQL builder emits database column names, so the internal select at line 2096 returns hashes keyed by database names (`user_id`) while `$pk_fields` still contains ORM names (`uid`). For a rowless update that changes an aliased primary key, both key lists become `[undef]`. `RowManager::Cached::cache` then deletes/caches under the empty cache key instead of moving the existing row from the old key to the new key.

Reproduction with SQLite and a schema mapping `uid => user_id`:

```perl
my $a = $h->one(uid => 1);
$h->where({uid => 1})->update({uid => 2});
my $old = $con->state_cache_lookup($h->source, [1]);
my $new = $con->state_cache_lookup($h->source, [2]);
my $b   = $h->one(uid => 2);
```

Observed result:

```text
old=a new=none
fetched_new_same=0 uid=2
```

That leaves the stale row under the old primary key and creates a second row object when the new key is fetched, violating the one-row-per-primary-key cache contract. The rowless update path needs to normalize the fetched hashes back to ORM names before deriving `$old_pk`/`$new_pk`, or derive those key values using `field_db_name`/`field_orm_name` consistently.

## Verification Notes

Ran:

```text
git diff --check master...HEAD
perl agent_scripts/audit-methods-not-functions lib
prove -Ilib t/remap.t t/remap_sql.t t/remap_join.t t/remap_merge.t
```

`git diff --check` passed.

`perl agent_scripts/audit-methods-not-functions lib` reports existing style-guide violations, including some touched files (`LiteralSource.pm`, `Join.pm`) but not all are introduced by this branch.

The focused remap tests passed for `t/remap_sql.t`, `t/remap_join.t`, and `t/remap_merge.t`. `t/remap.t` failed in this sandbox because non-SQLite `DBIx::QuickDB` backends could not bind Unix sockets under `/tmp` (`Operation not permitted`); the SQLite-covered behavior was exercised separately with the reproduction above.
