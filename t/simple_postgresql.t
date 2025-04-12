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

    autofill sub {
        autotype 'UUID';
        autotype 'JSON';
        autoskip column => qw/simple skip/;
        autoskip table => 'simple2';
    };
};

my $orm = orm('myorm')->connection;

ok(my $row = $orm->source('simple')->insert({name => 'a'}), "Inserted a row");
debug($row);
my $rowc = $orm->source('simple')->select({name => 'a'})->one;
my $rowd = $orm->source('simple')->one({name => 'a'});
ref_is($rowc, $row, "Got cached copy of row");
use Carp::Always;

ok(my $row2 = $orm->source('simple')->insert({name => 'b', data => {foo => 'bar'}}), "Inserted a row");
debug($row2);

$orm->insert('simple' => {name => 'c'});

debug($orm->source('simple')->all({}));

done_testing;

#    my $addr = "$row";
#    $row = undef;
#    $row = $orm->source('example')->one({name => 'a'});
#    ok($row, "got row");
#    isnt("$row", $addr, "uncached copy");
#    ok(!exists($row->{stored}->{data}), "did not fetch data");
#
#    $row = undef;
#
#    $row = $orm->source('example')->one({name => 'a'}, omit => {'name' => 1});
#    ok(!exists($row->{stored}->{name}), "Did not fetch name");


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
