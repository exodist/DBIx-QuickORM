package DBIx::QuickORM::Util::Has::Plugins;
use strict;
use warnings;

use Carp qw/croak confess/;
use Scalar::Util qw/blessed/;

require DBIx::QuickORM::Plugin;

use Importer Importer => 'import';

our @EXPORT = qw/PLUGINS plugins add_plugin ordered_plugins/;

sub PLUGINS() { 'plugins' }

sub apply {
    my $class = shift;
    my ($into, $HAS, $list) = @_;

    if ($into->can('add_pre_init') && $into->can('add_post_init')) {
        $into->add_pre_init(sub {
            my $self = shift;
            $self->{+PLUGINS} //= {__ORDER__ => []};
        });

        $into->add_post_init(sub {
            my $self = shift;
            $_->post_init($self) for $self->ordered_plugins;
        });
    }
    elsif (!$list || !@$list) {
        confess "Consuming class is not built with Object::HashBase, and no import list was specified";
    }

    $list //= \@EXPORT;
    no strict 'refs';
    *{"$into\::$_"} = $class->can($_) for @$list;
}

sub plugins { $_[0]->{+PLUGINS} //= {__ORDER__ => []} }

sub add_plugin {
    my $self = shift;
    my ($plugin) = @_;

    croak "Must provide a plugin" unless $plugin;
    my $class = blessed($plugin) or croak "Plugin must be a blessed instance";
    croak "Plugin must be a subclass of 'DBIx::QuickORM::Plugin', got '$plugin'" unless $plugin->isa('DBIx::QuickORM::Plugin');

    my $plugins = $self->plugins;

    if (my $have = $plugins->{$class}) {
        # Same instance, just return as we already have it
        return if $have == $plugin;

        croak "Already have a plugin of class '$class', cannot add another one";
    }

    $plugins->{$class} = $plugin;
    push @{$plugins->{__ORDER__} //= []} => $plugin;
}

sub ordered_plugins {
    my ($in) = @_;

    my $plugins;
    if (blessed($in) && $in->can('plugins')) {
        $plugins = $in->plugins;
    }
    elsif (ref($in) eq 'HASH') {
        $plugins = $in;
    }
    else {
        confess "Invalid input '$in'";
    }

    return unless keys %$plugins;

    my $order = $plugins->{__ORDER__} or croak "Plugin hash has no order";
    return map { $plugins->{$_} } @$order;
}

1;
