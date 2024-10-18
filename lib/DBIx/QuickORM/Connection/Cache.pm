package DBIx::QuickORM::Connection::Cache;
use strict;
use warnings;

use Carp qw/croak/;
use Scalar::Util qw/weaken blessed/;

use DBIx::QuickORM::Util::HashBase qw{
    +rows
    +transactions
    +savepoints
    +lookup
};

sub init {
    my $self = shift;

    croak "'transactions' is a required attribute"
        unless $self->{+TRANSACTIONS};

    $self->{+ROWS}       //= {};
    $self->{+LOOKUP}     //= {};
    $self->{+SAVEPOINTS} //= {};
}

sub transaction {
    my $self = shift;
    my $txns = $self->{+TRANSACTIONS};
    my $stack = $txns->{stack} //= [];
    return undef unless @$stack;
    return $stack->[-1];
}

sub pop_transaction {
    my $self = shift;
    my ($txn, $finalized) = @_;

    my $sp = delete $self->{+SAVEPOINTS}->{$txn};
    $sp = undef if $finalized eq 'commit';

    my $lookup = delete $self->{+LOOKUP}->{$txn} or return;

    # Rollback data with txn (unless commit was done)
    for my $row (values %$lookup) {
        next unless $row->{__TXN_TAGS__};
        delete $row->{__TXN_TAGS__}->{$txn};
        next unless $sp;
        my $data = delete $sp->{$row} or next;

        if ($data->{from_db}) {
            %{$row->from_db} = %{$data->{from_db}};
        }
        else {
            delete $row->{$row->FROM_DB};
        }

        if ($data->{dirty}) {
            %{$row->dirty} = %{$data->{dirty}};
        }
        else {
            delete $row->{$row->DIRTY};
        }
    }
}

sub from_cache {
    my $self = shift;
    my ($source, $data) = @_;

    my $cache_key = $self->_cache_key($source, $data) or return undef;
    my $cache_ref = $self->_cache_ref($source, $cache_key);

    return undef unless $$cache_ref;

    $self->touch_row_cache($$cache_ref);

    return $$cache_ref;
}

sub cache_row {
    my $self = shift;
    my ($row) = @_;
    return $self->cache_source_row($row->source, $row);
}

sub touch_row_cache {
    my $self = shift;
    my ($row) = @_;

    my $txn = $self->transaction or return;

    my $tags = $row->{__TXN_TAGS__} //= {};
    return if $tags->{$txn};
    $tags->{$txn} = 1;

    my $sp = $self->{+SAVEPOINTS}->{$txn} //= {};
    my $data = $sp->{$row} = {};

    if (my $fdb = $row->from_db) {
        $data->{from_db} = {%$fdb};
    }

    if (my $dt = $row->dirty) {
        $data->{dirty} = {%$dt};
    }

    my $lookup = $self->{+LOOKUP}->{$txn} //= {};
    $lookup->{$row} = $row;
    weaken($lookup->{$row});

    return;
}

sub cache_source_row {
    my $self = shift;
    my ($source, $row, %params) = @_;

    $params{weak} //= 1;

    my $cache_key = $self->_cache_key($source, $row) or return undef;
    my $cache_ref = $self->_cache_ref($source, $cache_key);

    $$cache_ref = $row;
    weaken(${$cache_ref}) if $params{weak};

    $self->touch_row_cache($row);

    return $row;
}

sub clear_cache {
    my $self = shift;
    $self->remove_source_cache($_) for keys %{$self->{+ROWS}};
}

sub prune_cache {
    my $self = shift;
    $self->prune_source_cache($_) for keys %{$self->{+ROWS}};
}

sub uncache_source_row {
    my $self = shift;
    my ($source, $row) = @_;

    my $cache_key = $self->_cache_key($source, $row) or return undef;

    my ($ref, $key) = $self->_cache_ref($source, $cache_key, parent => 1);

    return unless ${$ref}->{$key};

    croak "Found wrong object in cache (${$ref}->{$key} vs $row)" unless $row eq ${$ref}->{$key};
    delete ${$ref}->{$key};

    delete $row->{__TXN_TAGS__};
    $row->uncache();

    return $row;
}

sub _source_cache {
    my $self = shift;
    my ($source, $act) = @_;

    my $rows = $self->{+ROWS};

    return unless $rows->{$source};

    my @sets = ([$rows, $source, $rows->{$source}]);
    while (my $set = shift @sets) {
        my ($parent, $key, $item) = @$set;

        next if $act->($set);
        next unless $item;
        next if blessed($item) && $item->isa('DBIx::QuickORM::Row');

        push @sets => map { [$item, $_, $item->{$_}] } grep { $item->{$_} } keys %$item;
    }
}

sub prune_source_cache {
    my $self = shift;
    my ($source) = @_;

    $self->_source_cache(
        $source => sub {
            my $set = shift;
            my ($parent, $key, $item) = @$set;

            if (!$item) {
                delete $parent->{$key};    # Prune empty hash keys
                return 1;
            }

            if (blessed($item) && $item->isa('DBIx::QuickORM::Row')) {
                @$set = ();
                my $cnt = Internals::SvREFCNT(%$item);

                next if $cnt > 3;                                 # The cache copy, the copy here, and the _source_cache one
                next if $cnt == 2 && is_weak($parent->{$key});    # in cache weakly

                delete $parent->{$key};
                return 1;
            }

            return 0;
        }
    );
}

sub remove_source_cache {
    my $self = shift;
    my ($source) = @_;

    $self->_source_cache(
        $source => sub {
            my $set = shift;
            my ($parent, $key, $item) = @$set;

            return 0 unless $item;
            $item->uncache();
        }
    );

    my $rows = $self->{+ROWS};
    delete $rows->{$source};

    return;
}

sub _cache_key {
    my $self = shift;
    my ($source, $data) = @_;

    my $table = $source->table;
    my $pk_fields = $table->primary_key;
    return unless $pk_fields && @$pk_fields;

    if (blessed($data) && $data->isa('DBIx::QuickORM::Row')) {
        return [ map { $data->column($_) // return } @$pk_fields ];
    }

    return [ map { $data->{$_} // return } @$pk_fields ];
}

sub _cache_ref {
    my $self = shift;
    my ($source, $keys, %params) = @_;

    my $cache = $self->{+ROWS};

    my ($prev, $key);
    my $ref;
    for my $ck ("$source", @$keys) {
        if ($ref) {
            ${$ref} //= {};
            $prev = $ref;
            $key  = $ck;
            $ref  = \(${$ref}->{$ck});
        }
        else {
            $prev = $ref;
            $key  = $ck;
            $ref  = \($cache->{$ck});
        }
    }

    return ($prev, $key) if $params{parent};

    return $ref;
}

1;
