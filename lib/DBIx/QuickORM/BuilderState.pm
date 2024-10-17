package DBIx::QuickORM::BuilderState;
use strict;
use warnings;

use Carp qw/croak confess/;
use Scalar::Util qw/blessed weaken/;
use DBIx::QuickORM::Util qw/mesh_accessors update_subname/;

use Importer Importer => 'import';

$Carp::Internal{(__PACKAGE__)}++;

our (@EXPORT, %CONST);

BEGIN {
    %CONST = (
        ACCESSORS        => 'ACCESSORS',
        COLUMN           => 'COLUMN',
        COLUMNS          => 'COLUMN',
        CONFLATOR        => 'CONFLATOR',
        DB               => 'DB',
        DEFAULT_BASE_ROW => 'DEFAULT_BASE_ROW',
        ORM              => 'ORM',
        RELATION         => 'RELATION',
        SCHEMA           => 'SCHEMA',
        SOURCES          => 'SOURCES',
        TABLE            => 'TABLE',
    );

    my %seen;
    @EXPORT = grep { !$seen{$_}++ } (
        keys(%CONST),
        qw{
            column_order
            build
            build_clean_builder
            build_meta_state
            build_state
            build_top_builder
        },
    );

    require constant;
    constant->import(\%CONST);
}

my @STACK;
my $COL_ORDER = 1;

sub column_order { $COL_ORDER++ }

sub build_meta_state {
    return undef unless @STACK;
    my $top = $STACK[-1];
    return $top unless @_;
    return $top->{$_[0]} // $_[1] if @_ > 1;
    return $top->{$_[0]};
}

sub build_state {
    return undef unless @STACK;
    my $state = $STACK[-1]->{state};
    return $state unless @_;
    return $state->{$_[0]} //= $_[1] if @_ > 1;
    return $state->{$_[0]};
}

sub build {
    my %params = @_;

    my $state    = $params{state}    // (@STACK ? {%{$STACK[-1]}} : {});
    my $building = $params{building} or confess "'building' is a required parameter";
    my $callback = $params{callback} or confess "'callback' is a required parameter";

    my $caller   = $params{caller} // [caller(1)];
    my $args     = $params{args}   // [];

    if (my $tstate = build_state) {
        croak "New state cannot be the same ref as the current state" if $state == $tstate;
    }

    $state->{+ACCESSORS} = mesh_accessors($state->{+ACCESSORS}) if $state->{+ACCESSORS};

    push @STACK => \%params;

    my $out;
    my $ok  = eval { $out = $callback->(%params); 1 };
    my $err = $@;

    pop @STACK;

    die $err unless $ok;

    return $out;
}

sub build_top_builder {
    my ($name, $buildsub) = @_;

    croak "A 'name' is required" unless $name;

    my $sub = sub {
        build(
            building  => $name,
            callback  => $buildsub,
            args      => \@_,
            caller    => [caller()],
            state     => @STACK ? {%{$STACK[-1]->{state}}} : {},
            wantarray => wantarray,
        );
    };

    return update_subname $name => $sub if defined wantarray;

    my $caller  = caller;
    my $subname = "$caller\::$name";
    no strict 'refs';
    *{$subname} = update_subname $subname => $sub;
}

sub build_clean_builder {
    my ($name, $buildsub) = @_;

    my $sub = sub {
        build(
            building  => $name,
            callback  => $buildsub,
            args      => \@_,
            caller    => [caller()],
            state     => {},
            wantarray => wantarray,
        );
    };

    return update_subname $name => $sub if defined wantarray;

    my $caller = caller;
    my $subname = "$caller\::$name";
    no strict 'refs';
    *{$subname} = update_subname $subname => $sub;
}

1;
