use Test2::V0;

{
    $INC{'My/Plugin.pm'} = __PACKAGE__;
    package My::Plugin;
    use parent 'DBIx::QuickORM::Plugin';

    sub do_post_init {
        my ($self, $obj) = @_;
        $obj->{do_post_init} = $main::order++;
    };

    package My::Test::Base;

    sub init {
        my $self = shift;

        $self->{base}++;
    }

    package My::Test;
    BEGIN { push @My::Test::ISA => 'My::Test::Base' };

    use DBIx::QuickORM::Util::HashBase qw/from_hashbase/;
    use DBIx::QuickORM::Util::Has qw/Plugins Created/;

    add_pre_init {
        my $self = shift;
        $self->{init} = $main::order++;
        $self->{+FROM_HASHBASE}++;
    };

    package My::Test2;
    use DBIx::QuickORM::Util::Has Plugins => [qw/PLUGINS/];
}

$main::order = 1;

my $file = __FILE__;
my $line = 1 + __LINE__;
my $it = My::Test->new();

can_ok(
    $it,
    [qw{
        PLUGINS plugins
        CREATED created gen_created
    }],
    "Added the necessary methods"
);

is($it->from_hashbase, 1, "Called the regularly added init");
is($it->{base}, 1, "Called init from base class");

isa_ok($it->{$it->PLUGINS}, ['DBIx::QuickORM::PluginSet'], "Got a pluginset");
is($it->{$it->CREATED}, "$file line $line", "Got the created string via constant");

isa_ok($it->plugins, ['DBIx::QuickORM::PluginSet'], "Got a pluginset");
is($it->created, "$file line $line", "Got the created string via method");

$main::order = 1;
my $it2 = My::Test->new(plugins => ['+My::Plugin']);
is($it2->{init}, 1, "init ran first");
is($it2->{do_post_init}, 2, "post_init ran last");

sub {
    my $line = __LINE__ + 1;
    my $it3 = My::Test->new();
    is($it3->created, "$file line $line", "Did not go too deep");
}->();

can_ok('My::Test2', [qw/PLUGINS/], "Imported requested subs");
ok(!My::Test2->can('plugins'), "Did not import 'plugins'");

done_testing;
