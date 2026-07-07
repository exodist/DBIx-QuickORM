use Test2::V0 '!meta', '!pass';
use lib 't/lib';

# A PostgreSQL enum is a user-defined type: information_schema reports the column
# as data_type 'USER-DEFINED' with the enum's name as udt_name, and the generic
# driver type catalog does not list it. The dialect resolves such types from
# pg_type (enum -> string affinity) so introspection does not fall through to the
# "unrecognized type" warning.

BEGIN {
    skip_all "DBD::Pg is required for these tests"
        unless eval { require DBD::Pg; 1 };
}

use DBIx::QuickORM::Test qw/psql/;

my $db = psql() or skip_all "Could not provision a PostgreSQL database";

{
    my $dbh = $db->connect('quickdb', RaiseError => 1, PrintError => 0, AutoCommit => 1);
    $dbh->do("CREATE TYPE color AS ENUM ('red','green','blue')");
    $dbh->do("CREATE DOMAIN positive_int AS INTEGER");
    $dbh->do(<<'    EOT');
        CREATE TABLE swatches (
            id    SERIAL PRIMARY KEY,
            shade color        NOT NULL DEFAULT 'red',
            rank  positive_int,
            label TEXT
        )
    EOT
    $dbh->disconnect;
}

require DBIx::QuickORM;

my @warnings;
my $con;
{
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    $con = DBIx::QuickORM->quick(
        connect => sub { $db->connect('quickdb', RaiseError => 1, PrintError => 0, AutoCommit => 1) },
    );
    # Force introspection while the warning trap is in place.
    $con->schema;
}

my $swatches = $con->schema->table('swatches');

is($swatches->column('shade')->affinity, 'string',  "enum column resolves to string affinity");
is(${$swatches->column('shade')->type},  'color',   "enum column keeps its database type name");
is($swatches->column('rank')->affinity,  'numeric', "domain-over-integer column resolves to numeric affinity");
is($swatches->column('label')->affinity, 'string',  "plain text column resolves to string affinity");

my @type_warnings = grep { /does not recognize the database type/ } @warnings;
is(\@type_warnings, [], "no unrecognized-type warning for a resolvable enum/domain")
    or diag("unexpected warnings: @type_warnings");

done_testing;
