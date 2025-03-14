package DBIx::QuickORM;
use strict;
use warnings;
use Carp qw/croak confess/;

use Scalar::Util qw/blessed/;

use Scope::Guard();

use DBIx::QuickORM::Util qw/load_class/;
use DBIx::QuickORM::Affinity qw/validate_affinity affinity_from_type/;

use constant DBS     => 'dbs';
use constant ORMS    => 'orms';
use constant PACKAGE => 'package';
use constant SCHEMAS => 'schemas';
use constant SERVERS => 'servers';
use constant STACK   => 'stack';

my @EXPORT = qw{
    plugin
    plugins
    meta
    orm

    build_class

    server
     driver
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
     alt
     table
      db_name
      column
       affinity
       conflate
       omit
       nullable
       identity
       type
       size
       sql
      columns
      primary_key
      unique
     link
};

sub import {
    my $class = shift;
    my $caller = caller;

    my $builder = $class->new(PACKAGE() => $caller);

    my %export = (
        builder => sub { $builder },
        import  => sub { shift; $builder->import_into(scalar(caller), @_) },
    );

    for my $name (@EXPORT) {
        my $meth = $name;
        $export{$name} = sub { shift @_ if @_ && $_[0] && "$_[0]" eq $caller; $builder->$meth(@_) };
    }

    for my $sym (keys %export) {
        no strict 'refs';
        *{"${caller}\::${sym}"} = $export{$sym};
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

    if (@_ == 1 && $_[0] =~ m/^(\S+)\.([^:\s]+)(?::(\S+))?$/) {
        my ($server_name, $db_name, $variant_name) = ($1, $2, $3);

        my $server = $self->{+SERVERS}->{$server_name} or croak "'$server_name' is not a defined server";
        my $db = $server->{meta}->{dbs}->{$db_name} or croak "'$db_name' is not a defined database on server '$server_name'";
        return $self->compile($db, $variant_name);
    }

    my $top = $self->top;
    my $into = $self->{+DBS};
    my $frame = {building => 'DB', class => 'DBIx::QuickORM::DB'};

    if ($top->{building} eq 'ORM') {
        croak "DB has already been defined" if $top->{meta}->{db};
        return $top->{meta}->{db} = $self->_build('DB', into => $into, frame => $frame, args => \@_);
    }

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

sub driver {
    my $self = shift;
    my ($proto) = @_;

    my $top = $self->_in_builder(qw{db server});

    my $class = load_class($proto, 'DBIx::QuickORM::DB') or croak "Could not load DB driver '$proto': $@";

    croak "Class '$class' is not a subclass of 'DBIx::QuickORM::DB'"
        unless $class->isa('DBIx::QuickORM::DB');

    $top->{class} = $class;
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
        return $top->{meta}->{schema} = $self->_build('Schema', into => $into, frame => $frame, args => \@_);
    }

    return $self->_build('Schema', into => $into, frame => $frame, args => \@_);
}

sub table {
    my $self = shift;

    my $top = $self->_in_builder(qw{schema});

    my $into  = $top->{meta}->{tables} //= {};
    my $frame = {building => 'TABLE', class => 'DBIx::QuickORM::Schema::Table', meta => {row_class => $top->{meta}->{row_class}}};

    return $self->_build('Table', into => $into, frame => $frame, args => \@_);
}

sub column {
    my $self = shift;

    my $top = $self->_in_builder(qw{table});

    my $into  = $top->{meta}->{columns} //= {};
    my $frame = {building => 'COLUMN', class => 'DBIx::QuickORM::Schema::Table::Column'};

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

            for my $arg (@$extra) {
                local $@;

                if(validate_affinity($arg)) {
                    $meta->{affinity} = $arg;
                }
                elsif(my $class = $self->is_conflator($arg)) {
                    $meta->{conflate} = $class;
                }
                else {
                    my $msg = "'$arg' does not appear to be either an affinity or a conflator";
                    $msg .= ".\nlast error: $@\n" if $@;
                    croak $msg;
                }
            }

            @$extra = ();
        },
    );
}

sub is_conflator {
    my $self = shift;
    my ($arg) = @_;

    my $class = load_class($arg, 'DBIx::QuickORM::Conflator') or return 0;
    return 0 unless $class->isa('DBIx::QuickORM::Conflator');
    return $class;
}

sub columns {
    my $self = shift;

    my $top = $self->_in_builder(qw{table});

    my (@names, $other);
    for my $arg (@_) {
        my $ref = ref($arg);
        if   (!$ref)          { push @names => $arg }
        if   ($ref eq 'HASH') { croak "Cannot provide multiple hashrefs" if $other; $other = $arg }
        else                  { croak "Not sure what to do with '$arg'" }
    }

    return [map { column($_, $other) } @names] if defined wantarray;

    column($_, $other) for @names;

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

    croak "'infix' sql is not supported in SCHEMA, use prefix or postfix" if $affix eq 'infix' && $top->{building} eq 'SCHEMA';

    push @{$top->{meta}->{sql}->{$affix}} => $sql;
}

sub affinity {
    my $self = shift;
    croak "Not enough arguments" unless @_;
    my ($affinity) = @_;

    croak "'$affinity' is not a valid affinity" unless validate_affinity($affinity);

    my $top = $self->_in_builder(qw{column});
    $top->{meta}->{affinity} = $affinity;
}

