# AGENTS.md

This project is a ground-up, fresh-start rewrite of **`DBIx::QuickORM`**.
Earlier attempts were experimental; we are **not** preserving backward
compatibility with any of them. Everything ships in a single
distribution (`DBIx-QuickORM`) under the `DBIx::QuickORM` namespace.

At a high level, `DBIx::QuickORM` is an ORM where the **database is
canonical**:

- A single `DBIx::QuickORM` object maintains one primary database
  connection (reconnecting if the connection is lost) built from
  `credentials` or a `connect` callback.
- Table and column metadata (columns, indexes, primary keys, etc.) is
  introspected directly from the live database and populated
  automatically. User-provided overrides fill gaps and win where they
  conflict, but the database is the source of truth.
- Row objects track state through a transaction/savepoint stack, with
  separate `fetched` (raw), `pending` (unsaved), and `inflated`
  (type-converted) views of their data.
- Optional `dedup` and `cache` layers keep at most one copy of a row in
  memory per connection and avoid re-querying rows already loaded.
- `DBIx::QuickORM::Type` classes provide automatic inflate/deflate for
  things like JSON, UUIDs, and DateTime.

`ARCHITECTURE.md` at the repo root is the authoritative spec describing
the current implementation.

You are an expert Perl developer. Write code following the patterns
and styles of "Exodist" (Chad Granum) as seen throughout this
codebase.

## How work happens

The project is **driven by the user, not by an AI plan**. There is no
multi-stage staged backlog; agents do not pick what to do next.
Instead, the flow is:

- The user writes stubs / comments / pseudo-code and asks an agent to
  flesh out a specific piece.
- The user asks an agent to grab a specific component from a previous
  iteration under `old*/` and adapt it.
- The user asks targeted questions, requests reviews, or requests
  follow-up edits.

Agents respond to those specific asks and stop. Do not invent
follow-up work, do not expand scope, do not draft staged plans. When
an ask is ambiguous, ask back before guessing.

## Reference trees

Earlier experimental implementations live in `old*/` directories at the
repo root (`old/`, `old1/`, `old2/`, …). They are **reference only** —
read them for prior art and components worth adapting, but the new
implementation owns its own decisions and is not bound by theirs.

**Never modify anything under `old*/`.** Copy out, modify the copy. The
old trees are immutable history we read against.

If an old tree's behavior conflicts with `ARCHITECTURE.md` or
`STYLE_GUIDE.md`, the current docs win — flag the conflict if it is
non-trivial.

## Canonical sources of truth

1. **`ARCHITECTURE.md`** — Authoritative spec describing the current
   implementation. Grown incrementally as architecture is decided;
   deviations are recorded as addenda at its end.
2. **`STYLE_GUIDE.md`** — Style, formatting, and language-feature
   rules for code in this repository.
3. **`STYLE_GUIDE_AGENT_CHECKLIST.md`** — Self-audit checklist agents
   walk through every touched file before handing changes back to
   the user. Mirrors `STYLE_GUIDE.md` and the pre-review checks
   below.
4. **This file (`AGENTS.md`)** — Per-repository agent / contributor
   workflow, pre-review checks, and project conventions that are
   not pure style.

If you are about to implement something that seems to conflict with
`ARCHITECTURE.md`, stop and verify. The most common cause is that
the other document is stale — follow `ARCHITECTURE.md` and flag the
inconsistency.

## Pre-review checks

Before handing changes back to the user for review, run the following
passes against every file the branch touched (typically
`git diff --name-only $base...HEAD`, where `$base` is your merge
base — `origin/master`, `origin/main`, or whatever branch you cut
from). Resolve anything they turn up, then re-run the test suite.

1. **Style-guide pass.** Walk
   `STYLE_GUIDE_AGENT_CHECKLIST.md` against every touched file.
   Common slips: `eval` patterns (always check the return value,
   never raw `$@`), `croak` vs `die`, `//=` for defaults,
   `Time::HiRes::sleep` for sub-second waits,
   `Object::HashBase` slot ordering, no trailing whitespace, and the "named subs in
   object modules must be methods, not functions" rule (see
   `STYLE_GUIDE.md` "Naming and structure"). Run
   `perl agent_scripts/audit-methods-not-functions lib` and resolve
   every reported hit.

