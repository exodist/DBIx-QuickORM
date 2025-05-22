package DBIx::QuickORM::Handle;
use strict;
use warnings;
use feature qw/state/;

use Carp qw/confess croak carp/;
use Sub::Util qw/set_subname/;
use List::Util qw/mesh/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::STH();
use DBIx::QuickORM::STH::Fork();
use DBIx::QuickORM::STH::Aside();
use DBIx::QuickORM::STH::Async();
use DBIx::QuickORM::Row::Async();

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

    +auto_refresh

    +data_only

    +internal_transactions

    +target
};

sub dialect { $_[0]->{+CONNECTION}->dialect }

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

    $self->{+INTERNAL_TRANSACTIONS} //= $con->default_internal_txn // 1;

    if (my $builder = $self->{+SQL_BUILDER}) {
        confess "SQL Builder '$builder' does not implement the 'DBIx::QuickORM::Role::SQLBuilder' role"
            unless blessed($builder) && $builder->DOES('DBIx::QuickORM::Role::SQLBuilder');
    }

    if (my $row = $self->{+ROW}) {
        croak "Invalid row: $row" if $row && !$row->DOES('DBIx::QuickORM::Role::Row');

        croak "You cannot provide both a 'row' and a 'where'" if $self->{+WHERE};

        $self->{+WHERE} = $self->sql_builder->qorm_where_for_row($row);
    }

    unless ($self->{+WHERE}) {
        croak "You must provide a where clause or row before specifying a limit"     if $self->{+LIMIT};
        croak "You must provide a where clause or row before specifying an order_by" if $self->{+ORDER_BY};
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

sub _sql_builder {
    my $self = shift;

    if (my $where = $self->{+WHERE}) {
        return $where->sql_builder if blessed($where) && $where->can('sql_builder');
    }

    return $self->{+CONNECTION}->default_sql_builder;
}

########################################
# }}} Initialization and normalization #
########################################

###############
# {{{ Joining #
###############

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

##################
# {{{ Immutators #
##################

sub clone { shift->handle(@_) }

sub handle {
    my $in = shift;

    my ($self, $class);
    if ($class = blessed($in)) {
        $self = $in;
    }
    else {
        $class = $in;
    }

    my $clone = { $self ? %$self : () };

    my %flags;
    $flags{unknown_object} = sub { croak "Not sure what to do with '$_[1]'" };
    $flags{unknown_ref}    = sub { croak "Not sure what to do with '$_[1]'" };
    $flags{unknown_arg}    = sub { croak "$_[1] is not a recognized handle-attribute or table name" };
    $flags{row_and_where}  = sub { croak "Cannot provide both a 'where' and a 'row'" };
    $flags{row_and_source} = sub { croak "Cannot provide both a 'source' and a 'row'" };
    $flags{bad_override}   = sub { my ($self, $key, @args) = @_; croak "Handle already has a '$key' set (" . (map { defined($_) ? ( (blessed($_) && $_->can('display')) ? $_->display : "'$_'" ) : 'undef'} @args) . ")" };
    $flags{allow_override} = 1;

    my %set;
    while (my $arg = shift @_) {
        if (my $ref = ref($arg)) {
            if (my $class = blessed($arg)) {
                if ($arg->DOES('DBIx::QuickORM::Role::Source')) {
                    $flags{bad_override}->($clone, SOURCE() => $clone->{+SOURCE}, $arg) if $clone->{+SOURCE} && !$flags{allow_override};

                    if ($set{+ROW}) {
                        my $s1 = $arg;
                        my $s2 = $clone->{+ROW}->source;
                        $flags{row_and_source}->($clone) unless $s1 == $s2;
                    }
                    else {
                        $clone->{+SOURCE} = $arg;
                    }

                    $set{+SOURCE}++;

                    next;
                }

                if ($arg->DOES('DBIx::QuickORM::Role::SQLBuilder')) {
                    $flags{bad_override}->($clone, SQL_BUILDER() => $clone->{+SQL_BUILDER}, $arg) if $clone->{+SQL_BUILDER} && !$flags{allow_override};
                    $set{+SQL_BUILDER}++;
                    $clone->{+SQL_BUILDER} = $arg;
                    next;
                }

                if ($arg->isa('DBIx::QuickORM::Connection')) {
                    $flags{bad_override}->($clone, CONNECTION() => $clone->{+CONNECTION}, $arg) if $clone->{+CONNECTION} && !$flags{allow_override};
                    $set{+CONNECTION}++;
                    $clone->{+CONNECTION} = $arg;
                    next;
                }

                if ($arg->DOES('DBIx::QuickORM::Role::Row')) {
                    $flags{bad_override}->($clone, ROW() => $clone->{+ROW}, $arg) if $clone->{+ROW} && !$flags{allow_override};
                    $flags{row_and_where}->($clone) if $set{+WHERE};

                    if ($set{+SOURCE}) {
                        my $s1 = $clone->{+SOURCE};
                        my $s2 = $arg->source;
                        $flags{row_and_source}->($clone) unless $s1 == $s2;
                    }
                    else {
                        $clone->{+SOURCE} = $arg->source;
                    }

                    $set{+ROW}++;
                    $clone->{+ROW} = $arg;
                    delete $clone->{+WHERE};
                    next;
                }

                $flags{unknown_object}->($clone, $arg);
            }

            if ($ref eq 'ARRAY') {
                if (my $cb = $flags{array}) {
                    $cb->($clone, $arg) and next;
                }

                $flags{bad_override}->($clone, ORDER_BY() => $clone->{+ORDER_BY}, $arg) if $clone->{+ORDER_BY} && !$flags{allow_override};
                $clone->{+ORDER_BY} = $arg;
                next;
            }

            if ($ref eq 'HASH') {
                if (my $cb = $flags{hash}) {
                    $cb->($clone, $arg) and next;
                }

                $flags{bad_override}->($clone, WHERE() => $clone->{+WHERE}, $arg) if $clone->{+WHERE} && !$flags{allow_override};
                $flags{row_and_where}->($clone) if $set{+ROW};
                $set{+WHERE}++;
                $clone->{+WHERE} = $arg;
                delete $clone->{+ROW};
                next;
            }

            $flags{unknown_ref}->($clone, $arg);
            next;
        }

        if ($arg =~ m/^-(.+)$/) {
            my $flag = $1;
            my $val = shift @_;
            $flags{$flag} = $val;
            if ($arg eq 'unknown') {
                $flags{$_} = $val for qw/unknown_object unknown_ref unknown_arg/;
            }
            next;
        }

        if ($arg =~ m/^\d+$/) {
            if (my $cb = $flags{integer}) {
                $cb->($clone, $arg, \@_) and next;
            }
            $flags{bad_override}->($clone, LIMIT() => $clone->{+LIMIT}, $arg) if defined($clone->{+LIMIT}) && !$flags{allow_override};
            $clone->{+LIMIT} = $arg;
            next;
        }

        if (my $cb = $flags{scalar}) {
            $cb->($clone, $arg, \@_) and next;
        }

        if (my $const = $class->can(uc($arg))) {
            my $val = shift(@_);
            my $key = $const->();

            $flags{bad_override}->($clone, $key => $clone->{$key}, $val) if defined($clone->{$key}) && !$flags{allow_override};

            unless (defined $val) {
                delete $set{$key};
                delete $clone->{$key};
                next;
            }

            $set{$key}++;
            $flags{row_and_where}->($clone) if $set{+ROW} && $set{+WHERE};
            $clone->{$key} = $val;

            if ($key eq WHERE()) {
                $flags{bad_override}->($clone, ROW() => $clone->{+ROW}, undef) if $clone->{+ROW} && !$flags{allow_override};
                delete $clone->{+ROW};
            }
            elsif ($key eq ROW()) {
                $flags{bad_override}->($clone, WHERE() => $clone->{+WHERE}, undef) if $clone->{+WHERE} && !$flags{allow_override};
                delete $clone->{+WHERE};
            }

            next;
        }

        if (my $src = $clone->{+CONNECTION}->source($arg, no_fatal => 1)) {
            $flags{bad_override}->($clone, SOURCE() => $clone->{+SOURCE}, $src) if $clone->{+SOURCE} && !$flags{allow_override};
            $clone->{+SOURCE} = $src;
            next;
        }

        $flags{unknown_arg}->($clone, $arg, \@_);
    }

    my $new = bless($clone, $class);
    $new->init();
    return $new;
}

sub auto_refresh {
    my $self = shift;
    croak "Must not be called in void context" unless defined wantarray;
    return $self if $self->{+AUTO_REFRESH};
    return $self->clone(AUTO_REFRESH() => 1);
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

sub all_fields {
    my $self = shift;
    croak "Must not be called in void context" unless defined wantarray;
    return $self->clone(FIELDS() => $self->{+SOURCE}->fields_list_all);
}

sub internal_txns            { $_[0]->{+INTERNAL_TRANSACTIONS} = $_[1] // 1; $_[0] }
sub internal_transactions    { $_[0]->{+INTERNAL_TRANSACTIONS} = $_[1] // 1; $_[0] }

sub no_internal_txns         { $_[0]->{+INTERNAL_TRANSACTIONS} = defined($_[1]) ? $_[1] ? 0 : 1 : 0; $_[0] }
sub no_internal_transactions { $_[0]->{+INTERNAL_TRANSACTIONS} = defined($_[1]) ? $_[1] ? 0 : 1 : 0; $_[0] }

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

##################
# }}} Immutators #
##################

###################
# {{{ Immucessors #
###################

sub sql_builder {
    my $self = shift;
    croak "Must not be called in void context" unless defined wantarray;

    return $self->clone(SQL_BUILDER() => $_[0]) if @_;

    return $self->{+SQL_BUILDER} if $self->{+SQL_BUILDER}; # Directly set
    return $self->{+SQL_BUILDER_CACHE} //= $self->_sql_builder;
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
    return $self->clone(ROW() => $_[0], WHERE() => undef);
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
    return $self->clone(WHERE() => $_[0], ROW() => undef);
}

sub order_by {
    my $self = shift;
    croak "Must not be called in void context" unless defined wantarray;
    return $self->{+ORDER_BY} unless @_;
    return $self->clone(ORDER_BY() => @_ > 1 ? [@_] : $_[0]);
}

###################
# }}} Immucessors #
###################

#######################
# {{{ State Accessors #
#######################

sub is_sync   { !($_[0]->{+FORKED} || $_[0]->{+ASYNC} || $_[0]->{+ASIDE}) }
sub is_async  { $_[0]->{+ASYNC} }
sub is_aside  { $_[0]->{+ASIDE} }
sub is_forked { $_[0]->{+FORKED} }
sub using_internal_transactions { $_[0]->{+INTERNAL_TRANSACTIONS} ? 1 : 0 }

#######################
# }}} State Accessors #
#######################

####################
# {{{ STH BUILDERS #
####################

sub _has_pk {
    my $self = shift;
    my $pk_fields = $self->{+SOURCE}->primary_key;
    my $has_pk = $pk_fields && @$pk_fields;
    return $has_pk ? $pk_fields : 0;
}

sub make_sth {
    my $self = shift;

    $self->{+CONNECTION}->pid_and_async_check;

    return $self->_make_async_sth(@_)  if $self->{+ASYNC} || $self->{+ASIDE};
    return $self->_make_forked_sth(@_) if $self->{+FORKED};
    return $self->_make_sync_sth(@_);
}

sub _execute {
    my $self = shift;
    my ($dbh, $sql, @prepare_args) = @_;
    my $sth = $dbh->prepare($sql->{statement}, @prepare_args);
    $self->_do_binds($sth, $sql);
    my $res = $sth->execute();
    return ($sth, $res);
}

sub _do_binds {
    my $self = shift;
    my ($sth, $sql) = @_;

    my $bind      = $sql->{bind};
    my $source    = $sql->{+SOURCE};
    my $dialect   = $self->dialect;
    my $quote_bin = $dialect->quote_binary_data;

    for my $item  (@$bind) {
        my ($field, $val, $param, $type) = @{$item}{qw/field value param type/};

        my @args;
        if ($type eq 'field') {
            my $affinity = $source->field_affinity($field, $dialect);

            if (blessed($val) && $val->DOES('DBIx::QuickORM::Role::Type')) {
                $val = $val->qorm_deflate($affinity);
            }
            elsif (my $type = $source->field_type($field)) {
                $val = $type->qorm_deflate($val, $affinity);
            }

            if ($quote_bin && $affinity eq 'binary') {
                @args = ($quote_bin);
            }
        }

        $sth->bind_param($param, $val, @args);
    }

    return $sth;
}

sub _make_sync_sth {
    my $self = shift;
    my ($sql, %params) = @_;

    croak "'on_ready' is required" unless $params{on_ready};

    my $con = $self->{+CONNECTION};
    my $dbh = $con->dbh;
    my ($sth, $res) = $self->_execute($dbh, $sql);

    return DBIx::QuickORM::STH->new(
        %params,
        connection => $con,
        source     => $sql->{+SOURCE},
        dbh        => $dbh,
        sth        => $sth,
        sql        => $sql,
        result     => $res,
    );
}

sub _make_async_sth {
    my $self = shift;
    my ($sql, %params) = @_;

    croak "'on_ready' is required" unless $params{on_ready};

    my $dialect = $self->dialect;
    croak "Dialect '" . $dialect->dialect_name . "' does not support async" unless $dialect->async_supported;

    my $con = $self->{+CONNECTION};

    my ($dbh, $class, $meth);
    if ($self->{+ASIDE}) {
        $meth = 'add_aside';
        $dbh   = $con->aside_dbh;
        $class = 'DBIx::QuickORM::STH::Aside';
    }
    else {
        $meth = 'set_async';
        $dbh   = $con->dbh;
        $class = 'DBIx::QuickORM::STH::Async';
    }

    my ($sth, $res) = $self->_execute($dbh, $sql, $dialect->async_prepare_args);

    my $out = $class->new(
        %params,
        connection   => $con,
        source       => $sql->{+SOURCE},
        dbh          => $dbh,
        sth          => $sth,
        sql          => $sql,
        async_result => $res,
    );

    $con->$meth($out);
    return $out;
}

sub _make_forked_sth {
    my $self = shift;
    my ($sql, %params) = @_;

    my $on_ready = delete $params{on_ready} or croak "'on_ready' is required";

    my $con = $self->{+CONNECTION};

    my ($rh, $wh);
    pipe($rh, $wh) or die "Could not create pipe: $!";
    my $pid = fork // die "Could not fork: $!";

    if ($pid) {    # Parent
        close($wh);

        my $fork = DBIx::QuickORM::STH::Fork->new(
            %params,
            connection => $con,
            source     => $sql->{+SOURCE},
            pid        => $pid,
            sql        => $sql,
            pipe       => $rh,
        );

        $con->add_fork($fork);

        return $fork;
    }

    # Child
    my $guard = Scope::Guard->new(sub {
        my @caller = caller;
        print STDERR "Escaped Scope in forked query at $caller[1] line $caller[2].\n";
        POSIX::_exit(255);
    });
    close($rh);

    my $json = Cpanel::JSON::XS->new->utf8(1)->convert_blessed(1)->allow_nonref(1);
    my $dbh = $con->aside_dbh;

    my ($sth, $res) = $self->_execute($dbh, $sql);
    print $wh $json->encode({result => $res}), "\n";
    my $fetch = $on_ready->($dbh, $sth, $res, $sql);

    eval {
        while (my $row = $fetch->()) {
            print $wh $json->encode($row), "\n";
        }
        close($wh);
        1;
    } or warn $@;
    $guard->dismiss();
    POSIX::_exit(0);
}

sub _get_keys {
    my $self = shift;
    my ($source, $where) = @_;

    my $pk_fields = $source->primary_key or croak "No primary key";

    my $sql = $self->sql_builder->qorm_select(source => $source, fields => $pk_fields, where => $where);
    my $sth = $self->_make_sth($sql);
    my $keys = $sth->fetchall_arrayref({});
    return $keys;
}

####################
# }}} STH BUILDERS #
####################

###########################
# {{{ Transaction Related #
###########################

sub _start_internal_txn {
    my $self = shift;
    my (%params) = @_;

    my $con = $self->{+CONNECTION};

    # Already inside a txn
    return undef if $con->in_txn;

    # Internal TXNs are allowed, use one
    return $con->txn if $self->{+INTERNAL_TRANSACTIONS};

    carp "Internal transactions are disabled: $params{warn}" if $params{warn};
    croak "Internal transactions are disabled: $params{die}" if $params{die};

    return undef;
}

sub _internal_txn {
    my $self = shift;
    my ($cb, %params) = @_;

    my $con = $self->{+CONNECTION};

    # Already inside a txn
    return $cb->() if $con->in_txn;

    # Internal TXNs are allowed, use one
    return $con->txn($cb) if $self->{+INTERNAL_TRANSACTIONS};

    carp "Internal transactions are disabled: $params{warn}" if $params{warn};
    croak "Internal transactions are disabled: $params{die}" if $params{die};

    return undef if $params{noop};

    return $cb->();
}

###########################
# }}} Transaction Related #
###########################

########################
# {{{ Results Fetchers #
########################

sub _fixture_arg {
    my $self = shift;
    my ($arg) = @_;
    $self->{+TARGET} = $arg;
}

sub by_id {
    my $id = pop;
    my $self = shift->handle(@_);

    my $source = $self->{+SOURCE};

    my $where;
    my $ref = ref($id);
    #<<<
    if    ($ref eq 'HASH')  { $where = $id; $id = [ map { $where->{$_} } @{$source->primary_key} ] }
    elsif ($ref eq 'ARRAY') { $where = +{ mesh($source->primary_key, $id) } }
    elsif (!$ref)           { $id = [ $id ]; $where = +{ mesh($source->primary_key, $id) } }
    #>>>

    croak "Unrecognized primary key format: $id" unless ref($id) eq 'ARRAY';

    my $row = $self->{+CONNECTION}->state_cache_lookup($source, $id);
    return $row //= $self->where($where)->one();
}

sub by_ids {
    my $self = shift;
    croak "Cannot call by_ids() on a handle with a where clause"    if $self->{+WHERE};
    croak "Cannot call by_ids() on a handle with an associated row" if $self->{+ROW};
    return [map { $self->by_id($_) } @_];
}

sub vivify {
    croak "Not enough arguments to vivify()" if @_ < 2;
    my $data = pop or croak "You must provide a data hashref as the final argument to vivify()";
    croak "last argument to vivify() must be a hashref, got '$data'" unless ref($data) eq 'HASH';

    my $self = shift->handle(@_);

    $self->{+CONNECTION}->pid_check;

    return $self->{+CONNECTION}->state_vivify_row(
        source  => $self->{+SOURCE},
        fetched => $data,
    );
}

sub _builder_args {
    my $self = shift;

    return {
        source   => $self->{+SOURCE},
        where    => $self->{+WHERE},
        limit    => $self->{+LIMIT},
        order_by => $self->{+ORDER_BY},
        fields   => $self->fields,
    };
}

sub insert {
    my $self = shift->handle(-unknown_ref => \&_fixture_arg, -hash => \&_fixture_arg, @_);

    return $self->_insert_and_refresh() if $self->{+AUTO_REFRESH};
    return $self->_insert();
}

sub insert_and_refresh {
    my $self = shift->handle(-unknown_ref => \&_fixture_arg, -hash => \&_fixture_arg, @_);
    return $self->_insert_and_refresh();
}

sub _insert_and_refresh {
    my $self = shift;

    croak "Cannot refresh a row without a primary key" unless $self->_has_pk;

    return $self->handle(AUTO_REFRESH() => 1)->_insert() if $self->dialect->supports_returning_insert;

    my $row = $self->_insert();

    if ($self->is_sync) {
        $row->refresh();
    }
    else {
        $row->{auto_refresh} = 1;
    }

    return $row;
}

sub _insert {
    my $self = shift;

    croak "Cannot insert rows using a handle with data_only set"   if $self->{+DATA_ONLY};
    croak "Cannot insert rows using a handle with a limit set"     if defined $self->{+LIMIT};
    croak "Cannot insert rows using a handle with an order_by set" if defined $self->{+ORDER_BY};

    my $data;
    if (my $in = $self->{+TARGET}) {
        $data = $in if ref($in) eq 'HASH';
        croak "Not sure how to insert '$in'" unless $data;
    }

    if (my $row = $self->{+ROW}) {
        croak "Cannot provide both a row and data to insert()" if $data;
        croak "Cannot insert a row that is already stored" if $row->in_storage;
        $data = $row->row_data_obj->pending_data or croak "Row has no pending data to insert";
    }

    croak "No data provided to insert" unless $data;
    croak "Refusing to insert an empty row" unless keys %$data;

    my $source  = $self->{+SOURCE};
    my $dialect = $self->dialect;

    my $builder_args = $self->_builder_args;
    my $fields  = $builder_args->{fields};

    for my $col ($source->columns) {
        my $def  = $col->perl_default or next;
        my $name = $col->name;

        $data->{$name} = $def->() unless exists $data->{$name};
    }

    my $has_pk = $self->_has_pk;
    my $has_ret = $dialect->supports_returning_insert;

    if ($has_pk && @$has_pk > 1 && !$has_ret) {
        croak "Database-Auto-Generated compound primary keys are not supported for databases that do not support 'returning on insert' functionality"
            if grep { !$data->{$_} } @$has_pk;
    }

    $builder_args->{insert} = $data;

    if ($has_ret && $has_pk) {
        my %seen;
        # @fields might omit some fields specified in $data, so we want to include any that were in data
        $builder_args->{returning} = $self->{+AUTO_REFRESH} ? [ grep { !$seen{$_}++ } @$has_pk, @$fields, keys %$data ] : $has_pk;
    }

    my $sql = $self->sql_builder->qorm_insert(%$builder_args);
    my $sth = $self->make_sth(
        $sql,
        only_one => 1,
        on_ready => sub {
            my ($dbh, $sth, $res, $sql) = @_;

            my $row_data;

            # Add generated PKs, mixed with insert values
            if ($builder_args->{returning}) {
                $row_data = {
                    %$data,
                    %{$sth->fetchrow_hashref},
                };
            }
            else {
                my $kv = $dbh->last_insert_id(undef, undef, $self->{+SOURCE}->source_db_moniker);
                $row_data = {
                    %$data,
                    $has_pk->[0] => $kv,
                };
            }

            my $sent = 0;
            return sub { $sent++ ? () : $row_data };
        },
    );

    if ($sth->DOES('DBIx::QuickORM::Role::Async')) {
        return DBIx::QuickORM::Row::Async->new(
            async        => $sth,
            state_method => 'state_insert_row',
            state_args   => [row => $self->{+ROW}],
        );
    }

    return $self->{+CONNECTION}->state_insert_row(
        source  => $source,
        fetched => $sth->next,
        row     => $self->{+ROW},
    );
}

#sub delete {
#sub update {
#sub all      { shift->handle(@_)->all }
#sub iterator { shift->handle(@_)->iterator }
#sub any      { shift->handle(@_)->any }
#sub first    { shift->handle(@_)->first }
#sub one      { shift->handle(@_)->one }
#sub count    { shift->handle(@_)->count }
#sub iterate  { }
#sub update_or_insert { my $arg = pop; shift->handle(@_)->update_or_insert($arg) }
#sub find_or_insert   { my $arg = pop; shift->handle(@_)->update_or_insert($arg) }

1;

__END__


    if ($has_pk ) {
        my $pk_fields = $self->{+SOURCE}->primary_key;

        if (@$pk_fields > 1) {
            croak "Database-Auto-Generated compound primary keys are not supported for databases that do not support 'returning on insert' functionality"
                if grep { !$data->{$_} } @$pk_fields;
        }

        $stage2 = sub {
            my ($dbh, $sth) = @_;

            my $kv    = $dbh->last_insert_id(undef, undef, $self->{+SOURCE}->source_db_moniker);
            my $where = {$pk_fields->[0] => $kv};

            my $sql  = $self->sql_builder->qorm_select(source => $source, where => $where, fields => $fields);
            my $sth2 = $self->make_sth($sql);
            $sth2->set_only_one(1);
            return ($sth2, $res);
        };
    }

sub _make_sth {
    my $self = shift;
    my ($sql) = @_;

    my $dbh = $self->dbh;
    my $sth = $dbh->prepare($sql->{statement});
    $self->_do_binds($sth, $sql);
    my $res = $sth->execute();
    return $sth;
}

sub _stage1 {
    my $self = shift;
    my ($dbh, @prepare_args) = @_;
    my $sth = $dbh->prepare($sql->{statement}, @prepare_args);
    $self->_do_binds($sth, $sql);
    my $res = $sth->execute();
    return ($sth, $res);
}


#        $stage2 = sub {
#            my ($dbh, $sth, $res) = @_;
#
#            my $kv    = $dbh->last_insert_id(undef, undef, $self->{+SOURCE}->source_db_moniker);
#            my $where = {$pk_fields->[0] => $kv};
#
#            my $sql  = $self->sql_builder->qorm_select(source => $source, where => $where, fields => $fields);
#            my $sth2 = $self->make_sth($sql);
#            $sth2->set_only_one(1);
#            return ($sth2, $res);
#        };


sub insert {
    my $self = shift->handle(-unknown_ref => \&_fixture_arg, @_);

    croak "Cannot insert rows using a handle with a limit set"     if defined $self->{+LIMIT};
    croak "Cannot insert rows using a handle with an order_by set" if defined $self->{+ORDER_BY};

    my $data;
    if (my $in = $self->{+TARGET}) {
        $data = $in if ref($in) eq 'HASH';
        croak "Not sure how to insert '$in'" unless $data;
    }

    if (my $row = $self->{+ROW}) {
        croak "Cannot provide both a row and data to insert()" if $data;
        $data = $row->row_data_obj->pending_data or croak "Row has no pending data to insert";
    }

    croak "No data provided to insert" unless $data;
    croak "Refusing to insert an empty row" unless keys %$data;

    my $source = $self->{+SOURCE};
    my $fields = $self->fields;

    for my $col ($source->columns) {
        my $def  = $col->perl_default or next;
        my $name = $col->name;

        $data->{$name} = $def->() unless exists $data->{$name};
    }

    my $has_pk = $self->_has_pk;

    my $stage2;
    if ($has_pk) {
        my $pk_fields = $self->{+SOURCE}->primary_key;

        if (@$pk_fields > 1) {
            croak "Database-Auto-Generated compound primary keys are not supported for databases that do not support 'returning on insert' functionality"
                if grep { !$data->{$_} } @$pk_fields;
        }

        $stage2 = sub {
            my ($dbh, $sth) = @_;

            my $kv    = $dbh->last_insert_id(undef, undef, $self->{+SOURCE}->source_db_moniker);
            my $where = {$pk_fields->[0] => $kv};

            my $sql  = $self->sql_builder->qorm_select(source => $source, where => $where, fields => $fields);
            my $sth2 = $self->make_sth($sql);
            $sth2->set_only_one(1);
            return ($sth2, $res);
        };
    }

    my $sth = $self->_do_query(
        builder_meth => 'qorm_insert',
        builder_args => [insert => $data],
        return_meth  => 'supports_returning_insert',
        fields       => $fields,
        has_pk       => $has_pk,

        no_returning_stage2 => $stage2,
        no_pk_return        => $data,
    );

    $sth->set_only_one(1);

    if ($sth->DOES('DBIx::QuickORM::Role::Async')) {
        return DBIx::QuickORM::Row::Async->new(
            async        => $sth,
            state_method => 'state_insert_row',
            state_args   => [row => $self->{+ROW}],
        );
    }

    return $self->{+CONNECTION}->state_insert_row(
        source  => $source,
        fetched => $sth->next,
        row     => $self->{+ROW},
    );
}

1;

__END__
    my $do_it = sub {
        my $sql = $self->sql_builder->qorm_insert(source => $source, insert => $data, $ret ? (returning => $fields) : ());
        my $sth = $self->make_sth($sql, @_);
        $sth->set_only_one(1);
        return $sth;
    };

    # 'returning' in sql makes things so much easier!
    if ($ret) {
        my $sth = $do_it->();

        # Super easy!
        if ($sync) {
            my $fetched = $sth->next;

            return $con->state_insert_row(
                source  => $source,
                fetched => $fetched,
                row     => $self->{+ROW},
            );
        }

        # Still not hard
        return DBIx::QuickORM::Row::Async->new(
            async        => $sth,
            state_method => 'state_insert_row',
            state_args   => [row => $self->{+ROW}],
        );
    }


    if (!$has_pk) {
        if ($sync) {
            $do_it->();
            $fetched = $data;

            return $con->state_insert_row(
                source  => $source,
                fetched => $fetched,
                row     => $self->{+ROW},
            );
        }

        my $sth = $do_it->(fetch_cb => sub { $data });
        return DBIx::QuickORM::Row::Async->new(
            async        => $sth,
            state_method => 'state_insert_row',
            state_args   => [row => $self->{+ROW}],
        );
    }

    croak "Auto-generated compound primary keys are not supported for databases that do not support 'returning on insert' functionality" if @$pk_fields > 1;

    if ($sync) {
        $self->_internal_txn(sub {
            my $sth = $do_it->();
            my $dbh = $sth->dbh;

            my $kv = $dbh->last_insert_id(undef, undef, $source->source_db_moniker);
            my $where = {$pk_fields->[0] => $kv};

            my $sql = $self->sql_builder->qorm_select(source => $source, where => $where, fields => $fields);
            my $sth2 = $self->make_sth($sql);
            $sth2->set_only_one(1);
            $fetched = $sth->next;
        });

        return $con->state_insert_row(
            source  => $source,
            fetched => $fetched,
            row     => $self->{+ROW},
        );
    }
}

__END__
sub delete {
    my $self = shift->handle(@_);

    my $con = $self->{+CONNECTION};
    $con->pid_and_async_check;

    croak "No row or where clause provided to the handle, nothing to delete"
        unless $self->{+WHERE} || $self->{+ROW};

    my $row      = $self->{+ROW};
    my $source   = $self->{+SOURCE};
    my $dialect  = $self->dialect;
    my $do_cache = $con->state_does_cache;
    my $ret      = $do_cache && $dialect->supports_returning_delete;

    my $pk_fields = $source->primary_key;

    my $where = $self->{+WHERE} // $self->sql_builder->qorm_where_for_row($self->{+ROW});

    my $deleted_keys;
    my $do_it = sub {
        my $sql = $self->sql_builder->qorm_delete(source => $source, where => $where, $ret ? (returning => $pk_fields) : (), limit => $self->{+LIMIT}, order_by => $self->{+ORDER_BY});
        my $sth = $self->_make_sth($sql);
        $deleted_keys = $sth->fetchall_arrayref({}) if $ret;
    };

    # If we are either not managing cache, or if we can use 'returning' then we
    # can do the easy way, no txn.
    if ($ret || !$do_cache || $row) {
        $do_it->();
        $deleted_keys //= [$row->primary_key_hashref] if $row;
    }
    else {
        $con->_internal_txn(sub {
            $deleted_keys = $self->_get_keys($source, $self->{+WHERE});
            $do_it->();
        });
    }

    if ($do_cache && $deleted_keys && @$deleted_keys) {
        $con->state_delete_row(source => $source, old_primary_key => $_) for @$deleted_keys;
    }

    return;
}

__END__
sub update {
    my $self = shift;
    my ($in) = @_;

    my $con = $self->{+CONNECTION};
    $con->pid_and_async_check;

    croak "update() cannot be used asynchronously" unless $self->is_sync;
    croak "update() with a 'limit' clause is not currently supported"     if $self->{+LIMIT};
    croak "update() with an 'order_by' clause is not currently supported" if $self->{+ORDER_BY};

    my (@rows, $changes);
    push @rows => $self->{+ROW} if $self->{+ROW};

    if ($in) {
        if (blessed($in) && $in->DOES('DBIx::QuickORM::Role::Row')) {
            push @rows => $in;
        }
        elsif (ref($in) eq 'HASH') {
            $changes = $in;
        }
        else {
            croak "Not sure what to do with update() input '$in'";
        }
    }

    my %seen;
    @rows = grep { $_ && !$seen{$_}++ } @rows;
    croak "Multiple rows provided to update(): " . join(', ' => map { $_->display } @rows) if @rows > 1;
    my ($row) = @rows;

    croak "Row provided to update() on a handle that already has a where clause" if $row && $self->{+WHERE} && !$self->{+ROW};

    $changes //= $row->pending_data if $row;

    croak "No changes for update"            unless $changes;
    croak "Changes must be a hashref"        unless ref($changes) eq 'HASH';
    croak "Changes hashref may not be empty" unless keys %$changes;

    my $source            = $self->{+SOURCE};
    my $pk_fields         = $source->primary_key;
    my $changes_pk_fields = grep { $changes->{$_} } @$pk_fields;

    my $dialect  = $self->dialect;
    my $do_cache = $con->state_does_cache;
    my $ret      = $do_cache && $dialect->supports_returning_update;

    my $where = $row ? $self->sql_builder->qorm_where_for_row($row) : $self->{+WHERE};

    # No cache, or not cachable, just do the update
    unless ($do_cache && $pk_fields && @$pk_fields) {
        my $sql = $self->sql_builder->qorm_update(source => $source, update => $changes, where => $self->{+WHERE});
        my $sth = $self-_>make_sth($sql);
        return $sth->rows;
    }

    my $fields;
    my $updated;
    my $do_it = sub {
        my $where = shift // $self->{+WHERE};
        my $sql = $self->sql_builder->qorm_update(source => $source, update => $changes, where => $where, $ret ? (returning => $fields) : ());
        my $sth = $self->_make_sth($source, $stmt, $bind, $query);
        $updated = $sth->fetchall_arrayref({}) if $ret;
    };

    # Simple case, updating a single row, or not updating any pks
    if ($row || !$changes_pk_fields) {
        my %seen;
        $fields = [grep { !$seen{$_}++ } @{$pk_fields // []}, keys %$changes];

        if ($ret) {
            $do_it->();
        }
        else {
            $self->_internal_txn(sub {
                my ($keys, $where) = $self->_get_keys($source, $query->{+QUERY_WHERE});

                $do_it->($where);

                my ($stmt, $bind) = $self->sql_builder->qorm_select($source, $fields, $where);
                my $sth = $self->_make_sth($source, $stmt, $bind, $query);
                $updated = $sth->fetchall_arrayref({});
            });
        }

        $self->{+MANAGER}->update($query->query_pairs, source => $source, connection => $self, fetched => $_) for @$updated;

        return scalar(@$updated);
    }

    # Not returning anything.
    $ret = 0;

    # Crap, we are changing pk's, possibly multiple, and no way to associate the before and after...
    my ($keys, $where);
    $self->_internal_txn(sub {
        ($keys, $where) = $self->_get_keys($source, $query->{+QUERY_WHERE});
        $do_it->($where);
    });

    $self->{+MANAGER}->invalidate($query->query_pairs, old_primary_key => $_) for @$keys;

    return;
}


sub all      { shift->handle(@_)->all }
sub iterator { shift->handle(@_)->iterator }
sub any      { shift->handle(@_)->any }
sub first    { shift->handle(@_)->first }
sub one      { shift->handle(@_)->one }
sub count    { shift->handle(@_)->count }
sub iterate  { }


sub update_or_insert { my $arg = pop; shift->handle(@_)->update_or_insert($arg) }
sub find_or_insert   { my $arg = pop; shift->handle(@_)->update_or_insert($arg) }

########################
# }}} Results Fetchers #
########################

1;