sub conflate {
    my $self = shift;
    croak "Not enough arguments" unless @_;
    my ($proto) = @_;

    my $top = $self->_in_builder(qw{column});

    my $class = $self->is_conflator($proto) or croak "'$proto' is not a valid conflator class";

    $top->{meta}->{conflate} = $class;
}

sub type {
    my $self = shift;
    croak "Not enough arguments" unless @_;
    my ($type) = @_;

    my $top = $self->_in_builder(qw{column});
    $top->{meta}->{affinity} //= affinity_from_type($type);
    $top->{meta}->{type} = $type;
}

sub size {
    my $self = shift;
    croak "Not enough arguments" unless @_;
    my ($size) = @_;

    my $top = $self->_in_builder(qw{column});

    $top->{meta}->{size} = $size;
}

sub omit     { $_[0]->_in_builder('column')->{meta}->{omit}     = $_[1] // 1 }
sub nullable { $_[0]->_in_builder('column')->{meta}->{nullable} = $_[1] // 1 }
sub identity { $_[0]->_in_builder('column')->{meta}->{identity} = $_[1] // 1 }

sub _in_builder {
    my $self = shift;
    my %builders = map { lc($_) => 1 } @_;

    if (@{$self->{+STACK}} > 1) {
        my $top = $self->top;
        my $bld = lc($top->{building});

        return $top if $builders{$bld};
    }

    my ($pkg, $file, $line, $name) = caller(0);

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

    my $top = $self->_in_builder(qw{table column});

    my $class = load_class($proto, 'DBIx::QuickORM::Row') or croak "Could not load class '$proto': $@";

    $top->{meta}->{row_class} = $class;
}

sub primary_key {
    my $self = shift;
    my (@list) = @_;

    my $top = $self->_in_builder(qw{table});

    $top->{meta}->{primary_key} = \@list;
}

sub unique {
    my $self = shift;
    my (@list) = @_;

    my $top = $self->_in_builder(qw{table});

    @list = sort @list;

    my $key = join ', ' => @list;

    $top->{meta}->{unique}->{$key} = \@list;
}

sub link {
    my $self = shift;
    my $top = $self->_in_builder(qw{schema});

    my ($node_a, $node_b, @extra) = @_;
    croak "Must specify 2 nodes" unless $node_a && $node_b;
    croak "Too many arguments" if @extra;

    push @{$top->{meta}->{links}} => [$node_a, $node_b];
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

        my $val = $self->_merge($alta->{$field}, $meta->{$field}) or next;

        unless($recurse->{$field}) {
            $obj_data{$field} = $val;
            next;
        }

        if ($field =~ m/s$/) {
            $obj_data{$field} = { map { $_ => $self->compile($val->{$_}, $alt_arg) } keys %$val };
        }
        else {
            $obj_data{$field} = $self->compile($val, $alt_arg);
        }
    }

    my $proto = $frame->{class} or croak "No class to compile for '$frame->{name}' ($frame->{created})";
    my $class = load_class($proto) or croak "Could not load class '$proto' for '$frame->{name}' ($frame->{created}): $@";

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
    croak "Mismatched referenced!" unless $ref_a eq $ref_b;

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

    my @caller = caller(1);

    my ($name, $builder, $meta_arg, @extra);
    for my $arg (@$args) {
        my $ref = ref($arg);
        if    (!$ref)          { if ($name) { push @extra => $arg } else { $name = $arg } }
        elsif ($ref eq 'CODE') { croak "Multiple builders provided!" if $builder; $builder = $arg }
        elsif ($ref eq 'HASH') { croak "Multiple meta hashes provided!" if $meta_arg; $meta_arg = $arg }
        else                   { croak "Not sure what to do with '$arg'" }
    }

    my $alt = $name =~ s/:(\S+)$// ? $1 : undef;
    $name = undef if defined($name) && !length($name);

    my $meta = $meta_arg // {};
    $self->$extra_cb(%params, type => $type, extra => \@extra, meta => $meta, name => $name, frame => $frame) if $extra_cb;
    croak "Multiple names provided: " . join(', ' => $name, @extra) if @extra;

    # Simple fetch
    if ($name && !$builder && !$meta_arg && !$force_build) {
        croak "'$name' is not a defined $type" unless $into->{$name};
        return $self->compile($into->{$name}, $alt);
    }

    my $created = "$caller[3]() at $caller[1] line $caller[2]";
    %$frame = (
        %$frame,
        plugins  => [],
        created  => $created,
    );

    $frame->{name} //= $name // "Anonymous builder ($created)";

    $frame->{meta} = { %{$frame->{meta} // {}}, %{$meta} };

    $frame->{meta}->{name} = $name if $name && $type ne 'Alt';

    push @{$self->{+STACK}} => $frame;

    my $ok = eval {
        $builder->($meta, $frame) if $builder;
        $_->munge($frame) for @{$self->plugins};
        1;
    };
    my $err = $@;

    pop @{$self->{+STACK}};

    die $err unless $ok;

    $into->{$name} = $frame if $into && $name;

    return $self->compile($frame, $alt) if defined wantarray;

    return if $name;

    croak "No name provided, but called in void context!";
}

1;
