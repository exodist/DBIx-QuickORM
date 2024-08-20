use Test2::V0;

{
    package My::Plugin;

    BEGIN {
        require DBIx::QuickORM::Plugin;
        push @My::Test::ISA => 'DBIx::QuickORM::Plugin';
    };

    sub new { bless({}, shift) }

    sub post_init {
        my ($self, $obj) = @_;
        $obj->{post_init} = $main::order++;
    }

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
    use DBIx::QuickORM::Util::Has Plugins => [qw/PLUGINS ordered_plugins/];
}

$main::order = 1;

my $file = __FILE__;
my $line = 1 + __LINE__;
my $it = My::Test->new();

can_ok(
    $it,
    [qw{
        PLUGINS plugins ordered_plugins add_plugin
        CREATED created gen_created
    }],
    "Added the necessary methods"
);

is($it->from_hashbase, 1, "Called the regularly added init");
is($it->{base}, 1, "Called init from base class");

is($it->{$it->PLUGINS}, {__ORDER__ => []}, "Got the plugins hash with order key via constant");
is($it->{$it->CREATED}, "$file line $line", "Got the created string via constant");

is($it->plugins, {__ORDER__ => []}, "Got the plugins hash with order key via method");
is($it->created, "$file line $line", "Got the created string via method");

$main::order = 1;
my $it2 = My::Test->new(plugins => {__ORDER__ => ['My::Plugin'], 'My::Plugin' => My::Plugin->new()});
is($it2->{init}, 1, "init ran first");
is($it2->{post_init}, 2, "post_init ran last");

sub {
    my $line = __LINE__ + 1;
    my $it3 = My::Test->new();
    is($it3->created, "$file line $line", "Did not go too deep");
}->();

can_ok('My::Test2', [qw/PLUGINS ordered_plugins/], "Imported requested subs");
ok(!My::Test2->can('plugins'), "Did not import 'plugins'");
ok(!My::Test2->can('add_plugin'), "Did not import 'add_plugin'");

done_testing;
