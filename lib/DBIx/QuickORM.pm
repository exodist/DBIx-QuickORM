package DBIx::QuickORM;
use strict;
use warnings;

our $VERSION = '0.000005';

use Carp qw/croak confess/;
$Carp::Internal{ (__PACKAGE__) }++;

use Storable qw/dclone/;
use Sub::Util qw/set_subname/;
use Scalar::Util qw/blessed/;

use Scope::Guard();

use DBIx::QuickORM::Util qw/load_class find_modules/;
use DBIx::QuickORM::Affinity qw/validate_affinity/;

use constant DBS     => 'dbs';
use constant ORMS    => 'orms';
use constant PACKAGE => 'package';
use constant SCHEMAS => 'schemas';
use constant SERVERS => 'servers';
use constant STACK   => 'stack';
use constant TYPE    => 'type';

my @EXPORT = qw{
    plugin
    plugins
    meta
    orm
    autofill
    alt

    build_class

    server
     driver
     dialect
     attributes
     host
     port
     socket
     user
     pass
     creds
     db
      connect
      dsn

    schema
     row_class
     tables
     table
     view
      db_name
      column
       omit
       nullable
       not_null
       identity
       affinity
       type
       sql
       default
      columns
      primary_key
      unique
      index
     link
};

sub import {
    my $class = shift;
    my ($type) = @_;

    $type //= 'orm';

    my $caller = caller;

    my $builder = $class->new(PACKAGE() => $caller, TYPE() => $type);

    my %export = (
        builder => set_subname("${caller}::builder" => sub { $builder }),
        import  => set_subname("${caller}::import" => sub { shift; $builder->import_into(scalar(caller), @_) }),
    );

    $export{ONE_TO_ONE}   = \&ONE_TO_ONE;
    $export{MANY_TO_MANY} = \&MANY_TO_MANY;
    $export{ONE_TO_MANY}  = \&ONE_TO_MANY;
    $export{MANY_TO_ONE}  = \&MANY_TO_ONE;

    for my $name (@EXPORT) {
        my $meth = $name;
        $export{$name} //= set_subname("${caller}::$meth" => sub { shift @_ if @_ && $_[0] && "$_[0]" eq $caller; $builder->$meth(@_) });
    }

    for my $sym (keys %export) {
        no strict 'refs';
        *{"${caller}\::${sym}"} = $export{$sym};
    }
}

sub _caller {
    my $self = shift;

    my $i = 0;
    while (my @caller = caller($i++)) {
        return unless @caller;
        next if eval { $caller[0]->isa(__PACKAGE__) };
        return \@caller;
    }

    return;
}

sub unimport {
    my $class = shift;
    my $caller = caller;

    $class->unimport_from($caller);
}

sub unimport_from {
    my $class = shift;
    my ($caller) = @_;

    my $stash = do { no strict 'refs'; \%{"$caller\::"} };

    for my $item (@EXPORT) {
        my $export = $class->can($item)  or next;
        my $sub    = $caller->can($item) or next;

        next unless $export == $sub;

        my $glob = delete $stash->{$item};

        {
            no strict 'refs';
            no warnings 'redefine';

            for my $type (qw/SCALAR HASH ARRAY FORMAT IO/) {
                next unless defined(*{$glob}{$type});
                *{"$caller\::$item"} = *{$glob}{$type};
            }
        }
    }
}

sub new {
    my $class = shift;
    my %params = @_;

    croak "'package' is a required attribute" unless $params{+PACKAGE};

    $params{+STACK}   //= [{base => 1, plugins => [], building => '', build => 'Should not access this', meta => 'Should not access this'}];

    $params{+ORMS}    //= {};
    $params{+DBS}     //= {};
    $params{+SCHEMAS} //= {};
    $params{+SERVERS} //= {};

    return bless(\%params, $class);
}

sub import_into {
    my $self = shift;
    my ($caller, $name, @extra) = @_;

    croak "Not enough arguments, caller is required" unless $caller;
    croak "Too many arguments" if @extra;

    $name //= 'qorm';

    no strict 'refs';
    *{"${caller}\::${name}"} = sub {
        return $self unless @_;
        return $self->orm(@_) if @_ == 1;
        my ($type, $name, @extra) = @_;
        croak "Too many arguments" if @extra;
        croak "'$type' is not a valid item type to fetch from '$caller'" unless $type =~ m/^(orm|db|schema)$/;
        return $self->$type($name);
    };
}

sub top {
    my $self = shift;
    return $self->{+STACK}->[-1];
}

sub alt {
    my $self = shift;
    my $top = $self->top;
    croak "alt() cannot be used outside of a builder" if $top->{base};
    my ($name, $builder) = @_;

    my $frame = $top->{alt}->{$name} // {building => $top->{building}, name => $name, meta => {}};
    return $self->_build(
        'Alt',
        into => $top->{alt} //= {},
        frame => $frame,
        args => [$name, $builder],
    );
}

sub plugin {
    my $self = shift;
    my ($proto, @proto_params) = @_;

    if (blessed($proto)) {
        croak "Cannot pass in both a blessed plugin instance and constructor arguments" if @proto_params;
        if ($proto->isa('DBIx::QuickORM::Plugin')) {
            push @{$self->top->{plugins}} => $proto;
            return $proto;
        }
        croak "$proto is not an instance of 'DBIx::QuickORM::Plugin' or a subclass of it";
    }

    my $class = load_class($proto, 'DBIx::QuickORM::Plugin') or croak "Could not load plugin '$proto': $@";
    croak "$class is not a subclass of DBIx::QuickORM::Plugin" unless $class->isa('DBIx::QuickORM::Plugin');

    my $params = @proto_params == 1 ? shift(@proto_params) : { @proto_params };

    my $plugin = $class->new(%$params);
    push @{$self->top->{plugins}} => $plugin;
    return $plugin;
}

