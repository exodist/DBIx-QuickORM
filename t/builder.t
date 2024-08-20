use Test2::V0;

use DBIx::QuickORM;

imported_ok qw{
    attributes autofill column_class column columns conflate connect db
    db_class db_name default dsn host include index member member_class
    meta_table mixer omit password plugin port primary_key orm relation
    relation_class row_base_class schema socket sql_spec table table_class
    source_class unique user
};

mixer mymix => sub {
    
};

ok(mymix(), "Added mymix");
isa_ok(mymix(), ['DBIx::QuickORM::Mixer'], "Mixer is the rite type of object");

done_testing;
