# Flagged fix: Link::parse scalar-ref source lookup is broken

Status: open / needs a design decision. Found during the AI test-coverage
pass (branch `ai-test-coverage`, `t/AI/link.t`). Recorded here because the fix
is larger than an obvious one-liner.

## What is broken

`DBIx::QuickORM::Link::parse` has a branch for a scalar-ref spec that is meant
to look a link up from a source by table name:

```perl
if (ref($link) eq 'SCALAR') {
    ... $source->links($$link) ...
}
```

It calls `$source->links($table_name)` expecting a source to return the links
*for that table*. No source implements that:

- `Schema::Table` / `Schema::View` expose the bare `Object::HashBase` reader
  `links` (a 0-arg accessor returning the arrayref). Passing an argument
  croaks: `Usage: ...::links(self)`.
- `Join::links` exists but ignores its argument (returns all links).

So `Link->parse($source, \'table_name')` and, through it,
`Role::Linked::resolve_link(\'table_name')` die for every real source.

## Impact

Low in practice: the common `resolve_link` paths (by alias, by table name as a
plain string, by columns, by an existing `Link` object) all work and are now
covered by `t/AI/link.t`. The scalar-ref-to-source form appears unused by the
current codebase. But it is a latent dead/broken branch that will die if any
caller uses it, and the intent (filter a source's links by table name) is not
expressible against the current source interface.

## Options

1. **Define a filtering `links($name)` on sources.** Add an optional
   table-name argument to `Schema::Table::links` (and make `Join::links`
   honor it), returning only links whose `other_table` matches. Then
   `parse`'s scalar-ref branch works as intended. Touches the `Role::Source`
   contract and every source.

2. **Filter in `parse` itself.** Leave sources alone; have `parse` call the
   0-arg `links` and grep for `other_table eq $$link` (and/or alias match).
   Smaller blast radius, keeps the filtering logic in one place, but `parse`
   then has to know how to read a source's link list.

3. **Drop the scalar-ref branch.** If the form is genuinely unused, remove it
   and document that a link spec is a name/alias/columns/hashref/Link object.
   Smallest change; loses a (currently non-functional) affordance.

## Recommendation

Option 2 (filter in `parse`) if the scalar-ref form should keep working, since
it does not disturb the source interface; otherwise Option 3. Either is a
deliberate API decision, hence flagged rather than fixed.

## Test state

`t/AI/link.t` asserts the working no-source croak and wraps the broken
positive path in a `todo` block (with a comment pointing here), so the suite
stays green and the bug is recorded.