sub plugins {
    my $self = shift;

    # Return a list of plugins if no arguments were provided
    return [map { @{$_->{plugins} // []} } reverse @{$self->{+STACK}}]
        unless @_;

    my @out;

    while (my $proto = shift @_) {
        if (@_ && ref($_[0]) eq 'HASH') {
            my $params = shift @_;
            push @out => $self->plugin($proto, $params);
        }
        else {
            push @out => $self->plugin($proto);
        }
    }

    return \@out;
}

sub meta {
    my $self = shift;

    croak "Cannot access meta without a builder" unless @{$self->{+STACK}} > 1;
    my $top = $self->top;

    return $top->{meta} unless @_;

    %{$top->{meta}} = (%{$top->{meta}}, @_);

    return $top->{meta};
}

sub build_class {
    my $self = shift;

    croak "Not enough arguments" unless @_;

    my ($proto) = @_;

    croak "You must provide a class name" unless $proto;

    my $class = load_class($proto) or croak "Could not load class '$proto': $@";

    croak "Cannot set the build class without a builder" unless @{$self->{+STACK}} > 1;

    $self->top->{class} = $class;
}

sub server {
    my $self = shift;

    my $top   = $self->top;
    my $into  = $self->{+SERVERS};
    my $frame = {building => 'SERVER'};

    return $self->_build('Server', into => $into, frame => $frame, args => \@_);
}

sub db {
    my $self = shift;

    my $top = $self->top;

    my $bld_orm = 0;
    if ($top->{building} eq 'ORM') {
        croak "DB has already been defined" if $top->{meta}->{db};
        $bld_orm = 1;
    }

    if (@_ == 1 && $_[0] =~ m/^(\S+)\.([^:\s]+)(?::(\S+))?$/) {
        my ($server_name, $db_name, $variant_name) = ($1, $2, $3);

        my $server = $self->{+SERVERS}->{$server_name} or croak "'$server_name' is not a defined server";
        my $db = $server->{meta}->{dbs}->{$db_name} or croak "'$db_name' is not a defined database on server '$server_name'";

        return $top->{meta}->{db} = $db if $bld_orm;
        return $self->compile($db, $variant_name);
    }

    my $into = $self->{+DBS};
    my $frame = {building => 'DB', class => 'DBIx::QuickORM::DB'};

    return $top->{meta}->{db} = $self->_build('DB', into => $into, frame => $frame, args => \@_, no_compile => 1)
        if $bld_orm;

    my $force_build = 0;
    if ($top->{building} eq 'SERVER') {
        $force_build = 1;

        $frame = {
            %$frame,
            %{$top},
            building => 'DB',
            meta => {%{$top->{meta}}},
            server => $top->{name} // $top->{created},
        };

        delete $frame->{name};
        delete $frame->{meta}->{name};
        delete $frame->{meta}->{dbs};
        delete $frame->{prefix} unless defined $frame->{prefix};

        $into = $top->{meta}->{dbs} //= {};
    }

    return $self->_build('DB', into => $into, frame => $frame, args => \@_, force_build => $force_build);
}

sub autofill {
    my $self = shift;

    my $top = $self->_in_builder(qw{orm});

    $top->{meta}->{autofill} = 1;
}

sub driver {
    my $self = shift;
    my ($proto) = @_;

    my $top = $self->_in_builder(qw{db server});

    my $class = load_class($proto, 'DBD') or croak "Could not load DBI driver '$proto': $@";

    $top->{meta}->{dbi_driver} = $class;
}

sub dialect {
    my $self = shift;
    my ($dialect) = @_;

    my $top = $self->_in_builder(qw{db server});

    my $class = load_class($dialect, 'DBIx::QuickORM::Dialect') or croak "Could not load dialect '$dialect': $@";

    $top->{meta}->{dialect} = $class;
}

sub connect {
    my $self = shift;
    my ($cb) = @_;

    my $top = $self->_in_builder(qw{db server});

    croak "connect must be given a coderef as its only argument, got '$cb' instead" unless ref($cb) eq 'CODE';

    $top->{meta}->{connect} = $cb;
}

sub attributes {
    my $self = shift;
    my $attrs = @_ == 1 ? $_[0] : {@_};

    my $top = $self->_in_builder(qw{db server});

    croak "attributes() accepts either a hashref, or (key => value) pairs"
        unless ref($attrs) eq 'HASH';

    $top->{meta}->{attributes} = $attrs;
}

sub creds {
    my $self = shift;
    my ($in) = @_;

    croak "creds() accepts only a coderef as an argument" unless $in && ref($in) eq 'CODE';
    my $data = $in->();

    my $top = $self->_in_builder(qw{db server});

    croak "The subroutine passed to creds() must return a hashref" unless $data && ref($data) eq 'HASH';

    my %creds;

    $creds{user}   = $data->{user} or croak "No 'user' key in the hash returned by the credential subroutine";
    $creds{pass}   = $data->{pass} or croak "No 'pass' key in the hash returned by the credential subroutine";
    $creds{socket} = $data->{socket} if $data->{socket};
    $creds{host}   = $data->{host}   if $data->{host};
    $creds{port}   = $data->{port}   if $data->{port};

    croak "Neither 'host' or 'socket' keys were provided by the credential subroutine" unless $creds{host} || $creds{socket};

    my @keys = keys %creds;
    @{$top->{meta} // {}}{@keys} = @creds{@keys};

    return;
}

sub dsn    { $_[0]->_in_builder(qw{db server})->{meta}->{dsn}    = $_[1] }
sub host   { $_[0]->_in_builder(qw{db server})->{meta}->{host}   = $_[1] }
sub port   { $_[0]->_in_builder(qw{db server})->{meta}->{port}   = $_[1] }
sub socket { $_[0]->_in_builder(qw{db server})->{meta}->{socket} = $_[1] }
sub user   { $_[0]->_in_builder(qw{db server})->{meta}->{user}   = $_[1] }
sub pass   { $_[0]->_in_builder(qw{db server})->{meta}->{pass}   = $_[1] }

sub schema {
    my $self = shift;

    my $into  = $self->{+SCHEMAS};
    my $frame = {building => 'SCHEMA', class => 'DBIx::QuickORM::Schema'};

    my $top = $self->top;
    if ($top->{building} eq 'ORM') {
        croak "Schema has already been defined" if $top->{meta}->{schema};
        return $top->{meta}->{schema} = $self->_build('Schema', into => $into, frame => $frame, args => \@_, no_compile => 1);
    }

    return $self->_build('Schema', into => $into, frame => $frame, args => \@_);
}

sub tables {
    my $self = shift;

    my $top = $self->_in_builder(qw{schema});
    my $into = $top->{meta}->{tables} //= {};

    my (@modules, $cb);
    for my $arg (@_) {
        if (ref($arg) eq 'CODE') {
            croak "Only 1 callback is supported" if $cb;
            $cb = $arg;
            next;
        }

        push @modules => $arg;
    }

    $cb //= sub { ($_[0]->{name}, $_[0]) };

    for my $mod (find_modules(@modules)) {
        my $table = $self->_load_table($mod);
        my ($name, $data) = $cb->($table);
        next unless $name && $data;
        $into->{$name} = $data;
    }

    return;
}

sub _load_table {
    my $self = shift;
    my ($class) = @_;

    load_class($class) or croak "Could not load table class '$class': $@";
    croak "Class '$class' does not appear to define a table (no qorm_table() method)" unless $class->can('qorm_table');
    my $table = $class->qorm_table() or croak "Class '$class' appears to have an empty table";
    return $table;
}

sub table {
    my $self = shift;
    $self->_table('DBIx::QuickORM::Schema::Table', @_);
}

sub view {
    my $self = shift;
    $self->_table('DBIx::QuickORM::Schema::View', @_);
}

sub _table {
    my $self = shift;
    my $make = shift;

    # Defining a table in a table (row) class
    if (@{$self->{+STACK}} == 1 && $self->{+TYPE} eq 'table') {
        my $into  = \($self->top->{table});
        my $frame = {building => 'TABLE', class => $make};
        $self->_build('Table', into => $into, frame => $frame, args => \@_);
        my $table = $$into;

        $self->unimport_from($self->{+PACKAGE});

        my $pkg       = $self->{+PACKAGE};
        my $row_class = $table->{row_class} // '+DBIx::QuickORM::Row';
        my $loaded_class = load_class($row_class, 'DBIx::QuickORM::Row') or croak "Could not load row class '$row_class': $@";
        $table->{row_class} = $self->{+PACKAGE};
        $table->{meta}->{row_class} = $self->{+PACKAGE};

        {
            no strict 'refs';
            *{"$pkg\::qorm_table"} = sub { dclone($table) };
            push @{"$pkg\::ISA"} => $loaded_class;
        }

        return $table;
    }

    my $top = $self->_in_builder(qw{schema});
    my $into = $top->{meta}->{tables} //= {};

    # One of these:
    #   table NAME => CLASS, sub ...;
    #   table NAME => CLASS;
    #   table CLASS;
    #   table CLASS => sub ...;
    if ($_[0] =~ m/::/ || $_[1] && $_[1] =~ m/::/) {
        my @args = @_;
        my ($class, $name, $cb, $no_match);

        while (my $arg = shift @args) {
            if    ($arg =~ m/::/) { $class = $arg }
            elsif (my $ref = ref($arg)) {
                if   ($ref eq 'CODE') { $cb       = $arg }
                else                  { $no_match = 1; last }
            }
            else { $name = $arg }
        }

        if ($class && !$no_match) {
            my $table = $self->_load_table($class);
            $name //= $table->{name};
            $into->{$name} = $table;

            $self->_build('Table', frame => $table, args => [$cb], void => 1) if $cb;

            return $table;
        }

        # Fallback to regular build
    }

    # Typical case `table NAME => sub { ... }` or `table NAME => { ... }`
    my $frame = {building => 'TABLE', class => $make, meta => {row_class => $top->{meta}->{row_class}}};
    return $self->_build('Table', into => $into, frame => $frame, args => \@_);
}

sub index {
    my $self = shift;
    my ($name, $cols, $params);

    while (my $arg = shift @_) {
        my $ref = ref($arg);
        if    (!$ref)           { $name = $arg }
        elsif ($ref eq 'HASH')  { $params = {%{$params // {}}, %{$arg}} }
        elsif ($ref eq 'ARRAY') { $cols = $arg }
        else                    { croak "Not sure what to do with '$arg'" }
    }

    my $index = { %{$params // {}}, name => $name, columns => $cols };

    return $index if defined wantarray;

    my $top = $self->_in_builder(qw{table});

    push @{$top->{meta}->{indexes}} => $index;
}

sub column {
    my $self = shift;

    my $top = $self->_in_builder(qw{table});

    $top->{column_order} //= 1;
    my $order = $top->{column_order}++;

    my $into  = $top->{meta}->{columns} //= {};
    my $frame = {building => 'COLUMN', class => 'DBIx::QuickORM::Schema::Table::Column', meta => {order => $order}};

    return $self->_build(
        'Column',
        into     => $into,
        frame    => $frame,
        args     => \@_,
        extra_cb => sub {
            my $self = shift;
            my %params = @_;

            my $extra = $params{extra};
            my $meta  = $params{meta};

            while (my $arg = shift @$extra) {
                local $@;
                if (blessed($arg)) {
                    if ($arg->isa('DBIx::QuickORM::Type')) {
                        $meta->{type} = $arg;
                    }
                    else {
                        croak "'$arg' does not subclass 'DBIx::QuickORM::Type'";
                    }
                }
                elsif (my $ref = ref($arg)) {
                    if ($ref eq 'SCALAR') {
                        $meta->{type} = $arg;
                    }
                    else {
                        croak "Not sure what to do with column argument '$arg'";
                    }
                }
                elsif ($arg eq 'id' || $arg eq 'identity') {
                    $meta->{identity} = 1;
                }
                elsif ($arg eq 'not_null') {
                    $meta->{nullable} = 0;
                }
                elsif ($arg eq 'nullable') {
                    $meta->{nullable} = 1;
                }
                elsif ($arg eq 'omit') {
                    $meta->{omit} = 1;
                }
                elsif ($arg eq 'sql_default' || $arg eq 'perl_default') {
                    $meta->{$arg} = shift @$extra;
                }
                elsif (validate_affinity($arg)) {
                    $meta->{affinity} = $arg;
                }
                elsif (my $class = load_class($arg, 'DBIx::QuickORM::Type')) {
                    croak "Class '$class' is not a subclass of DBIx::QuickORM::Type" unless $class->isa('DBIx::QuickORM::Type');
                    $meta->{type} = $class;
                }
                else {
                    croak "Error loading class for type '$arg': $@" unless $@ =~ m/^Can't locate .+ in \@INC/;
                    croak "Column arg '$arg' does not appear to be pure-sql (scalar ref), affinity, or a DBIx::QuickORM::Type subclass";
                }
            }
        },
    );
}

sub columns {
    my $self = shift;

    my $top = $self->_in_builder(qw{table});

    my (@names, $other);
    for my $arg (@_) {
        my $ref = ref($arg);
        if    (!$ref)          { push @names => $arg }
        elsif ($ref eq 'HASH') { croak "Cannot provide multiple hashrefs" if $other; $other = $arg }
        else                   { croak "Not sure what to do with '$arg' ($ref)" }
    }

    return [map { $self->column($_, $other) } @names] if defined wantarray;

    $self->column($_, $other) for @names;

    return;
}

sub sql {
    my $self = shift;

    croak "Not enough arguments" unless @_;
    croak "Too many arguments" if @_ > 2;

    my $sql = pop;
    my $affix = lc(pop // 'infix');

    croak "'$affix' is not a valid sql position, use 'prefix', 'infix', or 'postfix'" unless $affix =~ m/^(pre|post|in)fix$/;

    my $top = $self->_in_builder(qw{schema table column});

    if ($affix eq 'infix') {
        croak "'infix' sql is not supported in SCHEMA, use prefix or postfix" if $top->{building} eq 'SCHEMA';
        croak "'infix' sql has already been set for '$top->{created}'"        if $top->{meta}->{sql}->{$affix};
        $top->{meta}->{sql}->{$affix} = $sql;
    }
    else {
        push @{$top->{meta}->{sql}->{$affix}} => $sql;
    }
}

sub affinity {
    my $self = shift;
    croak "Not enough arguments" unless @_;
    my ($affinity) = @_;

    croak "'$affinity' is not a valid affinity" unless validate_affinity($affinity);

    return $affinity if defined wantarray;

    my $top = $self->_in_builder(qw{column});
    $top->{meta}->{affinity} = $affinity;
}

sub _check_type {
    my $self = shift;
    my ($type) = @_;

    return $type if ref($type) eq 'SCALAR';
    return undef if ref($type);
    return $type if $type->isa('DBIx::QuickORM::Type');

    my $class = load_class($type, 'DBIx::QuickORM::Type') or return undef;
    return $class;
}

sub type {
    my $self = shift;
    croak "Not enough arguments" unless @_;
    my ($type, @args) = @_;

    croak "Too many arguments" if @args;
    croak "cannot use a blessed instance of the type ($type)" if blessed($type);

    local $@;
    my $use_type = $self->_check_type($type);
    unless ($use_type) {
        my $err = "Type must be a scalar reference, or a class that inherits from 'DBIx::QuickORM::Type', got: $type";
        $err .= "\nGot exception: $@" if $@ =~ m/^Can't locate .+ in \@INC/;
        confess $err;
    }

    return $use_type if defined wantarray;

    my $top = $self->_in_builder(qw{column});
    $top->{meta}->{type} = $use_type;
}

sub omit     { defined(wantarray) ? (($_[1] // 1) ? 'omit'     : ())         : ($_[0]->_in_builder('column')->{meta}->{omit}     = $_[1] // 1) }
sub identity { defined(wantarray) ? (($_[1] // 1) ? 'identity' : ())         : ($_[0]->_in_builder('column')->{meta}->{identity} = $_[1] // 1) }
sub nullable { defined(wantarray) ? (($_[1] // 1) ? 'nullable' : 'not_null') : ($_[0]->_in_builder('column')->{meta}->{nullable} = $_[1] // 1) }
sub not_null { defined(wantarray) ? (($_[1] // 1) ? 'not_null' : 'nullable') : ($_[0]->_in_builder('column')->{meta}->{nullable} = $_[1] ? 0 : 1) }

sub default {
    my $self = shift;
    my ($val) = @_;

    my $r = ref($val);

    my ($key);
    if    ($r eq 'SCALAR') { $key = 'sql_default'; $val = $$val }
    elsif ($r eq 'CODE')   { $key = 'perl_default' }
    else                   { croak "'$val' is not a valid default, must be a scalar ref, or a coderef" }

    return ($key => $val) if defined wantarray;

    my $top = $self->_in_builder('column');
    $top->{meta}->{$key} = $val;
}

sub _in_builder {
    my $self = shift;
    my %builders = map { lc($_) => 1 } @_;

    if (@{$self->{+STACK}} > 1) {
        my $top = $self->top;
        my $bld = lc($top->{building});

        return $top if $builders{$bld};
    }

    my ($pkg, $file, $line, $name) = caller(0);
    ($pkg, $file, $line, $name) = caller(1) if $name =~ m/_in_builder/;

    croak "${name}() can only be used inside one of the following builders: " . join(', ', @_);
}

sub db_name {
    my $self = shift;
    my ($db_name) = @_;

    my $top = $self->_in_builder(qw{table column db});

    $top->{meta}->{name} = $db_name;
}

sub row_class {
    my $self = shift;
    my ($proto) = @_;

    my $top = $self->_in_builder(qw{table schema});

    my $class = load_class($proto, 'DBIx::QuickORM::Row') or croak "Could not load class '$proto': $@";

    $top->{meta}->{row_class} = $class;
}

sub primary_key {
    my $self = shift;
    my (@list) = @_;

    my $top = $self->_in_builder(qw{table column});

    my $meta;
    if ($top->{building} eq 'COLUMN') {
        my $frame = $self->{+STACK}->[-2];

        croak "Too many arguments" if @list;

        croak "Could not find table for the column currently being built"
            unless $frame->{building} eq 'TABLE';

        @list = ($top->{meta}->{name});
        $meta = $frame->{meta};
    }
    else {
        croak "Not enough arguments" unless @list;
        $meta = $top->{meta};
    }

    $meta->{primary_key} = \@list;
}

sub unique {
    my $self = shift;
    my (@list) = @_;

    my $top = $self->_in_builder(qw{table column});

    my $meta;
    if ($top->{building} eq 'COLUMN') {
        my $frame = $self->{+STACK}->[-2];

        croak "Too many arguments" if @list;

        croak "Could not find table for the column currently being built"
            unless $frame->{building} eq 'TABLE';

        @list = ($top->{meta}->{name});
        $meta = $frame->{meta};
    }
    else {
        croak "Not enough arguments" unless @list;
        $meta = $top->{meta};
    }

    my $key = join ', ' => sort @list;

    $meta->{unique}->{$key} = \@list;
    push @{$meta->{indexes}} => {unique => 1, columns => \@list};
}

sub link {
    my $self = shift;
    my @args = @_;

    my $top = $self->_in_builder(qw{schema column});

    my ($table, $local);
    if ($top->{building} eq 'COLUMN') {
        my $alias = @args && !ref($args[0]) ? shift @args : undef;
        croak "Expected an arrayref, got '$args[0]'" unless ref($args[0]) eq 'ARRAY';
        @args = @{$args[0]};

        my $cols = [$top->{meta}->{name}];

        croak "Could not find table?" unless $self->{+STACK}->[-2]->{building} eq 'TABLE';

        $table = $self->{+STACK}->[-2];
        my $tname = $table->{name};

        $local = [$tname, $cols];
        push @$local => $alias if $alias;
    }

    my @nodes;
    while (my $first = shift @args) {
        my $fref = ref($first);
        if (!$fref) {
            my $second = shift(@args);
            my $sref = ref($second);

            croak "Expected an array, got '$second'" unless $sref && $sref eq 'ARRAY';
            my $eref = ref($second->[1]);
            if ($eref && $eref eq 'ARRAY') {
                push @nodes => [$second->[0], $second->[1], $first];
            }
            else {
                push @nodes => [$first, $second];
            }

            next;
        }

        if ($fref eq 'HASH') {
            push @nodes => [$first->{table}, $first->{columns}, $first->{alias}];
            next;
        }

        croak "Expected a hashref, table name, or alias, got '$first'";
    }

    my $other;
    if ($local) {
        croak "Too many nodes" if @nodes > 1;
        croak "Not enough nodes" unless @nodes;
        ($other) = @nodes;
    }
    else {
        ($local, $other) = @nodes;
    }

    my $caller = $self->_caller;
    my $created = "$caller->[3]() at $caller->[1] line $caller->[2]";
    my $link = [$local, $other, $created];

    push @{($table // $top)->{meta}->{_links}} => $link;

    return;
}

sub orm {
    my $self = shift;

    my $into  = $self->{+ORMS};
    my $frame = {building => 'ORM', class => 'DBIx::QuickORM::ORM'};

    $self->_build('ORM', into => $into, frame => $frame, args => \@_);
}

my %RECURSE = (
    DB     => {},
    LINK   => {},
    COLUMN => {},
    ORM    => {schema  => 1, db => 1},
    SCHEMA => {tables  => 2},
    TABLE  => {columns => 2},
);

sub compile {
    my $self = shift;
    my ($frame, $alt_arg) = @_;

    my $alt = $alt_arg || ':';

    # Already compiled
    return $frame->{__COMPILED__}->{$alt} if $frame->{__COMPILED__}->{$alt};

    my $bld = $frame->{building} or confess "Not currently building anything";
    my $recurse = $RECURSE{$bld} or croak "Not sure how to compile '$bld'";

    my $meta = $frame->{meta};
    my $alta = $alt_arg && $frame->{alt}->{$alt_arg} ? $frame->{alt}->{$alt_arg}->{meta} // {} : {};

    my %obj_data;

    my %seen;
    for my $field (keys %$meta, keys %$alta) {
        next if $seen{$field}++;

        my $val = $self->_merge($alta->{$field}, $meta->{$field}) // next;

        unless($recurse->{$field}) {
            $obj_data{$field} = $val;
            next;
        }

        if ($recurse->{$field} > 1) {
            $obj_data{$field} = { map { $_ => $self->compile($val->{$_}, $alt_arg) } keys %$val };
        }
        else {
            $obj_data{$field} = $self->compile($val, $alt_arg);
        }
    }

    my $proto = $frame->{class} or croak "No class to compile for '$frame->{name}' ($frame->{created})";
    my $class = load_class($proto) or croak "Could not load class '$proto' for '$frame->{name}' ($frame->{created}): $@";

    my $caller = $self->_caller;
    my $compiled = "$caller->[3]() at $caller->[1] line $caller->[2]";

    $obj_data{compiled} = $compiled;

    my $out = eval { $class->new(%obj_data) } or confess "Could not construct an instance of '$class': $@";
    $frame->{__COMPILED__}->{$alt} = $out;

    return $out;
}

sub _merge {
    my $self = shift;
    my ($a, $b) = @_;

    return $a unless defined $b;
    return $b unless defined $a;

    my $ref_a = ref($a);
    my $ref_b = ref($b);
    croak "Mismatched reference!" unless $ref_a eq $ref_b;

    # Not a ref, a wins
    return $a // $b unless $ref_a;

    return { %$a, %$b } if $ref_a eq 'HASH';

    croak "Not sure how to merge $a and $b";
}

sub _build {
    my $self = shift;
    my ($type, %params) = @_;

    my $into        = $params{into};
    my $frame       = $params{frame};
    my $args        = $params{args};
    my $extra_cb    = $params{extra_cb};
    my $force_build = $params{force_build};

    croak "Not enough arguments" unless $args && @$args;

    my $caller = $self->_caller;

    my ($name, $builder, $meta_arg, @extra);
    for my $arg (@$args) {
        my $ref = ref($arg);
        if    (!$ref)          { if ($name) { push @extra => $arg } else { $name = $arg } }
        elsif ($ref eq 'CODE') { croak "Multiple builders provided!" if $builder; $builder = $arg }
        elsif ($ref eq 'HASH') { croak "Multiple meta hashes provided!" if $meta_arg; $meta_arg = $arg }
        else                   { push @extra => $arg }
    }

    $force_build = 1 if @extra;
    my $alt = $name && $name =~ s/:(\S+)$// ? $1 : undef;
    $name = undef if defined($name) && !length($name);

    my $meta = $meta_arg // {};
    $self->$extra_cb(%params, type => $type, extra => \@extra, meta => $meta, name => $name, frame => $frame) if $extra_cb;
    croak "Multiple names provided: " . join(', ' => $name, @extra) if @extra;

    # Simple fetch
    if ($name && !$builder && !$meta_arg && !$force_build) {
        croak "'$name' is not a defined $type" unless $into->{$name};
        return $self->compile($into->{$name}, $alt) unless $params{no_compile};
        return $into->{$name};
    }

    my $created = "$caller->[3]() at $caller->[1] line $caller->[2]";
    %$frame = (
        %$frame,
        plugins  => [],
        created  => $created,
    );

    $frame->{name} //= $name // "Anonymous builder ($created)";

    $frame->{meta} = { %{$frame->{meta} // {}}, %{$meta} };

    $frame->{meta}->{name} = $name if $name && $type ne 'Alt';

    $frame->{meta}->{created} = $created;

    push @{$self->{+STACK}} => $frame;

    my $ok = eval {
        $builder->(meta => $meta, frame => $frame) if $builder;
        $_->munge($frame) for @{$self->plugins};
        1;
    };
    my $err = $@;

    pop @{$self->{+STACK}};

    die $err unless $ok;

    if ($into) {
        my $ref = ref($into);
        if ($ref eq 'HASH') {
            $into->{$name} = $frame if $name;
        }
        elsif ($ref eq 'SCALAR') {
            ${$into} = $frame;
        }
        else {
            croak "Invalid 'into': $into";
        }
    }

    return if $params{void};

    if (defined wantarray) {
        return $self->compile($frame, $alt) unless $params{no_compile};
        return $frame;
    }

    return if $name;

    croak "No name provided, but called in void context!";
}

1;

__END__

=head1 NAME

DBIx::QuickORM - Composable ORM builder.

=head1 DESCRIPTION

DBIx::QuickORM allows you to define ORM's with reusable and composible parts.

With this ORM builder you can specify:

=over 4

=item How to connect to one or more databases on one or more servers.

=item One or more schema structures.

=item Custom row classes to use.

=item Plugins to use.

=back

=head1 SYNOPSIS

The common use case is to create an ORM package for your app, then use that ORM
package any place in the app that needs ORM access.

The ORM class

=head2 YOUR ORM PACKAGE

    package My::ORM;
    use DBIx::QuickORM;

    # Define your ORM
    orm my_orm => sub {

        # Define your object
        db my_db => sub {
            host 'mydb.mydomain.com';
            port 1234;

            # Best not to hardcode these, read them from a secure place and pass them in here.
            user $USER;
            pass $PASS;
        };

        # Define your schema
        schema myschema => sub {
            table my_table => sub {
                column id => sub {
                    identity;
                    primary_key;
                    not_null;
                };

                column name => sub {
                    type \'VARCHAR(128)';    # Exact SQL for the type
                    affinity 'string';       # required if other information does not make it obvious to DBIx::QuickORM
                    unique;
                    not_null;
                };

                column added => sub {
                    type 'Stamp';            # Short for DBIx::QuickORM::Type::Stamp
                    not_null;

                    # Exact SQL to use if DBIx::QuickORM generates the table SQL
                    default \'NOW()';

                    # Perl code to generate a default value when rows are created by DBIx::QuickORM
                    default sub { ... };
                };
            };
        };
    };

=head2 YOUR APP CODE

    package My::App;
    use My::Orm qw/orm/;

    my $orm = orm('my_orm');
    my $db = $orm->db;
    my $schema = $orm->schema;

    FIXME: Now use the ORM

=head1 A NOTE ON AFFINITY

Whenever you define a column in DBIx::QuickORM it is necessary for the orm to
know the 'affinity' of the column. It may be any of these:

=over 4

=item string

The column should be treated as a string when written to, or read from the
database.

=item numeric

The column should be treated as a number when written to, or read from the
database.

=item boolean

The column should be treated as a boolean when written to, or read from the
database.

=item binary

The column should be treated as a binary data when written to, or read from the
database.

=back

Much of the time the affinity can be derived from other data. The
L<DBIx::QuickORM::Affinity> package has an internal map for default affinities
for many sql types. Also if you use a L<DBIx::QuickORM::Type> subclass it will
often provide an affinity. You can override the affinity if necessary. If the
affinity cannot be derived you must specify it.

=head1 RECIPES

=head2 DEFINE TABLES IN THEIR OWN PACKAGES/FILES

If you have many tables, or want each to have a custom row class (custom
methods for items returned by tables), then you probably want to define tables
in their own files.

When you follow this example you create the table My::ORM::Table::Foo. The
package will automatically subclass L<DBIx::QuickORM::Row> unless you use
C<row_class()> to set an alternative base.

Any methods added in the file will be callable on the rows returned when
querying this table.

First create My/ORM/Table/Foo.pm:

    package My::ORM::Table::Foo;
    use DBIx::QuickORM 'table';

    # Calling this will define the table. It will also:
    #  * Remove all functions imported from DBIx::QuickORM
    #  * Set the base class to DBIx::QuickORM::Row, or to whatever class you specify with 'row_class'.
    table foo => sub {
        column a => sub { ... };
        column b => sub { ... };
        column c => sub { ... };

        ....

        # This is the default, but you can change it to set an alternate base class.
        row_class 'DBIx::QuickORM::Row';
    };

    sub custom_row_method {
        my $self = shift;
        ...
    }

Then in your ORM package:

    package My::ORM;

    schema my_schema => sub {
        table 'My::ORM::Table::Foo'; # Bring in the table
    };

Or if you have many tables and want to load all the tables under My::ORM::Table:: at once:

    schema my_schema => sub {
        tables 'My::ORM::Table';
    };

=head2 APP THAT CAN USE NEARLY IDENTICAL MYSQL AND POSTGRESQL DATABASES

Lets say you have a test app that can connect to nearly identical mysql or
postgres dbs. The schemas are the same apart from minor differences required by
the database engine. You want to make it easy to access whichever one you want,
or even both.

    package My::ORM;
    use DBIx::QuickORM;

    orm my_orm => sub {
        db myapp => sub {
            alt mysql => sub {
                host 'mysql.myapp.com';
                user $MYSQL_USER;
                pass $MYSQL_PASS;
                db_name 'myapp_mysql';    # In mysql the db is named myapp_mysql
            };
            alt pgsql => sub {
                host 'pgsql.myapp.com';
                user $PGSQL_USER;
                pass $PGSQL_PASS;
                db_name 'myapp_pgsql';    # In postgresql the db is names myapp_pgsql
            };
        };

        schema my_schema => sub {
            table same_on_both => sub { ... };

            # Give the name 'differs' that can always be used to refer to this table, despite each db giving it a different name
            table differs => sub {
                # Each db has a different name for the table
                alt mysql => sub { db_name 'differs_mysql' };
                alt pgsql => sub { db_name 'differs_pgsql' };

                # Name for the column that the code can always use regardless of which db is in use
                column foo => sub {
                    # Each db also names this column differently
                    alt mysql => sub { db_name 'foo_mysql' };
                    alt pgsql => sub { db_name 'foo_pgsql' };
                    ...;
                };

                ...;
            };
        };
    };

Then to use it:

    use My::ORM;

    my $orm_mysql = orm('my_orm:mysql');
    my $orm_pgsql = orm('my_orm:pgsql');

Each orm object is a complete and self-contained ORM with its own caching and
db connection. One connects to mysql and one connects to postgresql. Both can
ask for rown in the 'differs' table, on mysql it will query the
'differs_mysql', on postgresql it will query the 'differs_pgsql' table. You can
use them both at the same time in the same code.


=head2 ADVANCED COMPOSING

You can define databses and schemas on their own and create multiple orms that
combine them. You can also define a 'server' that has multiple databases.

    package My::ORM;
    use DBIx::QuickORM;

    server pg => sub {
        host 'pg.myapp.com';
        user $USER;
        pass $PASS;

        db 'myapp';       # Points at the 'myapp' database on this db server
        db 'otherapp';    # Points at the 'otherapp' database on this db server
    };

    schema myapp => sub { ... };
    schema otherapp => sub { ... };

    orm myapp => sub {
        db 'pg.myapp';
        schema 'myapp';
    };

    orm otherapp => sub {
        db 'pg.otherapp';
        schema 'otherapp';
    };

Then to use them:

    use My::ORM;

    my $myapp    = orm('myapp');
    my $otherapp = orm('otherapp');

Also note that C<< alt(variant => sub { ... }) >> can be used in any of the
above builders to create mysql/postgres/etc variants on the databses and
schemas. Then access them like:

    my $myapp_pgsql = orm('myapp:pgsql');
    my $myapp_mysql = orm('myapp:myql');

=head1 ORM BUILDER EXPORTS

You get all these when using DBIx::QuickORM.

=over 4

=item orm $NAME => sub { ... }

=item my $orm = orm($NAME)

Define or fetch an ORM.

    orm myorm => sub {
        db mydb => sub { ... };
        schema myschema => sub { ... };
    };

    my $orm = orm('myorm');

You can also compose using dbs or schemas you defined previously:

    db mydb1 => sub { ... };
    db mydb2 => sub { ... };

    schema myschema1 => sub { ... };
    schema myschema2 => sub { ... };

    orm myorm1 => sub {
        db 'mydb1';
        schema 'myschema1';
    };

    orm myorm2 => sub {
        db 'mydb2';
        schema 'myschema2';
    };

    orm my_mix_a => sub {
        db 'mydb1';
        schema 'myschema2';
    };

    orm my_mix_b => sub {
        db 'mydb2';
        schema 'myschema1';
    };

=item alt $VARIANT => sub { ... }

Can be used to add variations to any builder:

    orm my_orm => sub {
        db mydb => sub {
            # ************************************
            alt mysql => sub {
                driver 'MySQL';
            };

            alt pgsql => sub {
                driver 'PostgreSQL';
            };
            # ************************************
        };

        schema my_schema => sub {
            table foo => sub {
                column x => sub {
                    identity();

                    # ************************************
                    alt mysql => sub {
                        type \'BIGINT';
                    };

                    alt pgsql => sub {
                        type \'BIGSERIAL';
                    };
                    # ************************************
                };
            }
        };
    };

Variants can be fetched using the ':' in the name:

    my $pg_orm    = orm('my_orm:pgsql');
    my $mysql_orm = orm('my_orm:mysql');

This works in orm(), db(), schema(), table(), and row() builders. It does
cascade, so if you ask for the 'mysql' variant of an orm, it will also give you
the mysql variants of the db, schema, tables and rows.

=item db $NAME

=item db $NAME => sub { ... }

=item $db = db $NAME

=item $db = db $NAME => sub { ... }

Used to define a database.

    db mydb => sub {
        driver 'MySQL';
        host 'mysql.myapp.com';
        port 1234;
        user $MYSQL_USER;
        pass $MYSQL_PASS;
        db_name 'myapp_mysql';    # In mysql the db is named myapp_mysql
    };

Can also be used to fetch a db by name:

    my $db = db('mydb');

Can also be used to tell an ORM which db to use:

    orm myorm => sub {
        db 'mydb';
        ...
    };

=item dialect '+DBIx::QuickORM::Dialect::PostgreSQL'

=item dialect 'PostgreSQL'

=item dialect 'PostgreSQL::V17'

=item dialect 'MySQL'

=item dialect 'MariaDB'

=item dialect 'SQLite'

Specify what dialect of SQL should be used. This is important for reading
schema from an existing database, or writing new schema SQL.

'DBIx::QuickORM::Dialect::' will be prefixed to the start of any string
provided unless it starts with a '+', in whcih case the plus is removed and the
rest of the string is left unmodified.

The following are all supported by DBIx::QuickORM by default. Using them will
always use the latest version. If you are using an older version of the
database and want a matching dialect you can specify that with '::V#', assuming
a module exists for the dialect version you want. If none exists you can write
one and submit a PR.

=over 4

=item PostgreSQL

For interacting with PostgreSQL databases.

=item MySQL

For interacting with MySQL databases.

=item MariaDB

For interacting with MariaDB databases.

=item SQLite

For interacting with SQLite databases.

=back

=item driver '+DBD::Pg'

=item driver 'Pg'

=item driver 'mysql';

=item driver 'MariaDB';

=item driver 'SQLite';

Usually you do not need to specify this as your dialect should specify the
correct one to use. However in cases like MySQL and MariaDB they are more or
less interchangable and you may want to override the default.

Specify what DBI driver should be used. 'DBD::' is prefixed to any string you
specify unless it starts with '+', in which case the plus is stripped and the
rest of the module name is unmodified.

=item attributes \%HASHREF

=item attributes(attr => val, ...)

Set the attributes of the database connection.

This can take a hashref or key+value pairs.

This will override all previous attributes, it does not merge.

    db mydb => sub {
        attributes { foo => 1 };
    };

Or:

    db mydb => sub {
        attributes foo => 1;
    };

=item host $HOTNAME

Provide a hostname or IP address for db connections

    db mydb => sub {
        host 'mydb.mydomain.com';
    };

=item port $PORT

Provide a port number for db connection.

    db mydb => sub {
        port 1234;
    };

=item socket $SOCKET_PATH

Provide a socket instead of a host+port

    db mydb => sub {
        socket '/path/to/db.socket';
    };

=item user $USERNAME

provide a database username

    db mydb => sub {
        user 'bob';
    };

=item pass $PASSWORD

provide a database password

    db mydb => sub {
        pass 'hunter2'; # Do not store any real passwords in plaintext in code!!!!
    };

=item creds sub { return \%CREDS }

Allows you to provide a coderef that will return a hashref with all the
necessary db connection fields.

This is mainly useful if you credentials are in an encrypted yaml or json file
and you have a method to decrypt and read it returning it as a hash.

    db mydb => sub {
        creds sub { ... };
    };

=item connect sub { ... }

=item connect \&connect

Instead of providing all the other fields, you may specify a coderef that
returns a L<DBI> connection.

B<IMPORTANT:> This function must always return a new L<DBI> connection it
B<MUST NOT> cache it!

    sub mydb => sub {
        connect sub { ... };
    };

=item dsn $DSN

Specify the DSN used to connect to the database. If not provided then an
attempt will be made to construct a DSN from other parameters, if they are
available.

    db mydb => sub {
        dsn "dbi:Pg:dbname=foo";
    };

=item server $NAME => sub { ... }

Used to define a server with multiple databases. This is a way to avoid
re-specifying credentials for each database you connect to.

You can use C<< db('server_name.db_name') >> to fetch the db.

Basically this allows you to specify any db fields once in the server, then
define any number of db's that inherit them.

Example:

    server pg => sub {
        host 'pg.myapp.com';
        user $USER;
        pass $PASS;
        attributes { work_well => 1 }

        db 'myapp';       # Points at the 'myapp' database on this db server
        db 'otherapp';    # Points at the 'otherapp' database on this db server

        # You can also override any if a special db needs slight modifications.
        db special => sub {
            attributes { work_well => 0, work_wrong => 1 };
        };
    };

    orm myapp => sub {
        db 'pg.myapp';
        ...;
    };

    orm otherapp => sub {
        db 'pg.otherapp';
        ...;
    };

=item schema $NAME => sub { ... }

=item $schema = schema($NAME)

=item $schema = schema($NAME => sub { ... })

Used to either fetch or define a schema.

When called with only 1 argument it will fetch the schema with the given name.

When used inside an orm builder it will set the schema for the orm (all orm's
have exactly one schema).

When called with 2 arguments it will define the schema using the coderef as a
builder.

When called in a non-void context it will return the compiled schema, otherwise
it adds it to the ORM class.

    # Define the 'foo' schema:
    schema foo => sub {
        table a => sub { ... };
        table b => sub { ... };
    };

    # Fetch it:
    my $foo = schema('foo');

    # Define and compile one:
    my $bar = schema bar => sub { ... }

    # Use it in an orm:
    orm my_orm => sub {
        schema('foo');
        db(...);
    };

=item table $NAME => sub { ... }

=item table $CLASS

=item table $CLASS => sub { ... }

Used to define a table, or load a table class.

    schema my_schema => sub {
        # Load an existing table
        table 'My::Table::Foo';

        # Define a new table
        table my_table => sub {
            column foo => sub { ... };
            primary_key('foo');
        };

        # Load an existing table, but make some changes to it
        table 'My::Table::Bar' => sub {
            # Override the row class used in the original
            row_class 'DBIx::QuickORM::Row';
        };
    };

This will assume you are loading a table class if the '::' appears in the name.
Otherwise it assumes you are defining a new table. This means it is not
possible to load top-level packages as table classes, which is a feature, not a
bug.

=item tables 'Table::Namespace'

Used to load all tables in the specified namespace:

    schema my_schema => sub {
        # Load My::Table::Foo, My::Table::Bar, etc.
        tables 'My::Table';
    };

=item row_class '+My::Row::Class'

=item row_class 'MyRowClass'

When fetching a row from a table, this is the class that each row will be
blessed into.

This can be provided as a default for a schema, or as a specific one to use in
a table. When using table classes this will set the base class for the table as
the table class itself will be the row class.

If the class name has a '+' it will be stripped off and the class name will not
be altered further. If there is no '+' then 'DBIx::QuickORM::Row::' will be
prefixed onto your string, and the resulting class will be loaded.

    schema my_schema => sub {
        # Uses My::Row::Class as the default for rows in all tables that do not override it.
        row_class '+My::Row::Class';

        table foo => sub {
            row_class 'Foo'; # Uses DBIx::QuickORM::Row::Foo as the row class for this table
        };
    };

In a table class:

    package My::ORM::Table::Foo;
    use DBIx::QuickORM 'table';

    table foo => sub {
        # Sets the base class (@ISA) for this table class to 'My::Row::Class'
        row_class '+My::Row::Class';
    };

=item db_name $NAME

Sometimes you want the orm to use one name for a table or column, but the
database actually uses another. For example you may want the orm to use the
name 'id' for a column, but the table actually uses the name 'my_id'. You can
use db_name to set the in-database name. Or a table named populace that you
want to refer to with the name 'people'

    table people => sub {
        db_name 'populace';

        column id => sub {
            db_name 'my_id';
        };
    };

This can also be used to have a different name for an entire database in the
orm from its actual name on the server:

    db theapp => sub {    # Name in the orm
        db_name 'myapp'    # Actual name on the server;
    };

=item column NAME => sub { ... }

=item column NAME => %SPECS

Define a column with the given name. The name will be used both as the name the
ORM uses for the column, and the actual name of the column in the database. If
you wish to have the orm use one name, but the databases uses another you can
use db_name() inside the column builder to provide the actual db name.

    column foo => sub {
        db_name 'foooo'; # In the database it uses 4 o's, not 2.

        type \'BIGINT'; # Specify a type in raw SQL (can also accept DBIx::QuickORM::Type::*)

        not_null(); # Column cannot be null

        # This column is an identity column, or is a primary key using
        # auto-increment. OR similar
        identity();

        ...
    };

There is no way to set an alternate db_name without a builder.
But here is how to do everything else above without one.

    column foo => ('not_null', 'identity', \'BIGINT');

=item omit

When set on a column, the column will be omited from selects by default. When
you fetch a row the column will not be fetched until needed. This is useful if
a table has a column that is usually huge and rarely used.

    column foo => sub {
        omit;
    };

In a non-void context it will return the string 'omit' for use in a column
specification without a builder.

    column bar => omit();

=item nullable()

=item nullable(1)

=item nullable(0)

=item not_null()

=item not_null(1)

=item not_null(0)

Toggle nullability for a column. nullable() defaults to setting the column as
nullable. not_null() defaults to setting the column as not nullable.

    column not_nullable => sub {
        not_null();
    };

    column is_nullable => sub {
        nullable();
    };

In a non-void context these will return a string, either 'nullable' or
'not_null'. These can be used in column specifications that do not use a
builder.

    column foo => nullable();
    column bar => not_null();

=item identity()

=item identity(1)

=item identity(0)

Used to designate a column as an identity column. This is mainly used for
generating schema SQL. In a sufficient version of postgresql this will generate
an identity column. It will fallback to a column with a sequence, or in
mysql/sqlite it will use auto-incrementing columns.

In a column builder it will set (default) or unset the 'identity' attribute of
the column.


    column foo => sub {
        identity();
    };

In a non-void context it will simply return 'identity' by default or when given
a true value as an argument. It will return an empty list if a false argument
is provided.

    column foo => identity();

=item affinity('string')

=item affinity('numeric')

=item affinity('binary')

=item affinity('boolean')

When used inside a column builder it will set the columns affinity to the one
specified.

    column foo => sub {
        affinity 'string';
    };

When used in a non-void context it will return the provided string. This case
is only useful for checking for typos as it will throw an exception if you use
an invalid affinity type.

    column foo => affinity('string');

=item type(\$sql)

=item type("+My::Custom::Type") # The + is stripped off

=item type("+My::Custom::Type", @CONSTRUCTION_ARGS)

=item type("MyType") # Short for "DBIx::QuickORM::Type::MyType"

=item type("MyType", @CONSTRUCTION_ARGS)

=item type(My::Type->new(...))

Used to specify the type for the column. You can provide custom SQL in the form
of a scalar referernce. You can also provide the class of a type, if you prefix
the class name with a '+' then it will strip the + off and make no further
modifications. If you provide a string without a + it will attempt to load
'DBIx::QuickORM::Type::YOUR_STRING' and use that.

In a column builder this will directly apply the type to the column being
built.

In scalar context this will return the constructed type object.

    column foo => sub {
        type 'MyType';
    };

    column foo => type('MyType');

=item sql($sql)

=item sql(infix => $sql)

=item sql(prefix => $sql)

=item sql(postfix => $sql)

This is used when generating sql to define the database.

This allows you to provide custom SQL to define a table/column, or add sql
before (prefix) and after (postfix).

Infix will prevent the typical sql from being generated, the infix will be used
instead.

If no *fix is specified then 'infix' is assumed.

=item default(\$sql)

=item default(sub { ... })

=item %key_val = default(\$sql)

=item %key_val = default(sub { ... })

When given a scalar reference it is treated as SQL to be used when generating
sql to define the column.

When given a coderef it will be used as a default value generator for the
column whenever DBIx::QuickORM inserts a new row.

In void context it will apply the default to the column being defined, or will
throw an exception if no column is being built.

    column foo => sub {
        default \"NOW()"; # Used when generating SQL for the table
        default sub { 123 }; # Used when inserting a new row
    };

This can also be used without a codeblock:

    column foo => default(\"NOW()"), default(sub { 123 });

In the above cases they return:

    (sql_default => "NOW()")
    (perl_default => sub { 123 })

=item columns(@names)

=item columns(@names, \%attrs)

=item columns(@names, sub { ... })

Define multiple columns at a time. If any attrs hashref or sub builder are
specified they will be applied to ALL provided column names.

=item primary_key

=item primary_key(@COLS)

Used to define a primary key. When used under a table you must provide a
list of columns. When used under a column builder it designates just that
column as the primary key, no arguments would be accepted.

    table mytable => sub {
        column a => sub { ... };
        column b => sub { ... };

        primary_key('a', 'b');
    };

Or to make a single column the primary key:

    table mytable => sub {
        column a => sub {
            ...
            primary_key();
        };
    };

=item unique

=item unique(@COLS)

Used to define a unique constraint. When used under a table you must provide a
list of columns. When used under a column builder it designates just that
column as unique, no arguments would be accepted.

    table mytable => sub {
        column a => sub { ... };
        column b => sub { ... };

        unique('a', 'b');
    };

Or to make a single column unique:

    table mytable => sub {
        column a => sub {
            ...
            unique();
        };
    };

=item link($node_a, $ratio, $node_b)

Used to create a link between a set of columns in one table to a set of columns
in another table. An example would be foreign keys.

Examples:

    schema myschema => sub {
        table a => {column 'id' => sub { ... }};
        table b => {column 'id' => sub { ... }};

        link(
            {table => 'a', columns => ['id'], accessor => 'get_b'},
            '1:1',    # Or you can use the ONE_TO_ONE constant.
            {table => 'b', columns => ['id'], accessor => 'get_a'},
        );
    };

Or define when defining columns:

    schema myschema => sub {
        table a => {
            column 'id' => sub {
                link 'get_b', ONE_TO_ONE, {table => 'b', columns => ['id']};
            };
        };

        table b => {
            column 'id' => sub {
                link 'get_a', ONE_TO_ONE, {table => 'a', columns => ['id']};
            };
        };
    };

=item $ratio = ONE_TO_ONE

Constant that returns the string C<'1:1'>.

This is used in conjunction with the C<link()> function.

    link {...}, ONE_TO_ONE, {...};

=item $ratio = MANY_TO_MANY

Constant that returns the string C<'*:*'>.

This is used in conjunction with the C<link()> function.

    link {...}, MANY_TO_MANY, {...};

=item $ratio = ONE_TO_MANY

Constant that returns the string C<'1:*'>.

This is used in conjunction with the C<link()> function.

    link {...}, ONE_TO_MANY, {...};

=item $ratio = MANY_TO_ONE

Constant that returns the string C<'*:1'>.

This is used in conjunction with the C<link()> function.

    link {...}, MANY_TO_ONE, {...};

=item build_class $CLASS

Use this to override the class being built by a builder.

    schema myschema => sub {
        build_class 'DBIx::QuickORM::Schema::MySchemaSubclass';

        ...
    };

=item my $meta = meta

Get the current builder meta hashref

    table mytable => sub {
        my $meta = meta();

        # This is what db_name('foo') would do!
        $meta->{name} = 'foo';
    };

=item plugin '+My::Plugin'

=item plugin 'MyPlugin'

=item plugin 'MyPlugin' => @CONSTRUCTION_ARGS

=item plugin 'MyPlugin' => \%CONSTRUCTION_ARGS

=item plugin My::Plugin->new()

Load a plugin and apply it to the current builder (or top level) and all nested
builders below it.

The '+' prefix can be used to specify a fully qualified plugin package name.
Without the '+' the namespace 'DBIx::QuickORM::Plugin::' will be prefixed to
the string.

    plugin '+My::Plugin';    # Loads 'My::Plugin'
    plugin 'MyPlugin';       # Loads 'DBIx::QuickORM::Plugin::MyPlugin

You can also provide an already blessed plugin:

    plugin My::Plugin->new();

Or provide construction args:

    plugin '+My::Plugin' => (foo => 1, bar => 2);
    plugin '+MyPlugin'   => {foo => 1, bar => 2};

=item $plugins = plugins()

=item plugins '+My::Plugin', 'MyPlugin' => \%ARGS, My::Plugin->new(...), ...;

Load several plugins at once, if a plugin class is followed by a hashref it is
used as construction arguments.

Can also be used with no arguments to return an arrayref of all active plugins
for the current scope.

=back

=head1 YOUR ORM PACKAGE EXPORTS

=over 4

=item $orm_meta = orm()

=item $orm = orm($ORM_NAME)

=item $db = orm(db => $DB_NAME)

=item $schema = orm(schema => $SCHEMA_NAME)

=item $orm_variant = orm("${ORM_NAME}:${VARIANT}")

=item $db_variant = orm(db => "${DB_NAME}:${VARIANT}")

=item $schema_variant = orm(schema => "${SCHEMA_NAME}:${VARIANT}")

This function is the one-stop shop to access any orm, schema, or db instances
you have defined.

=back

=head2 RENAMING THE EXPORT

You can rename the orm() function at import time by providing an alternate
name.

    use My::ORM qw/renamed_orm/;

    my $orm = renamed_orm('my_orm');

=cut
