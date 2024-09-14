package DBIx::QuickORM::PluginSet;
use strict;
use warnings;

use Carp qw/croak/;
use List::Util qw/uniq/;
use Scalar::Util qw/blessed/;
use DBIx::QuickORM::Util qw/mod2file/;

use DBIx::QuickORM::Util::HashBase qw{
    +parent
    +before_parent
    +after_parent
    +plugins
};

sub init {
    my $self = shift;

    $self->{+BEFORE_PARENT} //= [];
    $self->{+PLUGINS}       //= {};
    $self->{+AFTER_PARENT}  //= [];
}

sub order {
    my $self = shift;

    my @order;
    push @order => @{$self->{+BEFORE_PARENT} // []};
    push @order => @{$self->{+PARENT}->order // []} if $self->{+PARENT};
    push @order => @{$self->{+AFTER_PARENT}  // []};
    return [uniq(@order)];
}

sub all {
    my $self = shift;

    my %plugins;

    my @todo = ($self);
    while (my $me = shift @todo) {
        push @todo => $me->{+PARENT} if $me->{+PARENT};
        %plugins = (%{$me->{+PLUGINS}}, %plugins);
    }

    my @out;
    for my $name (@{$self->order}) {
        my $inst = $plugins{$name} or croak "Plugin '$name' is in the ordered list, but there is no instance!";
        push @out => $inst;
    }

    return \@out;
}

sub has_plugin {
    my $self = shift;
    my ($class) = @_;

    return $self->{+PLUGINS}->{$class} if $self->{+PLUGINS}->{$class};
    return $self->{+PARENT}->get_plugin($class) if $self->{+PARENT};
    return undef;
}

sub get_plugin {
    my $self = shift;
    my ($class) = @_;

    my $plugin = $self->has_plugin($class) or croak "Plugin '$class' is not in this plugin set";
    return $plugin;
}

sub push_plugin {
    my $self = shift;
    my ($class, $inst) = $self->_add_plugin(@_);
    push @{$self->{+AFTER_PARENT}} => $class;
    return $inst;
}

sub unshift_plugin {
    my $self = shift;
    my ($class, $inst) = $self->_add_plugin(@_);
    push @{$self->{+BEFORE_PARENT}} => $class;
    return $inst;
}

sub _add_plugin {
    my $self = shift;
    my ($plugin, %params) = @_;

    my ($class, $inst);

    if ($class = blessed($plugin)) {
        croak "'$plugin' is not an instance of 'DBIx::QuickORM::Plugin' or a subclass of it" unless $plugin->isa('DBIx::QuickORM::Plugin');
        $inst = $plugin;
    }
    else {
        $class = "DBIx::QuickORM::Plugin::$plugin" unless $plugin =~ s/^\+// || $plugin =~ m/^DBIx::QuickORM::Plugin::/;
        $class //= $plugin;
        eval { require(mod2file($class)); 1 } or croak "Could not load plugin '$plugin' ($class): $@";
        croak "Plugin '$plugin' ($class) is not a subclass of 'DBIx::QuickORM::Plugin'" unless $class->isa('DBIx::QuickORM::Plugin');
    }

    # Ok to override a parents, but not our own
    croak "This instance already has a '$class' plugin" if $self->{+PLUGINS}->{$class};

    $self->{+PLUGINS}->{$class} = $inst // $class->new(%params);

    return ($class, $inst);
}

1;
