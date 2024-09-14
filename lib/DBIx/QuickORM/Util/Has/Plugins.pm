package DBIx::QuickORM::Util::Has::Plugins;
use strict;
use warnings;

use Carp qw/croak confess/;
use Scalar::Util qw/blessed/;

require DBIx::QuickORM::Plugin;
require DBIx::QuickORM::PluginSet;

use Importer Importer => 'import';

our @EXPORT = qw/PLUGINS plugins/;

sub PLUGINS() { 'plugins' }

sub apply {
    my $class = shift;
    my ($into, $HAS, $list) = @_;

    if ($into->can('add_pre_init') && $into->can('add_post_init')) {
        $into->add_pre_init(sub {
            my $self = shift;

            my $plugins = delete $self->{+PLUGINS};
            if (blessed($plugins) && $plugins->isa('DBIx::QuickORM::PluginSet')) {
                $self->{+PLUGINS} = $plugins;
            }
            elsif($plugins) {
                my $set = DBIx::QuickORM::PluginSet->new;
                croak "'plugins' must me an arrayref or an instance of 'DBIx::QuickORM::PluginSet' got '$plugins'" unless ref($plugins) eq 'ARRAY';
                $set->push_plugin($_) for @$plugins;
                $self->{+PLUGINS} = $set;
            }
        });

        $into->add_post_init(sub {
            my $self = shift;
            $_->do_post_init($self) for @{$self->plugins->all};
        });
    }
    elsif (!$list || !@$list) {
        confess "Consuming class is not built with Object::HashBase, and no import list was specified";
    }

    $list //= \@EXPORT;
    no strict 'refs';
    *{"$into\::$_"} = $class->can($_) for @$list;
}

sub plugins { $_[0]->{+PLUGINS} //= DBIx::QuickORM::PluginSet->new }

1;
