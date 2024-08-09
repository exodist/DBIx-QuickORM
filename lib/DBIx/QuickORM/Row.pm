package DBIx::QuickORM::Row;
use strict;
use warnings;

use Carp qw/croak cluck confess/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::Util qw/delegate alias/;

use DBIx::QuickORM::HashBase qw{
    <table
    <raw
    <inflated
    <stored
    <dirty

    +table_meta
};

sub SAVE_AUTOLOAD_METHODS { 0 }

sub table_meta { $_[0]->{+TABLE_META} //= $_[0]->table->table_meta }
sub table_name { $_[0]->table_meta->name }

sub clear_dirty_flags { $_[0]->{+DIRTY} = {} }
sub clear_stored      { delete $_[0]->{+STORED} }

delegate has_column   => (TABLE_META() => 'column');
delegate has_relation => (TABLE_META() => 'relation');
delegate schema       => (TABLE()      => 'schema');

alias col_inflated    => 'column_inflated';
alias col_is_dirty    => 'column_is_dirty';
alias col_raw         => 'column_raw';
alias col_stored      => 'column_stored';
alias cols_dirty_raw  => 'columns_dirty_raw';
alias cols_inflated   => 'columns_inflated';
alias cols_raw        => 'columns_raw';
alias cols_set        => 'columns_set';
alias cols_stored     => 'columns_stored';
alias dirty_cols      => 'dirty_columns';
alias is_tracking_col => 'is_tracking_column';
alias pkey            => 'pkeys';
alias pkey            => 'primary_key';
alias pkey            => 'primary_keys';
alias tracked_cols    => 'tracked_columns';

sub init {
    my $self = shift;

    my $table = $self->{+TABLE} or croak "'table' is a required attribute";
    croak "'table' must be an instance of 'DBIx::QuickORM::Table' or a subclass of it" unless blessed($table) && $table->isa('DBIx::QuickORM::Table');

    $self->{+INFLATED} //= {};
    $self->{+RAW}      //= {};
    $self->{+DIRTY}    //= {};

    if (my $data = delete $self->{data}) {
        $self->cols_set($data);
    }

    if (my $stored = $self->{+STORED}) {
        for my $col (@{$self->table_meta->primary_key}) {
            croak "Missing primary key column '$col' in stored fields" unless exists $stored->{$col};
        }
    }

    return;
}

sub is_tracking_col {
    my $self = shift;
    my ($col) = @_;

    $self->_check_col($col);

    return 1 if exists $self->{+INFLATED}->{$col};
    return 1 if exists $self->{+RAW}->{$col};
    return 1 if $self->{+STORED} && exists $self->{+STORED}->{$col};
    return 0;
}

sub is_stored {
    my $self = shift;
    return $self->{+STORED} ? 1 : 0;
}

sub _check_col {
    my $self = shift;
    my ($col) = @_;

    return $col if $self->has_column($col);
    confess "'$col' is not a valid column on this instance of '" . ref($self). "'";
}

sub _check_stored {
    my $self = shift;
    return 1 if $self->{+STORED};
    croak "This instance of '" . ref($self) . "' has not yet been inserted into the database";
}

sub _check_tracked {
    my $self = shift;
    my ($col) = @_;

    return 1 if $self->{+RAW}->{$col};
    return 1 if $self->{+INFLATED}->{$col};
    return 1 if $self->{+STORED} && $self->{+STORED}->{$col};

    croak "This instance of '" . ref($self) . "' is not tracking the '$col' column (did you forget to fetch it?)";
}

sub pkey {
    my $self        = shift;
    my $pkey_fields = $self->table_meta->primary_key;
    return {map { ($_ => $self->col_inflated($_)) } @$pkey_fields};
}

sub pkey_raw {
    my $self        = shift;
    my $pkey_fields = $self->table_meta->primary_key;
    return {map { ($_ => $self->col_raw($_)) } @$pkey_fields};
}

sub pkey_stored {
    my $self        = shift;
    my $pkey_fields = $self->table_meta->primary_key;
    return {map { ($_ => $self->col_stored($_)) } @$pkey_fields};
}

sub col_raw {
    my $self = shift;
    $self->_check_col(@_);
    return $self->_col_raw(@_);
}

sub _col_raw {
    my $self = shift;
    my ($col) = @_;

    return $self->{+RAW}->{$col} if exists $self->{+RAW}->{$col};

    if (exists $self->{+INFLATED}->{$col}) {
        my $colm = $self->table_meta->column($col);
        my $inf = $self->{+INFLATED}->{$col};

        # Do not deflate undef
        return $self->{+RAW}->{$col} = $inf unless defined $inf;

        if (my $type = $colm->inflate) {
            return $self->{+RAW}->{$col} = $type->orm_tiny_deflate($inf);
        }

        confess "Got reference ($inf) for column ($col) but column does not have a way to deflate it to a valid column value" if ref($inf);

        return $self->{+RAW}->{$col} = $inf;
    }

    return $self->{+RAW}->{$col} = $self->{+STORED} ? $self->col_stored($col) : undef;
}

sub col_stored {
    my $self = shift;
    my ($col) = @_;

    $self->_check_col($col);
    $self->_check_stored();
    $self->_check_tracked($col);

    return $self->{+STORED}->{$col} if exists $self->{+STORED}->{$col};

    croak "This instance of '" . ref($self) . "' has a new value for the '$col' column, but the old value was never fetched (Did you forget to fetch it?)";
}

sub _col_stored {
    my $self = shift;
    my ($col) = @_;

    return undef unless $self->{+STORED};
    return $self->{+STORED}->{$col};
}

sub col_inflated {
    my $self = shift;
    $self->_check_col(@_);
    return $self->_col_inflated(@_);
}

sub _col_inflated {
    my $self = shift;
    my ($col) = @_;

    return $self->{+INFLATED}->{$col} if exists $self->{+INFLATED}->{$col};

    my $raw = $self->col_raw($col);

    if (defined($raw)) {
        my $colm = $self->table_meta->column($col);

        if (my $type = $colm->inflate) {
            return $self->{+INFLATED}->{$col} = $type->orm_tiny_inflate($raw);
        }
    }

    return $self->{+INFLATED}->{$col} = $raw;
}

sub col_is_dirty { $_[0]->{+DIRTY}->{$_[0]->_check_col($_[1])} ? 1 : 0 }

sub cols_set {
    my $self = shift;

    my $cols;
    if (@_ == 1 && ref($_[0]) eq 'HASH') {
        ($cols) = @_;
    }
    else {
        $cols = {@_};
    }

    my %pkey = map {$_ => 1} @{$self->table_meta->primary_key};

    for my $col (keys %$cols) {
        $self->_check_col($col); # TODO bypass this check in some cases?

        my $val = $cols->{$col};

        if ($self->{+STORED}) {
            croak "Attempt to alter primary key ($col) on stored object" if $pkey{$col};
            $self->{+DIRTY}->{$col} = 1;
        }

        if (ref($val)) {
            delete $self->{+RAW}->{$col};
            $self->{+INFLATED}->{$col} = $val;
        }
        else {
            delete $self->{+INFLATED}->{$col};
            $self->{+RAW} = $val;
        }
    }

    return $cols;
}

sub dirty_cols { grep { $_[0]->{+DIRTY}->{$_} } keys %{$_[0]->{+DIRTY}} }

sub tracked_cols {
    my $self = shift;
    my %cols = (%{$self->{+RAW}}, %{$self->{+INFLATED}}, %{$self->{+STORED} // {}});
    return keys %cols;
}

sub cols_stored {
    my $self = shift;
    $self->_check_stored();
    return { %{$self->{+STORED}} };
}

sub cols_raw {
    my $self = shift;
    return { map { $self->_col_raw($_) } $self->tracked_cols };
}

sub cols_inflated {
    my $self = shift;
    return { map { $self->_col_inflated($_) } $self->tracked_cols };
}

sub cols_dirty_raw {
    my $self = shift;
    return { map { $self->_col_raw($_) } $self->dirty_cols };
}

sub relation {
    my $self = shift;
    my ($name) = @_;

    my $rel = $self->has_relation($name) or croak "'$name' is not a valid relation on table '" . $self->table_name . "'";

    my ($me_cols, $iterate, $other, $other_cols) = $rel->from($self->table_name);

    my $table = $other eq $name ? $self : $self->schema->table($other);

    my $search = {};
    for (my $i = 0; $i < @$me_cols; $i++) {
        $search->{$other_cols->[$i]} = $self->col_raw($me_cols->[$i]);
    }

    return $iterate ? $table->search($search) : $table->find($search);
}

sub fetch_tracked { $_->fetch($_[0]->tracked_cols) }
sub fetch_all { $_->fetch($_[0]->table_meta->column_names) }

sub fetch {
    my $self = shift;
    my @cols = @_;

    $self->_check_stored();

    croak "You must provide a list of columns to fetch" unless @cols;

    $self->{+STORED} = $self->{+TABLE}->fetch($self->pkey_raw, \@cols);
    $self->{+DIRTY}->{$_} = 1 for @cols;
}

sub reset {
    my $self = shift;

    $self->_check_stored();

    $self->{+INFLATED} = {};
    $self->{+RAW} = {};
    $self->{+DIRTY} = {};

    return;
}

sub reload {
    my $self = shift;
    $self->fetch_tracked;
    $self->reset;
}

sub vivify {
    my $self = shift;
    return $self->insert(@_) unless $self->{+STORED};
    return $self->update(@_);
}

sub save {
    my $self = shift;

    $self->{+TABLE}->update_or_insert($self);

    return $self;
}

sub delete {
    my $self = shift;

    $self->{+TABLE}->delete($self);

    return $self;
}

sub DESTROY {
    my $self = shift;

    return if $self->{+STORED} && !keys %{$self->{+DIRTY}};

    my $pk = $self->pkey;
    my $me = "Object in table '" . $self->table_name . "' with key(s): " . join(', ', map { "$_ => $pk->{$_}" } sort keys %$pk);

    cluck "$me was destroyed while dirty, changes not saved!" if keys %{$self->{+DIRTY}};
    cluck "$me was not stored in the database before being destroyed, changes not saved!" unless $self->{+STORED};
}

sub can {
    my $self = shift;
    my ($name) = @_;

    my $sub = $self->SUPER::can($name);

    # Already defined
    return $sub if $sub;
    return $sub unless ref($self);

    if ($name =~ m/^(.+)_(raw|inflated|stored)$/) {
        return $sub unless $self->has_column($1);
    }
    else {
        return $sub unless $self->has_column($name) || $self->has_relation($name);
    }

    return $self->_generate_meth($name) // $sub;
}

our $AUTOLOAD;
sub AUTOLOAD {
    my ($self) = @_;

    my ($name) = ($AUTOLOAD =~ m/([^:]+)$/);

    return if $name =~ m/((un)?import|DESTROY)/;

    croak qq{Can't locate object method "$name" via package "$self"} unless ref($self);

    my $sub = $self->_generate_meth($name);
    croak qq{Can't locate object method "$name" via package "$self"} unless $sub;

    goto &$sub;
}

sub _generate_meth {
    my $self = shift;
    my ($name) = @_;

    my $sub;
    if ($self->has_relation($name)) {
        $sub = $self->table_meta->generate_relation_method($name);
    }
    else {
        my ($col, $type);
        $col = $name;
        $type = $1 if $col =~ s/_(raw|inflated|stored)$//;
        return unless $self->has_column($col);
        $sub = $self->table_meta->generate_column_method($col, $type);
    }

    if ($self->SAVE_AUTOLOAD_METHODS) {
        my $class = ref($self);
        no strict 'refs';
        *{"$class\::$name"} = $sub;
    }

    return $sub;
}

1;
