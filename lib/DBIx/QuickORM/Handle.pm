package DBIx::QuickORM::Handle;
use strict;
use warnings;
use feature qw/state/;

use Carp qw/confess croak/;
use Sub::Util qw/set_subname/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::Util::HashBase qw{
    +connection
    +source
    +sql_builder
    +sql_builder_cache

    +row

    +where
    +order_by
    +limit
    +fields
    +omit

    +async
    +aside
    +forked

    +data_only
};

########################################
# {{{ Initialization and normalization #
########################################

sub init {
    my $self = shift;

    delete $self->{+SQL_BUILDER_CACHE};

    croak "async, aside, and forked are exclusive options, only one may be selected" if 1 < grep { $_ } @{$self}{ASYNC(), ASIDE(), FORKED()};

    my $con = $self->connection or confess "'connection' is a required attribute";
    confess "Connection '$con' is not an instance of 'DBIx::QuickORM::Connection'"
        unless blessed($con) && $con->isa('DBIx::QuickORM::Connection');

    my $source = $self->{+SOURCE} or croak "No source provided";
    confess "Source '$source' does not implement the 'DBIx::QuickORM::Role::Source' role"
        unless blessed($source) && $source->DOES('DBIx::QuickORM::Role::Source');

    if (my $builder = $self->{+SQL_BUILDER}) {
        confess "SQL Builder '$builder' does not implement the 'DBIx::QuickORM::Role::SQLBuilder' role"
            unless blessed($builder) && $builder->DOES('DBIx::QuickORM::Role::SQLBuilder');
    }

    if (my $row = $self->{+ROW}) {
        croak "Invalid row: $row" if $row && !$row->DOES('DBIx::QuickORM::Role::Row');
        $self->{+WHERE} //= $self->sql_builder->qorm_where_for_row($row);
    }

    my $fields = $self->{+FIELDS} //= $source->fields_to_fetch;

    if (my $omit = $self->{+OMIT}) {
        croak "Cannot mix 'omit' and a non-arrayref field specification ('$fields')" if ref($fields) ne 'ARRAY';

        my $pk_fields = $source->primary_key;
        if ($omit = $self->_normalize_omit($self->{+OMIT}, $pk_fields)) {
            if ($pk_fields || $omit) {
                my %seen;
                $fields = [grep { !$seen{$_}++ && !($omit && $omit->{$_}) } @{$pk_fields // []}, @$fields];
            }

            $self->{+FIELDS} = $fields;

            if ($omit) { $self->{+OMIT} = $omit }
            else       { delete $self->{+OMIT} }
        }
    }
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

    $pk_fields //= $self->{+SOURCE}->primary_key or return $omit;

    for my $field (@$pk_fields) {
        next unless $omit->{$field};
        croak "Cannot omit primary key field '$field'";
    }

    return $omit;
}

########################################
# }}} Initialization and normalization #
########################################

###########################
# {{{ Proxy to connection #
###########################

BEGIN {
    my @CON_METHODS = qw{
        all
        iterator
        iterate
        any
        first
        one

        by_id
        by_ids
        insert
        vivify
        search
        count
        delete
        update
        find_or_insert
        update_or_insert
    };

    for my $meth (@CON_METHODS) {
        my $name = $meth;
        no strict 'refs';
        *$name = set_subname $name => sub { my $self = shift; $self->{+CONNECTION}->$name($self, @_) };
    }
}

###########################
# }}} Proxy to connection #
###########################

###############
# {{{ Joining #
###############
#
{
    no warnings 'once';
    *join = \&_join;
}
sub left_join  { shift->_join(@_, type => 'LEFT') }
sub right_join { shift->_join(@_, type => 'RIGHT') }
sub inner_join { shift->_join(@_, type => 'INNER') }
sub full_join  { shift->_join(@_, type => 'FULL') }
sub cross_join { shift->_join(@_, type => 'CROSS') }

sub _join {
    my $self = shift;
    my ($link, %params) = @_;

    ($params{from}, $link) = ($1, $2) if !ref($link) && $link =~ m/^(.+)\:(.+)$/;

    my $source = $self->{+SOURCE};

    $link = $source->resolve_link($link, %params);

    my $join;
    if ($source->isa('DBIx::QuickORM::Join')) {
        $join = $source;
    }
    else {
        require DBIx::QuickORM::Join;
        $join = DBIx::QuickORM::Join->new(
            primary_source => $source,
            schema         => $self->{+CONNECTION}->schema,
        );
    }

    $join = $join->join(%params, link => $link);

    return $self->clone(SOURCE() => $join, FIELDS() => $join->fields_to_fetch);
}

###############
# }}} Joining #
###############

############################################
# {{{ Mutators that return modified copies #
############################################

sub clone { shift->handle(@_) }

sub handle {
    my $self = shift;

    my $clone = { %$self };

    while (my $arg = shift @_) {
        if (my $ref = ref($arg)) {
            if (my $class = blessed($arg)) {
                $clone->{+SOURCE}      = $arg and next if $arg->DOES('DBIx::QuickORM::Role::Source');
                $clone->{+SQL_BUILDER} = $arg and next if $arg->DOES('DBIx::QuickORM::Role::SQLBuilder');
                $clone->{+ROW}         = $arg and next if $arg->DOES('DBIx::QuickORM::Role::Row');
                $clone->{+CONNECTION}  = $arg and next if $arg->isa('DBIx::QuickORM::Connection');
            }

            $clone->{+WHERE} = $arg and next if $ref eq 'HASH';
            $clone->{+ORDER_BY} = $arg and next if $ref eq 'ARRAY';

            croak "Not sure what to do with '$arg'";
        }

        $clone->{+LIMIT} = $arg and next if $arg =~ m/^\d+$/;

        croak "$arg is not a recognized attribute" unless $self->can(uc($arg));
        $clone->{$arg} = shift @_;
    }

    return bless($clone, blessed($self));
}

sub sql_builder {
    my $self = shift;
    croak "Must not be called in void context" unless defined wantarray;

    return $self->clone(SQL_BUILDER() => $_[0]) if @_;

    return $self->{+SQL_BUILDER} if $self->{+SQL_BUILDER}; # Directly set
    return $self->{+SQL_BUILDER_CACHE} //= $self->_sql_builder;
}

sub _sql_builder {
    my $self = shift;

    if (my $where = $self->{+WHERE}) {
        return $where->sql_builder if blessed($where) && $where->can('sql_builder');
    }

    return $self->{+CONNECTION}->default_sql_builder;
}

sub connection {
    my $self = shift;
    croak "Must not be called in void context" unless defined wantarray;
    return $self->{+CONNECTION} unless @_;
    return $self->clone(CONNECTION() => $_[0]);
}

sub source {
    my $self = shift;
    croak "Must not be called in void context" unless defined wantarray;
    return $self->{+SOURCE} unless @_;
    return $self->clone(SOURCE() => $_[0]);
}

sub row {
    my $self = shift;
    croak "Must not be called in void context" unless defined wantarray;
    return $self->{+ROW} unless @_;
    return $self->clone(ROW() => $_[0]);
}

sub sync {
    my $self = shift;
    croak "Must not be called in void context" unless defined wantarray;
    return $self unless $self->{+FORKED} || $self->{+ASYNC} || $self->{+ASIDE};
    return $self->clone(FORKED() => 0, ASYNC() => 0, ASIDE() => 0);
}

sub async {
    my $self = shift;
    croak "Must not be called in void context" unless defined wantarray;
    return $self if $self->{+ASYNC};
    return $self->clone(FORKED() => 0, ASYNC() => 1, ASIDE() => 0);
}

sub aside {
    my $self = shift;
    croak "Must not be called in void context" unless defined wantarray;
    return $self if $self->{+ASIDE};
    return $self->clone(FORKED() => 0, ASYNC() => 0, ASIDE() => 1);
}

sub forked {
    my $self = shift;
    croak "Must not be called in void context" unless defined wantarray;
    return $self if $self->{+FORKED};
    return $self->clone(FORKED() => 1, ASYNC() => 0, ASIDE() => 0);
}

sub data_only {
    my $self = shift;
    croak "Must not be called in void context" unless defined wantarray;

    if (@_) {
        my ($val) = @_;
        return $self->clone(DATA_ONLY() => $val);
    }

    return $self if $self->{+DATA_ONLY};

    return $self->clone(DATA_ONLY() => 1);
}

sub limit {
    my $self = shift;
    croak "Must not be called in void context" unless defined wantarray;
    return $self->{+LIMIT} unless @_;
    return $self->clone(LIMIT() => $_[0]);
}

sub where {
    my $self = shift;
    croak "Must not be called in void context" unless defined wantarray;
    return $self->{+WHERE} unless @_;
    return $self->clone(WHERE() => $_[0]);
}

sub order_by {
    my $self = shift;
    croak "Must not be called in void context" unless defined wantarray;
    return $self->{+ORDER_BY} unless @_;
    return $self->clone(ORDER_BY() => @_ > 1 ? [@_] : $_[0]);
}

sub all_fields {
    my $self = shift;
    croak "Must not be called in void context" unless defined wantarray;
    return $self->clone(FIELDS() => $self->{+SOURCE}->fields_list_all);
}

sub fields {
    my $self = shift;
    croak "Must not be called in void context" unless defined wantarray;
    return $self->{+FIELDS} unless @_;

    return $self->clone(FIELDS() => $_[0]) if @_ == 1 && ref($_[0]) eq 'ARRAY';

    my @fields = @{$self->{+FIELDS} // $self->{+SOURCE}->fields_to_fetch};
    push @fields => @_;

    return $self->clone(FIELDS() => \@fields);
}

sub omit {
    my $self = shift;
    croak "Must not be called in void context" unless defined wantarray;
    return $self->{+OMIT} unless @_;

    return $self->clone(OMIT() => $_[0]) if @_ == 1 && ref($_[0]) eq 'ARRAY';

    my @omit = @{$self->{+OMIT} // []};
    push @omit => @_;
    return $self->clone(OMIT() => \@omit)
}

# Do these last to avoid conflicts with the operators
{
    no warnings 'once';
    *and = set_subname 'and' => sub {
        my $self = shift;
        return $self->clone(WHERE() => $self->sql_builder->qorm_and($self->{+WHERE}, @_));
    };

    *or = set_subname 'or' => sub {
        my $self = shift;
        return $self->clone(WHERE() => $self->sql_builder->qorm_or($self->{+WHERE}, @_));
    };
}

############################################
# }}} Mutators that return modified copies #
############################################

1;