2. **POD pass.** Verify the file follows the POD layout in
   `STYLE_GUIDE.md` ("POD" section): `NAME` / `DESCRIPTION` /
   `SYNOPSIS` (plus `ATTRIBUTES` for HashBase-style classes) at the
   top of the file, `EXPORTS` / `PUBLIC METHODS` / `PRIVATE METHODS`
   inline above each sub, `SOURCE` / `MAINTAINERS` / `AUTHORS` /
   `COPYRIGHT` under `__END__`. Run `podchecker` on every `.pm`
   touched; resolve every error and warning.

3. **Util / role / base-class reuse pass.** Re-scan touched files
   for logic that already exists as a utility. The relevant homes
   are `DBIx::QuickORM::Util`, `DBIx::QuickORM::Util::*`,
   `DBIx::QuickORM::Role::*`, and the relevant base classes
   (e.g. the row / table / column / type base classes). If the file
   open-codes something a util / role / base class already provides,
   switch to using it. If you see the same logic appearing in three
   or more places across the touched files, extract it to a util /
   role / base class instead of leaving the duplication.

These three passes are mandatory, not optional. Land their fixups
either as cleanup commits or by amending the relevant feature
commits. Only after they pass should you announce the work as
ready for review.

## AI task documentation

`AI_DOCS/` is for durable context that the code and commit history
cannot carry on their own. Default: **do not** write one. Only write
an AI_DOC when the task falls into one of these categories:

- A significant new feature.
- An architectural change (connection lifecycle, schema introspection
  contract, transaction/row-state model, type inflate/deflate
  contract, dedup/cache layer behavior, etc.).
- A non-trivial refactor that changes module boundaries, public
  interfaces, or coding patterns across multiple files.

Do **not** write an AI_DOC for:

- Bug fixes. If the fix directly contradicts or extends what an
  existing AI_DOC or `ARCHITECTURE.md` section already says, update
  that document in place. Otherwise the commit message is the only
  record.
- Test-only work (adding tests, fixing flakes, test refactors).
  Commit messages only.
- Trivial cleanups (typos, whitespace, perltidy passes, comment
  tweaks).

When an AI_DOC is warranted, it should describe:

- What the task was and what triggered it.
- Decisions made, including alternatives considered and why they
  were rejected.
- Any architectural changes introduced.

Filename convention: `AI_DOCS/<YYYY-MM-DD>-<short-slug>.md`.

Any decision to deviate from `ARCHITECTURE.md` must **also** be
recorded as an addendum section appended to `ARCHITECTURE.md`
itself, explaining and justifying the deviation. `ARCHITECTURE.md`
remains the authoritative spec; addenda exist so anyone reading it
sees the deviation and its reasoning in one place. This rule applies
regardless of whether an AI_DOC is also written.

### Referencing AI docs from code

User-facing text — POD, `die` / `warn` / `croak` / `print` strings,
and any other diagnostic shown to users — must **never** reference any
`.md` document (including `ARCHITECTURE.md`, `STYLE_GUIDE.md`,
`STYLE_GUIDE_AGENT_CHECKLIST.md`, `AI_DOCS/*`, this file, etc.). If
the rule or behavior matters to the user, restate it in plain prose;
if it does not, drop the reference. Users cannot read internal
documentation and should not be pointed at it. POD is user-facing —
see `STYLE_GUIDE.md` "POD style".

Regular `#` comments in code may reference `ARCHITECTURE.md` or
`STYLE_GUIDE.md` (both tracked, both authoritative). References to
`AI_DOCS/*` or other markdown files are **discouraged** and should
only appear when the comment cannot stand on its own without one.
When a reference is included, it must be specific: full path plus
a section identifier. A bare token like `D6` or `M2 step 4+5` is
not acceptable.

When in doubt, restate the rule itself in the comment and skip the
reference.

## Testing

Tests run via:

```
prove -Ilib -j16 -r t/
```

Test layout:

