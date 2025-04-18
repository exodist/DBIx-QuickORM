package DBIx::QuickORM::Role::Query;
use strict;
use warnings;

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

sub SQLA_SOURCE() { 'sqla_source' }
sub ROW()         { 'row' }
sub WHERE ()      { 'where' }
sub ORDER_BY ()   { 'order_by' }
sub LIMIT ()      { 'limit' }
sub FIELDS ()     { 'fields' }
sub OMIT ()       { 'omit' }
sub ASYNC ()      { 'async' }
sub ASIDE ()      { 'aside' }
sub FORKED ()     { 'forked' }

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    SQLA_SOURCE
    WHERE
    ORDER_BY
    LIMIT
    FIELDS
    OMIT
    ASYNC
    ASIDE
    FORKED
    ROW
};

use Role::Tiny;

requires qw{
    SQLA_SOURCE
    WHERE
    ORDER_BY
    LIMIT
    FIELDS
    OMIT
    ASYNC
    ASIDE
    FORKED
};

sub normalize_query {
    my $self = shift;
    croak "async, aside, and forked are exclusive options, only one may be selected" if 1 < grep { $_ } @{$self}{ASYNC(), ASIDE(), FORKED()};

    my $sqla_source = $self->{+SQLA_SOURCE} or croak "No sqla_source provided";

    my $row = $self->{+ROW};
    croak "Invalid row: $row" if $row && !$row->isa('DBIx::QuickORM::Row');

    my $where  = $self->{+WHERE}  //= $row ? $row->primary_key_hashref : {};

    my $fields = $self->{+FIELDS} //= $sqla_source->fields_to_fetch;

    my $omit = $self->{+OMIT} or return;

    croak "Cannot mix 'omit' and a non-arrayref field specification ('$fields')" if ref($fields) ne 'ARRAY';

    my $pk_fields = $sqla_source->primary_key;
    $omit = $self->_normalize_omit($self->{+OMIT}, $pk_fields) or return;

    if ($pk_fields || $omit) {
        my %seen;
        $fields = [grep { !$seen{$_}++ && !($omit && $omit->{$_}) } @{$pk_fields // []}, @$fields];
    }

    $self->{+FIELDS} = $fields;

    if ($omit) { $self->{+OMIT} = $omit }
    else       { delete $self->{+OMIT} }
}

sub _normalize_omit {
    my $self = shift;
    my ($omit, $pk_fields) = @_;

    return undef unless defined $omit;

    my $r = ref($omit);
    #<<<
    if    ($r eq 'HASH')  {                                           } # Do nothing
    elsif ($r eq 'ARRAY') { $omit = map { ($_ => 1) } @$omit          } # Turn list into hash
    elsif (!$r)           { $omit =    {$omit => 1}                   } # Turn single into hash
    else                  { croak "$omit is not a valid 'omit' value" } # oops
    #>>>

    $pk_fields //= $self->{+SQLA_SOURCE}->primary_key or return $omit;

    for my $field (@$pk_fields) {
        next unless $omit->{$field};
        croak "Cannot omit primary key field '$field'";
    }

    return $omit;
}

sub clone {
    my $self = shift;
    my (%override) = @_;

    my $type = blessed($self);

    return $type->new(%$self, %override);
}

sub query_pairs {
    my $self = shift;

    return (
        SQLA_SOURCE() => $self->{+SQLA_SOURCE},
        WHERE()       => $self->{+WHERE},
        ORDER_BY()    => $self->{+ORDER_BY},
        LIMIT()       => $self->{+LIMIT},
        FIELDS()      => $self->{+FIELDS},
        OMIT()        => $self->{+OMIT},
        ASYNC()       => $self->{+ASYNC},
        ASIDE()       => $self->{+ASIDE},
        FORKED()      => $self->{+FORKED},
        ROW()         => $self->{+ROW},
    );
}

1;
