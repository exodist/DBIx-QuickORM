package DBIx::QuickORM::Source::Join;
use strict;
use warnings;

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::Util::HashBase qw{
    <type
    <as

    <table
    <using
    <on
};

use DBIx::QuickORM::Util::Has qw/Plugins Created/;

sub init {
    my $self = shift;

    my $tab = $self->{+TABLE} or croak "'table' is a required attribute";

    croak "'table' must be an instance of 'DBIx::QuickORM::Table'"
        unless blessed($tab) && $tab->isa('DBIx::QuickORM::Table');

    croak "Cannot provide both 'on' and 'using' attributes"
        if $self->{+ON} && $self->{+USING};

    if (my $using = $self->{+USING}) {
        croak "The 'using' attribute may not be a reference" if ref $using;
    }
    elsif (my $on = $self->{+ON}) {
        croak "The 'on' attribute must be a hash reference" unless ref($on) == 'HASH';
    }
    else {
        croak "Must provide either an 'on', or 'using' attribute when providing a table";
    }

    $self->{+AS} //= $tab->as;
}

1;

__END__

$orm->source('TABLE')->join('table', on => FIELD)->xxx_join('table', using => {})->select(...);
