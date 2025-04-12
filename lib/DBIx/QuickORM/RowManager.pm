package DBIx::QuickORM::RowManager;
use strict;
use warnings;

use Carp qw/confess croak/;
use Scalar::Util qw/weaken/;
use DBIx::QuickORM::Util qw/load_class/;

use DBIx::QuickORM::Affinity();

use DBIx::QuickORM::Connection::RowData qw{
    STORED
    PENDING
    DESYNC
    TRANSACTION
    ROW_DATA
};

use DBIx::QuickORM::Util::HashBase qw{
    transactions
    connection
};

sub init {
    my $self = shift;

    my $con = $self->{+CONNECTION} or croak "Connection was not provided";
    $self->{+TRANSACTIONS} //= $con->transactions;

    weaken($self->{+CONNECTION});
}

sub does_cache { 0 }

sub cache   { }
sub uncache { }

sub cache_lookup {
    my $self = shift;
    return $self->do_lookup($self->parse_params({@_}));
}

sub do_cache_lookup {
    my $self = shift;
    my ($sqla_source, $fetched, $old_pk, $new_pk, $row) = @_;
    return undef;
}

sub invalidate {
    my $self = shift;
    my ($sqla_source, $fetched, $old_pk, $new_pk, $row) = $self->parse_params({@_});

    # Remove from passed in row if we got one
    $row->{row_data}->invalidate if $row;

    # Now check cache for row, might be same, might not
    $row = $self->uncache($sqla_source, $row, $old_pk, $new_pk);
    $row->{row_data}->invalidate if $row;

    return;
}

sub _state {
    my $self = shift;
    my %params = @_;

    $params{+TRANSACTION} //= $self->{+TRANSACTIONS}->[-1] if @{$self->{+TRANSACTIONS}};

    return \%params;
}

sub _vivify {
    my $self = shift;
    my ($sqla_source, $state) = @_;
    my $connection = $self->{+CONNECTION};
    my $row_class = load_class($sqla_source->row_class // $connection->schema->row_class // 'DBIx::QuickORM::Row') or die $@;
    my $row_data = DBIx::QuickORM::Connection::RowData->new(stack => [$state], connection => $connection, sqla_source => $sqla_source);
    return $row_class->new(row_data => $row_data);
}

sub vivify {
    my $self = shift;
    my ($sqla_source, $fetched, $old_pk, $new_pk, $row) = $self->parse_params({@_}, row => 1);
    return $self->_vivify($sqla_source, $self->_state(pending => $fetched));
}

sub insert {
    my $self = shift;
    my ($sqla_source, $fetched, $old_pk, $new_pk, $row) = $self->parse_params({@_}, row => 1);

    $row = $self->do_insert($sqla_source, $fetched, $old_pk, $new_pk, $row);
    $self->cache($sqla_source, $row, $old_pk, $new_pk);

    return $row;
}

sub do_insert {
    my $self = shift;
    my ($sqla_source, $fetched, $old_pk, $new_pk, $row) = @_;

    my $state = $self->_state(stored => $fetched);

    $row->{row_data}->change_state($state) if $row;

    return $row // $self->_vivify($sqla_source, $state);
}

sub update {
    my $self = shift;
    my ($sqla_source, $fetched, $old_pk, $new_pk, $row) = $self->parse_params({@_});

    $row = $self->do_update($sqla_source, $fetched, $old_pk, $new_pk, $row);
    $self->cache($sqla_source, $row, $old_pk, $new_pk);

    return $row;
}

sub do_update {
    my $self = shift;
    my ($sqla_source, $fetched, $old_pk, $new_pk, $row) = @_;

    my $state = $self->_state(stored => $fetched, pending => undef, desync => undef);

    return $self->_vivify($sqla_source, $state)
        unless $row;

    $row->{row_data}->change_state($state);

    return $row;
}

sub delete {
    my $self = shift;
    my ($sqla_source, $fetched, $old_pk, $new_pk, $row) = $self->parse_params({@_}, fetched => 1);

    $row = $self->do_delete($sqla_source, $fetched, $old_pk, $new_pk, $row);
    $self->uncache($sqla_source, $row, $old_pk, $new_pk);

    return $row;
}

sub do_delete {
    my $self = shift;
    my ($sqla_source, $fetched, $old_pk, $new_pk, $row) = @_;

    $row->{row_data}->change_state($self->_state(stored => undef));

    return $row;
}

sub select {
    my $self = shift;
    my ($sqla_source, $fetched, $old_pk, $new_pk, $row) = $self->parse_params({@_});

    $row = $self->do_select($sqla_source, $fetched, $old_pk, $new_pk, $row);
    $self->cache($sqla_source, $row, $old_pk, $new_pk);

    return $row;
}

sub do_select {
    my $self = shift;
    my ($sqla_source, $fetched, $old_pk, $new_pk, $row) = @_;

    my $state = $self->_state(stored => $fetched);

    # No existing row, make a new one
    return $self->_vivify($sqla_source, $state)
        unless $row;

    $row->{row_data}->change_state($state);

    return $row;
}

sub parse_params {
    my $self = shift;
    my ($params, %skip) = @_;

    my $sqla_source = $params->{sqla_source} or confess "'source' is a required parameter";
    confess "'$sqla_source' is not a valid SQLA Source" unless $sqla_source->DOES('DBIx::QuickORM::Role::SQLASource');

    my $new_pk = $params->{new_primary_key};

    my $fetched = $params->{fetched};
    unless ($skip{fetched}) {
        my @pk_vals;
        confess "'fetched' is a required parameter" unless $fetched;
        confess "'$fetched' is not a valid fetched data set" unless ref($fetched) eq 'HASH';
        if (my $pk_fields = $sqla_source->primary_key) {
            my @bad;
            for my $field (@$pk_fields) {
                if (exists $fetched->{$field}) {
                    push @pk_vals => $fetched->{$field};
                }
                else {
                    push @bad => $field;
                }
            }

            confess "The following primary key fields are missing from the fetched data: " . join(', ' => sort @bad) if @bad;

            $new_pk //= \@pk_vals;
        }
    }

    my $old_pk = $params->{old_primary_key};

    my $row;
    unless ($skip{row}) {
        if ($row = $params->{row}) {
            confess "'$row' is not a valid row"     unless $row->isa('DBIx::QuickORM::Row');
            confess "Row has incorrect sqla_source" unless $row->{sqla_source} == $sqla_source;
            confess "Row has incorrect connection"  unless $row->{connection} == $self->{+CONNECTION};
            $old_pk //= $row->primary_key_values;
        }

        my $cached = $self->do_cache_lookup($sqla_source, $fetched, $old_pk, $new_pk, $row);

        confess "Cached row does not match operating row" if $cached && $row && $cached != $row;
        $row //= $cached;
    }

    return ($sqla_source, $fetched, $old_pk, $new_pk, $row);
}

1;
