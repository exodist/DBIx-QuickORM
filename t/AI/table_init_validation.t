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

subtest deterministic_field_order => sub {
    # Column order slots are deliberately out of both hash and alphabetical
    # order so the assertion can only pass if the field lists sort by order.
    my $t = DBIx::QuickORM::Schema::Table->new(
        name    => 't',
        columns => {
            zeta  => col('zeta',  1),
            alpha => col('alpha', 2),
            mid   => col('mid',   3),
            beta  => col('beta',  4),
        },
        primary_key => ['zeta'],
    );

    is($t->fields_list_all, ['zeta', 'alpha', 'mid', 'beta'], "fields_list_all follows column order, not hash/name order");
    is($t->fields_to_fetch, ['zeta', 'alpha', 'mid', 'beta'], "fields_to_fetch follows column order");
};

done_testing;
