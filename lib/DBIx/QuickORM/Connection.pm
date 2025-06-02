package DBIx::QuickORM::Connection;
use strict;
use warnings;
use feature qw/state/;

our $VERSION = '0.000011';

use Carp qw/confess croak cluck/;
use Scalar::Util qw/blessed weaken/;
use DBIx::QuickORM::Util qw/load_class/;

use DBIx::QuickORM::Handle;
use DBIx::QuickORM::Connection::Transaction;

use DBIx::QuickORM::Util::HashBase qw{
    <orm
    <dbh
    <dialect
    <pid
    <schema
    <transactions
    +_savepoint_counter
    +_txn_counter
    <manager
    <in_async
    <asides
    <forks
    <default_sql_builder
    <default_internal_txn
    <default_handle_class
};

sub init {
    my $self = shift;

    my $orm = $self->{+ORM} or croak "An orm is required";
    my $db = $orm->db;

    $self->{+_SAVEPOINT_COUNTER} = 1;
    $self->{+_TXN_COUNTER} = 1;

    $self->{+PID} //= $$;

    $self->{+DBH} = $db->new_dbh;

    $self->{+DIALECT} = $db->dialect->new(dbh => $self->{+DBH}, db_name => $db->db_name);

    $self->{+DEFAULT_INTERNAL_TXN} //= 1;

    $self->{+ASIDES} = {};
    $self->{+FORKS}  = {};

    $self->{+DEFAULT_HANDLE_CLASS} //= $orm->default_handle_class // 'DBIx::QuickORM::Handle';

    $self->{+DEFAULT_SQL_BUILDER} //= do {
        require DBIx::QuickORM::SQLBuilder::SQLAbstract;
        DBIx::QuickORM::SQLBuilder::SQLAbstract->new();
    };

    my $txns = $self->{+TRANSACTIONS} //= [];
    my $manager = $self->{+MANAGER} // 'DBIx::QuickORM::RowManager::Cached';
    if (blessed($manager)) {
        $manager->set_connection($self);
        $manager->set_transactions($txns);
    }
    else {
        my $class = load_class($manager) or die $@;
        $self->{+MANAGER} = $class->new(transactions => $txns, connection => $self);
    }

    if (my $autofill = $orm->autofill) {
        my $schema = $self->{+DIALECT}->build_schema_from_db(autofill => $autofill);

        if (my $schema2 = $orm->schema) {
            $self->{+SCHEMA} = $schema->merge($schema2);
        }
        else {
            $self->{+SCHEMA} = $schema->clone;
        }
    }
    else {
        $self->{+SCHEMA} = $orm->schema->clone;
    }
}

########################
# {{{ Async/Aside/Fork #
########################

sub set_async {
    my $self = shift;
    my ($async) = @_;

    croak "There is already an async query in progress" if $self->{+IN_ASYNC} && !$self->{+IN_ASYNC}->done;

    $self->{+IN_ASYNC} = $async;
    weaken($self->{+IN_ASYNC});

    return $async;
}

sub add_aside {
    my $self = shift;
    my ($aside) = @_;

    $self->{+ASIDES}->{$aside} = $aside;
    weaken($self->{+ASIDES}->{$aside});

    return $aside;
}

sub add_fork {
    my $self = shift;
    my ($fork) = @_;

    $self->{+FORKS}->{$fork} = $fork;
    weaken($self->{+FORKS}->{$fork});

    return $fork;
}

sub clear_async {
    my $self = shift;
    my ($async) = @_;

    croak "Not currently running an async query" unless $self->{+IN_ASYNC};

    croak "Mismatch, we are in an async query, but not the one we are trying to clear"
        unless $async == $self->{+IN_ASYNC};

    delete $self->{+IN_ASYNC};
}

sub clear_aside {
    my $self = shift;
    my ($aside) = @_;

    croak "Not currently running that aside query" unless $self->{+ASIDES}->{$aside};

    delete $self->{+ASIDES}->{$aside};
}

sub clear_fork {
    my $self = shift;
    my ($fork) = @_;

    croak "Not currently running that fork query" unless $self->{+FORKS}->{$fork};

    delete $self->{+FORKS}->{$fork};
}

########################
# }}} Async/Aside/Fork #
########################

#####################
# {{{ SANITY CHECKS #
#####################

sub pid_and_async_check {
    my $self = shift;
    return $self->pid_check && $self->async_check;
}

sub pid_check {
    my $self = shift;
    confess "Connections cannot be used across multiple processes, you must reconnect post-fork" unless $$ == $self->{+PID};
    return 1;
}

sub async_check {
    my $self = shift;

    my $async = $self->{+IN_ASYNC} or return 1;
    confess "There is currently an async query running, it must be completed before you run another query" unless $async->done;
    delete $self->{+IN_ASYNC};
    return 1;
}

#####################
# }}} SANITY CHECKS #
#####################

########################
# {{{ SIMPLE ACCESSORS #
########################

sub db { $_[0]->{+ORM}->db }
sub aside_dbh { $_[0]->{+ORM}->db->new_dbh }

