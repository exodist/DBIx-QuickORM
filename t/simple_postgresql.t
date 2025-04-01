use Test2::V0 -target => 'DBIx::QuickORM', '!meta', '!pass';
use DBIx::QuickORM;
use Carp::Always;

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

    autofill sub {
        autotype 'UUID';
        autotype 'JSON';
        autoskip column => qw/simple skip/;
        autoskip table => 'simple2';
    };
};

my $orm = orm('myorm');
debug($orm->connection);


__END__
my $con = $orm->connection;
diag "Using dialect '" . $con->dialect->dialect_name . "'";

my $schema = $con->schema;

my $s = $orm->source('simple');

my $uuid = DBIx::QuickORM::Type::UUID->new;
my $uuid2 = DBIx::QuickORM::Type::UUID->new;
my $one = $s->insert({name => 'x', uuid => $uuid});

#debug([$one]);
$one->field(uuid => $uuid2);
$one->save;
#debug([$one, $one->field('my_uuid')]);

my $x = $s->search({uuid => $uuid2})->one;
#debug([$x]);

done_testing;
