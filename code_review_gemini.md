# Code Review: column-aliasing branch

## Overview
This branch implements the ability for ORM-facing column names to differ from their database names. The design follows the principle that the ORM name is canonical for the user and in-memory storage, while the database name is used only at the SQL boundary.

## Major Components

### 1. Schema Metadata (`Table.pm`, `Column.pm`)
- `Column` objects now have a `db_name` attribute.
- `Table` objects maintain a `db_to_orm` mapping and a `has_aliases` flag.
- `Table->merge` has been updated to reconcile columns by `db_name`, which is essential for matching user-defined aliased columns with introspected database columns.
- **Validation:** `Table->init` ensures that `db_name` is unique within a table.

### 2. SQL Translation (`SQLAbstract.pm`)
- The SQL builder now recursively walks `where` and `order_by` clauses to translate ORM names to DB names.
- Data hashes for `insert` and `update` have their keys translated.
- Field lists and `RETURNING` clauses are also translated.
- **Observation:** Literal SQL (scalar refs) is correctly exempted from translation.

### 3. Result Remapping (`Role/SQLBuilder.pm`, `Handle.pm`, `RowManager.pm`)
- DB-keyed result hashes are remapped back to ORM-keyed hashes.
- This happens in `Handle.pm` for `select` results and in `RowManager.pm` during row vivification.
- The remapping logic is idempotent, ensuring that data already using ORM names is not corrupted.

### 4. Joins (`Join.pm`, `Join/Row.pm`)
- **Note:** The design doc suggested a "croak-guard" for joins, but this branch provides a full implementation.
- `Join` handles `alias.field` protos, translating them to `alias.db_field` for SQL and back to `alias.orm_field` for results.
- `Join::Row` leverages `fracture` to split flat join results into per-component rows, which are then individually remapped.

### 5. Documentation and Tests
- New manual page: `lib/DBIx/QuickORM/Manual/Aliasing.pm`.
- Architecture updated: `ARCHITECTURE.md`.
- Comprehensive tests added: `t/remap_join.t`, `t/remap_merge.t`, `t/remap_sql.t`.
- Existing test `t/remap.t` un-skipped and passing.

## Observations & Recommendations

- **Name Overlap:** There is no explicit check for collisions between a column's `db_name` and another column's `name` (ORM name). While the lookup priority (ORM name first) makes this predictable, it might be worth adding a warning or check if such an overlap is detected during `Table->init`.
- **Join Implementation:** The full implementation of joins is a significant improvement over the planned "croak-guard".
- **Short-circuiting:** The use of `source_has_aliases` to skip translation logic when not needed is a good performance optimization.
- **Consistency:** The implementation is very consistent with the existing architectural patterns of the project (e.g., using `HashBase`, `Role::Tiny`, and idempotent lookups).

## Conclusion
The `column-aliasing` branch appears to be well-implemented, thoroughly tested, and documented. It fulfills the requirements of the design doc and goes beyond by supporting joins.
