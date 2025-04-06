package DBIx::QuickORM::Row;
use strict;
use warnings;

use Carp qw/confess croak/;
use Scalar::Util qw/reftype blessed/;
use DBIx::QuickORM::Affinity();

our $VERSION = '0.000005';

use DBIx::QuickORM::Util::HashBase qw{
    +stored
    +pending
    +desync
    +connection
    +sqla_source
    +state
    +transactions
    +last_transaction
    +insert_transaction
};

sub track_desync { 1 }

sub sqla_source { $_[0]->{+SQLA_SOURCE}->() }
sub connection  { $_[0]->{+CONNECTION}->() }
sub dialect     { $_[0]->connection->dialect }

sub init {
    my $self = shift;

    my $src = $self->{+SQLA_SOURCE} or confess "'sqla_source' is required";
    my $con = $self->{+CONNECTION}  or confess "'connection' is required";

    my ($src_sub, $src_obj);
    if ((reftype($src) // '') eq 'CODE') {
        $src_sub = $src;
        $src_obj = $src_sub->();
    }
    else {
        $src_obj = $src;
        $src_sub = sub { $src_obj };
    }

    croak "'sqla_source' must be either a blessed object that consumes the role 'DBIx::QuickORM::Role::SQLASource', or a coderef that returns such an object"
        unless $src_obj && blessed($src_obj) && $src_obj->DOES('DBIx::QuickORM::Role::SQLASource');

    my ($con_sub, $con_obj);
    if ((reftype($con) // '') eq 'CODE') {
        $con_sub = $con;
        $con_obj = $con_sub->();
    }
    else {
        $con_obj = $con;
        $con_sub = sub { $con_obj };
    }

    croak "'connection' must be either a blessed instance of 'DBIx::QuickORM::Connection', or a coderef that returns such an object"
        unless $con_obj && blessed($con_obj) && $con_obj->isa('DBIx::QuickORM::Connection');

    $self->{+CONNECTION}  = $con_sub;
    $self->{+SQLA_SOURCE} = $src_sub;
}

sub source {
    my $self = shift;

    use DBIx::QuickORM::Util qw/debug/;

    require DBIx::QuickORM::Source;
    return DBIx::QuickORM::Source->new(
        SQLA_SOURCE() => $self->sqla_source,
        CONNECTION()  => $self->connection,
    );
}

sub update_from_db_data {
    my $self = shift;
    my ($new, %params) = @_;

    my $stored  = $self->{+STORED};
    my $pending = $self->{+PENDING};

    my $txn = delete $params{transaction};
    my $ins = delete $params{inserted};
    my $upd = delete $params{updated};
    my $nod = delete $params{no_desync};

    $self->txn_check($txn, $ins);

    if ($upd) {
        delete $self->{+PENDING};
        $pending = undef;
    }

    if ($nod || !$self->track_desync) {
        $self->{+STORED} = { %{$self->{+STORED} // {}}, %$new };
        return;
    }

    my $desync      = $self->{+DESYNC} //= {};
    my $has_pending = $pending && keys %$pending;

    for my $field (keys %$new) {
        next if $self->_compare_field($field, $stored->{$field}, $new->{$field}); # No change
        $stored->{$field} = $new->{$field};
        next unless $has_pending && $pending->{$field};
        $desync->{$field}++;
    }

    delete $self->{+DESYNC} unless keys %$desync;

    return;
}

sub txn_check {
    my $self = shift;
    my ($txn, $ins) = @_;

    my $txns    = $self->{+TRANSACTIONS};
    my $ltxn    = $self->{+LAST_TRANSACTION};
    my $itxn    = $self->{+INSERT_TRANSACTION};
    my $any_txn = ($ltxn // $itxn // ($txns && keys %$txns)) ? 1 : 0;

    if ($any_txn && !$txn) {
        # All transactions complete
        my $bad = grep { $_ && !$_->result } $itxn, $ltxn, values %{$txns // {}};
        delete $self->{+TRANSACTIONS};
        delete $self->{+LAST_TRANSACTION};
        delete $self->{+INSERT_TRANSACTION};

        # If any transaction failed, we cannot trust our storage
        if ($bad) {
            if ($itxn) {
                delete $self->{+STORED}; # Was never inserted
            }
            else {
                $self->{+STORED} = {}; # Cannot trust last read values, clear them
            }
        }
    }

    if ($txn) {
        $txns->{$txn} //= $txn;
        $self->{+LAST_TRANSACTION}   = $txn;
        $self->{+INSERT_TRANSACTION} = $txn if $ins;

        if ($ltxn && $ltxn != $txn) {
            my $res = $ltxn->result;
            if ($res) {
                delete $txns->{$ltxn};
            }
            elsif (defined($res)) {
                delete $txns->{$ltxn};
                if ($itxn && $itxn == $ltxn) {
                    delete $self->{+STORED}; # Was never in storage
                }
                else {
                    $self->{+STORED} = {}; # Cannot trust values
                }
            }
            # res not defined means txn is still open
        }
        # else { no change }
    }
}

sub stored_data   { $_[0]->{+STORED} }
sub pending_data  { $_[0]->{+PENDING} }
sub desynced_data { $_[0]->{+DESYNC} }

sub stored   { $_[0]->{+STORED}  ? wantarray ? (sort keys %{$_[0]->{+STORED}})  : 1 : () }
sub pending  { $_[0]->{+PENDING} ? wantarray ? (sort keys %{$_[0]->{+PENDING}}) : 1 : () }
sub desynced { $_[0]->{+DESYNC}  ? wantarray ? (sort keys %{$_[0]->{+DESYNC}})  : 1 : () }

sub insert_or_save {
    my $self = shift;

    return $self->save(@_)   if $self->{+STORED};
    return $self->insert(@_) if $self->{+PENDING};
}

# Write the data to the db
sub insert {
    my $self = shift;

    croak "This row is already in the database" if $self->{+STORED};
    croak "This row has no data to write" unless $self->{+PENDING} && keys %{$self->{+PENDING}};

    $self->source->insert_row($self);
    delete $self->{+PENDING};
    delete $self->{+DESYNC};

    return 1;
}

# Write pending changes
sub save {
    my $self = shift;
    my %params = @_;

    croak "This row is not in the database yet" unless $self->{+STORED};

    my $pk = $self->sqla_source->primary_key or croak "Cannot use 'save()' on a row with a source that has no primary key";

    croak "The object has changed in the database since making changes, use force => 1 to write anyway."
        if $self->{+DESYNC} && !$params{force};

    return 0 unless $self->{+PENDING};

    $self->source->update_row($self);

    delete $self->{+PENDING};
    delete $self->{+DESYNC};

    return 1;
}

# Fetch new data from the db
sub refresh {
    my $self = shift;
    $self->source->refresh_row($self);
}

sub primary_key_where {
    my $self = shift;

    my $pk_fields = $self->sqla_source->primary_key or confess "This source has no primary key";
    return { map { $_ => $self->stored_field($_) } @$pk_fields };
}

# Remove pending changes (and clear desync)
sub discard {
    my $self = shift;

    if (@_) {
        my ($field) = @_;
        delete $self->{+DESYNC}->{$field};
        delete $self->{+PENDING}->{$field};
        delete $self->{+DESYNC}  unless keys %{$self->{+DESYNC}};
        delete $self->{+PENDING} unless keys %{$self->{+PENDING}};
    }
    else {
        delete $self->{+DESYNC};
        delete $self->{+PENDING};
    }

    return;
}

sub update {
    my $self = shift;
    my ($changes, %params) = @_;

    $self->{+PENDING} = { %{$self->{+PENDING} // {}}, %$changes };

    $self->save(%params);
}

sub has_field {
    my $self = shift;
    my $field = shift or croak "Must specify a field name";

    return $self->sqla_source->has_field($field);
}

sub field {
    my $self = shift;
    my $field = shift or croak "Must specify a field name";

    croak "This row does not have a '$field' field" unless $self->has_field($field);

    $self->{+PENDING}->{$field} = shift if @_;

    return $self->_inflated_field($self->{+PENDING}, $field) if $self->{+PENDING} && exists $self->{+PENDING}->{$field};

    if (my $st = $self->{+STORED}) {
        unless (exists $st->{$field}) {
            my $data = $self->source->search($self->primary_key_where, fields => $field)->one(data_only => 1);
            $st->{$field} = $data->{$field};
        }

        return $self->_inflated_field($st, $field);
    }

    return undef;
}

sub raw_field {
    my $self = shift;
    my ($field) = @_;

    croak "This row does not have a '$field' field" unless $self->has_field($field);

    return $self->_raw_field($self->{+PENDING}, $field) if $self->{+PENDING} && exists $self->{+PENDING}->{$field};
    return $self->_raw_field($self->{+STORED},  $field) if $self->{+STORED}  && exists $self->{+STORED}->{$field};
    return undef;
}

sub stored_field      { $_[0]->_inflated_field($_[0]->{+STORED},  $_[1]) }
sub pending_field     { $_[0]->_inflated_field($_[0]->{+PENDING}, $_[1]) }
sub raw_stored_field  { $_[0]->_raw_field($_[0]->{+STORED},  $_[1]) }
sub raw_pending_field { $_[0]->_raw_field($_[0]->{+PENDING}, $_[1]) }

sub raw_fields {
    my $self = shift;

    my $out = { %{$self->{+STORED} // {}}, %{$self->{+PENDING} // {}} };
    $out->{$_} = $out->{$_}->qorm_deflate($self->field_affinity($_)) for grep { blessed($out->{$_}) } keys %$out;

    return $out;
}

sub raw_pending {
    my $self = shift;

    return unless $self->{+PENDING};

    my $out = { %{$self->{+PENDING}} };
    $out->{$_} = $out->{$_}->qorm_deflate($self->field_affinity($_)) for grep { blessed($out->{$_}) } keys %$out;

    return $out;
}

sub fields {
    my $self = shift;

    my $out = {};
    for my $set ($self->{+PENDING}, $self->{+STORED}) {
        next unless $set;
        for my $field (keys %$set) {
            $out->{$field} //= $self->field($field);
        }
    }

    return $out;
}

sub pending_fields { $_[0]->{+PENDING} // {} }

sub _inflated_field {
    my $self = shift;
    my ($from, $field) = @_;

    croak "This row does not have a '$field' field" unless $self->has_field($field);

    return undef unless $from;
    return undef unless exists $from->{$field};

    my $val = $from->{$field};

    return $val if ref($val);    # Inflated already

    if (my $type = $self->sqla_source->field_type($field)) {
        return $from->{$field} = $type->qorm_inflate($val);
    }

    return $from->{$field};
}

sub _raw_field {
    my $self = shift;
    my ($from, $field) = @_;

    croak "This row does not have a '$field' field" unless $self->has_field($field);

    return undef unless $from;
    return undef unless exists $from->{$field};
    my $val = $from->{$field};

    return $val unless blessed($val);    # not inflated
    return $val->qorm_deflate($self->field_affinity($field));
}

sub is_desynced {
    my $self = shift;
    my ($field) = @_;

    croak "You must specify a field name" unless @_;

    return 0 unless $self->{+DESYNC};
    return $self->{+DESYNC}->{$field} // 0;
}

sub field_affinity { $_[0]->sqla_source->field_affinity($_[1], $_[0]->dialect) }

sub delete {
    my $self = shift;
    $self->source->search($self->primary_key_where)->delete;
    if (my $cache = $self->connection->cache) {
        $cache->remove($self);
    }
    $self->{+PENDING} = { %{ $self->{+PENDING} // {} }, %{ delete $self->{+STORED} // {} } };
    delete $self->{+DESYNC};
    return $self;
}

1;
