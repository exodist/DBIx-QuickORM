use Test2::V0;

# Autofill hook behavior, exercised directly through Autofill->hook.

use DBIx::QuickORM::Schema::Autofill;

subtest tables_hook => sub {
    ok(DBIx::QuickORM::Schema::Autofill->new->is_valid_hook('tables'), "'tables' is a registered hook");

    my %seen;
    my $autofill = DBIx::QuickORM::Schema::Autofill->new(
        hooks => {
            tables => [
                sub {
                    my %p = @_;
                    %seen = %p;
                    return $p{tables};
                },
            ],
        },
    );

    my $tables = {foo => {name => 'foo'}, bar => {name => 'bar'}};
    $autofill->hook(tables => {tables => $tables});

    ref_is($seen{tables}, $tables, "callback received the tables hashref under the 'tables' key");
    ref_is($seen{autofill}, $autofill, "callback received the autofill object");
};

done_testing;
