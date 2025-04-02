use Test2::V0 -target => 'DBIx::QuickORM', '!meta', '!pass';
use DBIx::QuickORM;

use lib 't/lib';
use DBIx::QuickORM::Test;
use Hash::Merge qw/merge/;
Hash::Merge::set_behavior('RIGHT_PRECEDENT');

do_for_all_dbs {
    my $db = shift;

    db mydb => sub {
        dialect curdialect();
        db_name 'quickdb';
        connect sub { $db->connect };
    };

    orm my_orm => sub {
        db 'mydb';
        autofill sub {
            autotype 'UUID';
        };
    };

    my $uuid = DBIx::QuickORM::Type::UUID->new;
    ok(my $orm = orm('my_orm')->connect, "Got a connection");
    ok(my $row = $orm->source('example')->insert({name => 'a', uuid => $uuid}), "Inserted a row");
    is($row->{stored}->{uuid}, DBIx::QuickORM::Type::UUID::qorm_deflate($uuid, 'binary'), "Stored as binary");
    isnt($row->{stored}->{uuid}, $uuid, "Sanity check that original uuid and binary do not match");
    is($row->field('uuid'), $uuid, "Round trip returned the original UUID, no loss");
};

done_testing;