- `t/` — human-authored tests.
- `t/scripts/` — helper scripts invoked by human-authored tests.
- `t/AI/` — AI-generated tests. Mirror whatever subdirectory layout
  `t/` uses (e.g. `t/unit/Row.t` ↔ `t/AI/unit/Row.t`).
- `t/AI/scripts/` — helper scripts invoked by AI-generated tests.
- Tests copied from an `old*/` tree count as human-authored even when
  the copy is done by AI.

The default backend for tests is SQLite via `DBD::SQLite`. For
non-default flavors (Postgres, MySQL, MariaDB, Percona) and ephemeral
test setups, use `DBIx::QuickDB` (via `Test2::Tools::QuickDB`) and
point it at the installations under `~/dbs/` when available. This
project ships no schema of its own — tests stand up whatever schema
they need against an ephemeral database.

It is OK to add throwaway scripts under `agent_scripts/` to verify
in-progress functionality. Anything an agent (human- or AI-driven)
needs as standalone tooling — auditors, finders, stage verification
helpers — lives in `agent_scripts/`. These scripts are not part of
the shipped distribution.

## Style

See `STYLE_GUIDE.md`. Pay particular attention to the `eval`
patterns — agents frequently get them wrong. The checklist at
`STYLE_GUIDE_AGENT_CHECKLIST.md` is the self-audit form of the
guide; walk it before declaring work ready for review.

## Dependency rules

- The default backend is SQLite via `DBD::SQLite`, which is a hard
  requirement. Non-default database drivers (`DBD::Pg`, `DBD::mysql`,
  `DBD::MariaDB`, Percona drivers) are loaded only when the caller
  points the ORM at a matching DSN, so their `DBD::*` modules must be
  Suggests / Recommends in `dist.ini`, not hard requirements.
- Likewise for flavor-specific helpers (e.g. `DateTime::Format::*`
  modules) — required only for the flavor that needs them, so they
  are Suggests / Recommends, not hard requires.

## Commits

- Make a distinct commit for each change.
- Exception: if fixing a bug introduced by a recent commit that has
  not yet been pushed to origin, amend that commit instead of
  creating a new one.

## Changelog

- Every commit that changes shipped behavior must record itself in
  `Changes` in the **same commit**, by adding a bullet under the
  `{{$NEXT}}` section at the top of the file describing the change in
  user-facing terms. Do not defer changelog entries to release time —
  releases have shipped with empty changelogs because entries were
  never written.
- Keep each entry brief: one line, one sentence where possible, two at
  the very most.
- This applies to **all** such commits going forward, whether they land
  directly on the main branch or on a worktree branch that is later
  merged in. When you open a worktree, the work's `Changes` entry lands
  in that branch alongside the code; the merge commit then carries it
  onto the main branch.
- Exempt: changes that ship nothing to users — pure test-only work,
  trivial cleanups (whitespace, typos, formatting), and dev-only tooling
  (`agent_scripts/`, `old*/`, `AI_DOCS/`). Everything else needs an
  entry.

## Worktrees

- Significant work requires a worktree. Place worktrees in
  `worktrees/`.
- Documentation-only work (editing `ARCHITECTURE.md`, `STYLE_GUIDE.md`,
  this file, etc.) does not require a worktree.
- Always integrate a worktree's branch with a merge commit
  (`git merge --no-ff`), never a fast-forward. The merge commit is the
  record that a discrete piece of work landed; preserve it even when the
  target branch has not advanced.

## Architecture quick-reference

The full spec will live in `ARCHITECTURE.md`. Foundational rules an
agent must internalise before writing any code:

- **`Object::HashBase` for objects; `Role::Tiny` for
  roles.** They compose — `HashBase` may be used inside roles and used
  by consumers of roles that use it.
- **`parent` for inheritance, not `base`.**
- **No `DBIx::Class`.** The row layer is hand-written SQL on `DBI`
  (optionally aided by `SQL::Abstract`).
- **`DBD::SQLite` directly for the default backend.** `DBIx::QuickDB`
  is for ephemeral test setups and non-default flavors; never for
  the default SQLite path.
- **The database is canonical.** Schema metadata is introspected from
  the live database; user overrides fill gaps and win on conflict.
- **Old trees are immutable.** Copy out, modify the copy.
