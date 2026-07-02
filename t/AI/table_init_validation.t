use Test2::V0;

# Regression: Schema::Table->new with a scalar primary_key used to die with a
# raw "@$pk" dereference; it now croaks with a clear message.

require DBIx::QuickORM::Schema::Table;
require DBIx::QuickORM::Schema::Table::Column;

my $C = 'DBIx::QuickORM::Schema::Table::Column';
sub col { $C->new(name => $_[0], order => $_[1], affinity => 'numeric') }

like(
    dies {
        DBIx::QuickORM::Schema::Table->new(
            name        => 't',
            columns     => {id => col('id', 1)},
            primary_key => 'id',    # scalar, not an arrayref
        );
    },
    qr/primary_key.*must be an arrayref/,
    "a scalar primary_key croaks cleanly instead of dereferencing a non-arrayref",
);

ok(
    lives {
        DBIx::QuickORM::Schema::Table->new(
            name        => 't',
            columns     => {id => col('id', 1)},
            primary_key => ['id'],
        );
    },
    "an arrayref primary_key still works",
);

done_testing;