########################
# }}} SIMPLE ACCESSORS #
########################

#####################
# {{{ STATE CHANGES #
#####################

sub reconnect {
    my $self = shift;

    my $dbh = delete $self->{+DBH};
    $dbh->{InactiveDestroy} = 1 unless $self->{+PID} == $$;
    $dbh->disconnect;

    $self->{+PID} = $$;
    $self->{+DBH} = $self->{+ORM}->db->new_dbh;
}

#####################
# }}} STATE CHANGES #
#####################

###########################
# {{{ TRANSACTION METHODS #
###########################

{
    no warnings 'once';
    *transaction = \&txn;
}
sub txn {
    my $self = shift;
    $self->pid_check;

    my @caller = caller;

    my $txns = $self->{+TRANSACTIONS};

    my $cb = (@_ && ref($_[0]) eq 'CODE') ? shift : undef;
    my %params = @_;
    $cb //= $params{action};

    croak "Cannot start a transaction while there is an active async query" if $self->{+IN_ASYNC} && !$self->{+IN_ASYNC}->done;

    unless ($params{force}) {
        unless ($params{ignore_aside}) {
            my $count = grep { $_ && !$_->done } values %{$self->{+ASIDES} // {}};
            croak "Cannot start a transaction while there is an active aside query (unless you use ignore_aside => 1, or force => 1)" if $count;
        }

        unless ($params{ignore_forks}) {
            my $count = grep { $_ && !$_->done } values %{$self->{+FORKS} // {}};
            croak "Cannot start a transaction while there is an active forked query (unless you use ignore_forked => 1, or force => 1)" if $count;
        }
    }

    my $id = $self->{+_TXN_COUNTER}++;

    my $dialect = $self->dialect;

    my $sp;
    if (@$txns) {
        $sp = "SAVEPOINT_${$}_" . $self->{+_SAVEPOINT_COUNTER}++;
        $dialect->create_savepoint(savepoint => $sp);
    }
    elsif ($self->dialect->in_txn) {
        croak "A transaction is already open, but it is not controlled by DBIx::QuickORM";
    }
    else {
        $dialect->start_txn;
    }

    my $txn = DBIx::QuickORM::Connection::Transaction->new(
        id            => $id,
        savepoint     => $sp,
        trace         => \@caller,
        on_fail       => $params{on_fail},
        on_success    => $params{on_success},
        on_completion => $params{on_completion},
    );

    my ($root, $parent) = @$txns ? (@{$txns}[0,-1]) : ($txn, $txn);

    $parent->add_fail_callback($params{'on_parent_fail'})             if $params{on_parent_fail};
    $parent->add_success_callback($params{'on_parent_success'})       if $params{on_parent_success};
    $parent->add_completion_callback($params{'on_parent_completion'}) if $params{on_parent_completion};
    $root->add_fail_callback($params{'on_root_fail'})                 if $params{on_root_fail};
    $root->add_success_callback($params{'on_root_success'})           if $params{on_root_success};
    $root->add_completion_callback($params{'on_root_completion'})     if $params{on_root_completion};

    push @{$txns} => $txn;

    my $finalize = sub {
        my ($ok, @errors) = @_;

        $txn->throw("Cannot stop a transaction while there is an active async query")
            if $self->{+IN_ASYNC} && !$self->{+IN_ASYNC}->done;

        $txn->throw("Internal Error: Transaction stack mismatch")
            unless @$txns && $txns->[-1] == $txn;

        pop @$txns;

        my $rolled_back = $txn->rolled_back;
        my $res         = $ok && !$rolled_back;

        if ($sp) {
            if   ($res) { $dialect->commit_savepoint(savepoint => $sp) }
            else        { $dialect->rollback_savepoint(savepoint => $sp) }
        }
        else {
            if   ($res) { $dialect->commit_txn }
            else        { $dialect->rollback_txn }
        }

        my ($ok2, $err2) = $txn->terminate($res, \@errors);
        unless ($ok2) {
            $ok = 0;
            push @errors => @$err2;
        }

        return if $ok;
        $txn->throw(join "\n" => @errors);
    };

    unless($cb) {
        $txn->set_finalize($finalize);
        return $txn;
    }

    local $@;
    my $ok = eval {
        QORM_TRANSACTION: { $cb->($txn) };
        1;
    };

    $finalize->($ok, $@);

    return $txn;
}

{
    no warnings 'once';
    *in_transaction = \&in_txn;
}
sub in_txn {
    my $self = shift;
    return $self->current_txn // $self->dialect->in_txn;
}

{
    no warnings 'once';
    *current_transaction = \&current_txn;
}
sub current_txn {
    my $self = shift;
    $self->pid_check;

    if (my $txns = $self->{+TRANSACTIONS}) {
        return $txns->[-1] if @$txns;
    }

    return undef;
}

sub auto_retry_txn {
    my $self = shift;
    $self->pid_check;
    $self->async_check;

    my $count;
    my %params;

    if (!@_) {
        croak "Not enough arguments";
    }
    elsif (@_ == 1 && ref($_[0]) eq 'CODE') {
        $count = 1;
        $params{action} = $_[0];
    }
    elsif (@_ == 2) {
        my $ref = ref($_[1]);
        if ($ref eq 'CODE') {
            $count = $_[0];
            $params{action} = $_[1];
        }
        elsif ($ref eq 'HASH') {
            $count  = $_[0];
            %params = %{$_[1]};
        }
        else {
            croak "Not sure what to do with second argument '$_[0]'";
        }
    }
    else {
        %params = @_;
        $count  = delete $params{count};
    }

    $count ||= 1;

    $self->auto_retry($count => sub { $self->txn(%params) });
}

###########################
# }}} TRANSACTION METHODS #
###########################

#######################
# {{{ UTILITY METHODS #
#######################

sub auto_retry {
    my $self  = shift;
    my $cb    = pop;
    my $count = shift || 1;
    $self->pid_check;
    $self->async_check;

    croak "Cannot use auto_retry inside a transaction" if $self->in_txn;

    my ($ok, $out);
    for (0 .. $count) {
        $ok = eval { $out = $cb->(); 1 };
        last if $ok;
        warn "Error encountered in auto-retry, will retry...\n Exception was: $@\n";
        $self->reconnect unless $self->{+DBH} && $self->{+DBH}->ping;
    }

    croak "auto_retry did not succeed (attempted " . ($count + 1) . " times)"
        unless $ok;

    return $out;
}

sub source {
    my $self = shift;
    my ($in, %params) = @_;

    if (blessed($in)) {
        return $in if $in->DOES('DBIx::QuickORM::Role::Source');
        return undef if $params{no_fatal};
        croak "'$in' does not implement the 'DBIx::QuickORM::Role::Source' role";
    }

    if (my $r = ref($in)) {
        if ($r eq 'SCALAR') {
            require DBIx::QuickORM::LiteralSource;
            return DBIx::QuickORM::LiteralSource->new($in);
        }

        return undef if $params{no_fatal};
        croak "Not sure what to do with '$r'";
    }

    my $source = $self->schema->table($in);
    return $source if $source;

    return undef if $params{no_fatal};
    croak "Could not find the '$in' table in the schema";
}

#######################
# }}} UTILITY METHODS #
#######################

#########################
# {{{ HANDLE OPERATIONS #
#########################

sub handle {
    my $self = shift;
    my ($in, @args) = @_;

    my $handle;
    if ((blessed($in) || !ref($in)) && ($in->isa('DBIx::QuickORM::Handle') || $in->DOES('DBIx::QuickORM::Role::Handle'))) {
        return $in unless @args;
        return $in->handle(@args);
    }

    return $self->{+DEFAULT_HANDLE_CLASS}->handle(connection => $self, @_);
}

sub all      { shift->handle(@_)->all }
sub iterator { shift->handle(@_)->iterator }
sub any      { shift->handle(@_)->any }
sub first    { shift->handle(@_)->first }
sub one      { shift->handle(@_)->one }
sub count    { shift->handle(@_)->count }
sub delete   { shift->handle(@_)->delete }

sub by_id   { my $arg = pop; shift->handle(@_)->by_id($arg) }
sub iterate { my $arg = pop; shift->handle(@_)->iterate($arg) }
sub insert  { my $arg = pop; shift->handle(@_)->insert($arg) }
sub vivify  { my $arg = pop; shift->handle(@_)->vivify($arg) }
sub update  { my $arg = pop; shift->handle(@_)->update($arg) }

sub update_or_insert { my $arg = pop; shift->handle(@_)->update_or_insert($arg) }
sub find_or_insert   { my $arg = pop; shift->handle(@_)->update_or_insert($arg) }

sub by_ids {
    my $self = shift;
    my ($from, @ids) = @_;

    my $handle;
    if (blessed($from) && $from->isa('DBIx::QuickORM::Handle')) {
        $handle = $from;
    }
    else {
        $handle = $self->handle(source => $from);
    }

    return $handle->by_ids(@ids);
}

#########################
# }}} HANDLE OPERATIONS #
#########################

########################
# {{{ STATE OPERATIONS #
########################

sub state_does_cache   { $_[0]->{+MANAGER}->does_cache }
sub state_delete_row   { my $self = shift; $self->{+MANAGER}->delete(connection => $self, @_) }
sub state_insert_row   { my $self = shift; $self->{+MANAGER}->insert(connection => $self, @_) }
sub state_select_row   { my $self = shift; $self->{+MANAGER}->select(connection => $self, @_) }
sub state_update_row   { my $self = shift; $self->{+MANAGER}->update(connection => $self, @_) }
sub state_vivify_row   { my $self = shift; $self->{+MANAGER}->vivify(connection => $self, @_) }
sub state_invalidate   { my $self = shift; $self->{+MANAGER}->invalidate(connection => $self, @_) }
sub state_cache_lookup { $_[0]->{+MANAGER}->do_cache_lookup($_[1], undef, undef, $_[2]) }

########################
# }}} STATE OPERATIONS #
########################

1;
