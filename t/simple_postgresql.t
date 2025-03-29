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

debug($s->all);

my $s2 = $con->select(simple => { name => 'bar' });
debug($s2->all);


done_testing;
