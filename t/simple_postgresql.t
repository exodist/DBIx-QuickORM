use Test2::V0 -target => 'DBIx::QuickORM', '!meta', '!pass';
use DBIx::QuickORM;

use Test2::Tools::QuickDB;
skipall_unless_can_db(driver => 'PostgreSQL');

use lib 't/lib';
use DBIx::QuickORM::Test;

my $psql_file = __FILE__;
$psql_file =~ s/\.t/.sql/;
my $psql = psql(load_sql => [quickdb => $psql_file]);

db mydb => sub {
    dialect 'PostgreSQL';
    db_name 'quickdb';
    connect sub { $psql->connect };
};

orm myorm => sub {
    db 'mydb';
    autofill;
};

my $con = orm('myorm')->connect;
diag "Using dialect '" . $con->dialect->dialect_name . "'";

my $schema = $con->schema;

my $s = $con->source('simple');

$s->insert(name => 'foo');
$s->insert(name => 'bar');
$s->insert(name => 'baz');

require DBIx::QuickORM::Type::UUID;
my $uuid = DBIx::QuickORM::Type::UUID->new;
my $r = DBIx::QuickORM::Row->new(
    pending     => {name => 'bob', uuid => $uuid, uuid_b => $uuid},
    sqla_source => $s->sqla_source,
    connection  => $con,
);

debug([$r]);
$r->insert;
debug([$r]);
debug(DBIx::QuickORM::Type::UUID->new(binary => $r->field('uuid_b'))->string);


done_testing;
