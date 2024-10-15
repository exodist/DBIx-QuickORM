package DBIx::QuickORM::V0;
use strict;
use warnings;

use Carp qw/croak confess/;
use Sub::Util qw/set_subname/;
use List::Util qw/first uniq/;
use Scalar::Util qw/blessed/;
use DBIx::QuickORM::Util qw/update_subname mod2file alias find_modules mesh_accessors accessor_field_inversion/;

use DBIx::QuickORM::BuilderState;

use Importer Importer => 'import';

$Carp::Internal{(__PACKAGE__)}++;

my @PLUGIN_EXPORTS = qw{
    plugin
    plugins
};

my @DB_EXPORTS = qw{
    db
    db_attributes
    db_class
    db_connect
    db_dsn
    db_host
    db_name
    db_password
    db_port
    db_socket
    db_user
    sql_spec
};

my @REL_EXPORTS = qw{
    relate
    rtable
    relation
    relations
    references
    prefetch
    as
    on
    using
    on_delete
};

my @_TABLE_EXPORTS = qw{
    column
    column_class
    columns
    conflate
    inflate
    deflate
    default
    index
    is_temp
    is_view
    not_null
    nullable
    omit
    primary_key
    relation
    relations
    row_class
    serial
    source_class
    sql_spec
    sql_type
    table_class
    unique
    accessors
};

my @TABLE_EXPORTS = uniq (
    @_TABLE_EXPORTS,
    @REL_EXPORTS,
    qw{ table update_table },
);

my @ROGUE_TABLE_EXPORTS = uniq (
    @_TABLE_EXPORTS,
    @REL_EXPORTS,
    qw{ rogue_table },
);

my @TABLE_CLASS_EXPORTS = uniq (
    @_TABLE_EXPORTS,
    @REL_EXPORTS,
    qw{ meta_table },
);

my @SCHEMA_EXPORTS = uniq (
    @TABLE_EXPORTS,
    @REL_EXPORTS,
    qw{
        include
        schema
        tables
        default_base_row
        update_table
    },
);

our %EXPORT_GEN = (
    '&meta_table' => \&_gen_meta_table,
);

our %EXPORT_MAGIC = (
    '&meta_table' => \&_magic_meta_table,
);

our @EXPORT = uniq (
    @PLUGIN_EXPORTS,
    @DB_EXPORTS,
    @TABLE_EXPORTS,
    @SCHEMA_EXPORTS,
    @REL_EXPORTS,

    qw{
        default_base_row
        autofill
        mixer
        conflator
        orm
    },
);

our @EXPORT_OK = uniq (
    @EXPORT,
    @TABLE_CLASS_EXPORTS,
    @ROGUE_TABLE_EXPORTS,
);

our %EXPORT_TAGS = (
    DB            => \@DB_EXPORTS,
    PLUGIN        => \@PLUGIN_EXPORTS,
    ROGUE_TABLE   => \@ROGUE_TABLE_EXPORTS,
    SCHEMA        => \@SCHEMA_EXPORTS,
    TABLE         => \@TABLE_EXPORTS,
    TABLE_CLASS   => \@TABLE_CLASS_EXPORTS,
    RELATION      => \@REL_EXPORTS,
);

my @STACK;
my $COL_ORDER = 1;

alias column => 'columns';

sub plugins { build_state(PLUGINS) }

sub add_plugin {
    my ($in, %params) = @_;

    my $before = delete $params{before_parent};
    my $after  = delete $params{after_parent};

    croak "Cannot add a plugin both before AND after the parent" if $before && $after;

    my $plugins = plugins() or croak "Must be used under a supported builder, no builder that accepts plugins found";

    return $plugins->unshift_plugin($in, %params) if $before;
    return $plugins->push_plugin($in, %params);
}

sub default_base_row {
    my $state = build_state or croak "Must be used inside a mixer, orm, schema, or table builder";

    if (@_) {
        my $class = shift;
        require(mod2file($class));
        return $state->{+DEFAULT_BASE_ROW} = $class;
    }

    return $state->{+DEFAULT_BASE_ROW} // 'DBIx::QuickORM::Row';
}

# sub mixer {
build_clean_builder mixer => sub {
    my %params = @_;

    my $args      = $params{args};
    my $state     = $params{state};
    my $caller    = $params{caller};
    my $wantarray = $params{wantarray};

    my $cb   = pop(@$args);
    my $name = shift(@$args);

    my %mixer = (
        name       => $name // "mixer at $caller->[1] line $caller->[2]",
        created    => "$caller->[1] line $caller->[2]",
        dbs        => {},
        schemas    => {},
        conflators => {},
        plugins    => accept_plugins(),
    );

    $state->{+PLUGINS} = $mixer{plugins};
    $state->{+MIXER}   = \%mixer;

    delete $state->{+RELATION};
    delete $state->{+ACCESSORS};
    delete $state->{+ORM};

    update_subname("mixer builder $name", $cb)->(\%mixer);

    require DBIx::QuickORM::Mixer;
    my $mixer = DBIx::QuickORM::Mixer->new(\%mixer);

    croak "Cannot be called in void context without a symbol name"
        unless defined($name) || defined($wantarray);

    if ($name) {
        no strict 'refs';
        *{"$caller->[0]\::$name"} = set_subname $name => sub { $mixer };
    }

    return $mixer;
};

sub conflator {
    croak "Too many arguments to conflator()" if @_ > 2;
    my ($cb, $name);

    my $state = build_state;
    my $mixer = $state->{+MIXER};
    my $col   = $state->{+COLUMN};

    croak "conflator() can only be used in void context inside either a column or mixer builder "
        unless $col || $mixer || wantarray;

    for my $arg (@_) {
        $cb = $arg if ref($arg) eq 'CODE';
        $name = $arg;
    }

    my $c;
    if ($cb) {
        my %params = (name => $name);

        build(
            building => 'conflator',
            state    => {%$state, CONFLATOR => \%params},
            callback => $cb,
            caller   => [caller],
            args     => [\%params],
        );

        croak "The callback did not define an inflator" unless $params{inflator};
        croak "The callback did not define a deflator"  unless $params{deflator};

        require DBIx::QuickORM::Conflator;
        $c = DBIx::QuickORM::Conflator->new(%params);
    }
    elsif ($mixer) {
        $c = $mixer->{conflator}->{$name} or croak "conflator '$name' is not defined";
    }
    else {
        croak "a codeblock is required";
    }

    return $col->{conflate} = $c if $col;

    return $c unless $mixer;

    croak "a name is required when used inside a mixer builder but not a column builder" unless $name;
    croak "Conflator '$name' is already defined in this mixer" if $mixer->{conflators}->{$name};
    return $mixer->{conflators}->{$name} = $c;
}

sub inflate(&) {
    my $self = shift;
    my ($code) = @_;

    croak "inflate() requires a coderef" unless $code and ref($code) eq 'CODE';

    if (my $state = build_state) {
        if (my $c = $state->{CONFLATOR}) {
            croak "An inflation coderef has already been provided" if $c->{inflate};
            return $c->{inflate} = $code;
        }

        if (my $col = $state->{COLUMN}) {
            my $c = $col->{conflate} //= {};
            croak "An inflation coderef has already been provided" if $c->{inflate};
            return $c->{inflate} = $code;
        }
    }

    croak "inflate() can only be used inside either a conflator builder or a column builder"
}

sub deflate(&) {
    my $self = shift;
    my ($code) = @_;
    croak "deflate() requires a coderef" unless $code and ref($code) eq 'CODE';

    if (my $state = build_state) {
        if (my $c = $state->{CONFLATOR}) {
            croak "An deflation coderef has already been provided" if $c->{deflate};
            return $c->{deflate} = $code;
        }

        if (my $col = $state->{COLUMN}) {
            my $c = $col->{conflate} //= {};
            croak "An deflation coderef has already been provided" if $c->{deflate};
            return $c->{deflate} = $code;
        }
    }

    croak "deflate() can only be used inside either a conflator builder or a column builder"
}

# sub orm {
build_top_builder orm => sub {
    my %params = @_;

    my $args      = $params{args};
    my $state     = $params{state};
    my $caller    = $params{caller};
    my $wantarray = $params{wantarray};

    my $name = shift(@$args) or croak "First arguemnt (name) is required";

    my $mixer = $state->{+MIXER};

    my (@dbs, @schemas);
    my ($db, $schema, $cb);
    while (my $arg = shift(@$args)) {
        if (blessed($arg)) {
            $schema = $arg and next if $arg->isa('DBIx::QuickORM::Schema');
            $db     = $arg and next if $arg->isa('DBIx::QuickORM::DB');
            croak "'$arg' is not a valid argument to orm()";
        }

        if (my $ref = ref($arg)) {
            $cb = $arg and next if $ref eq 'CODE';
            croak "'$arg' is not a valid argument to orm()";
        }

        if ($arg eq 'db' || $arg eq 'database') {
            my $db_name = shift(@$args);
            croak "Cannot lookup database '$db_name' as we are not under a mixer builder" unless $mixer;
            $db = $mixer->{dbs}->{$db_name} or croak "'$db_name' is not a defined database in miver '$mixer->{name}'";
            next;
        }
        elsif ($arg eq 'schema') {
            my $schema_name = shift(@$args);
            croak "Cannot lookup schema '$schema_name' as we are not under a mixer builder" unless $mixer;
            $db = $mixer->{dbs}->{$schema_name} or croak "'$schema_name' is not a defined database in miver '$mixer->{name}'";
            next;
        }

        croak "Cannot lookup '$arg' as we are not under a mixer builder" unless $mixer;

        my $s = $mixer->{schemas}->{$arg};
        my $d = $mixer->{dbs}->{$arg};
        croak "'$arg' is not a defined schema or database on mixer '$mixer->{name}'" unless $s || $d;

        push @dbs     => $d if $d && !$db;
        push @schemas => $s if $s && !$schema;
    }

    unless ($db && $schema) {
        if ($db && !$schema) {
            $schema = shift(@schemas) if @schemas;
        }
        elsif ($schema && !$db) {
            $db = shift(@dbs) if @dbs;
        }
        else {
            # If there are more than 1 if either of these then that means 1
            # name was ambiguous and pulled both a schema and a database, but a
            # second name only pulled one.
            shift(@dbs)     if @dbs > @schemas;
            shift(@schemas) if @schemas > @dbs;

            if (@dbs > 1 || @schemas > 1) {
                my %seen;
                my @names = sort grep { !$seen{$_}++ } map { $_->name } @dbs, @schemas;

                croak(
                    # Comments to keep formatter from making this all one line.
                    "Ambiguity, not sure which of the plain-text names is the database, and which is the schema. Please prefix one or the other with the 'schema' or 'db' prefix:\n"    #
                        . "    orm '$name' => (db => $names[0], schema => $names[1], ...);\n"                                                                                           #
                        . "    orm '$name' => (db => $names[1], schema => $names[0], ...);\n"                                                                                           #
                        . "  Ambiguous names are (" . join(', ' => @names) . ")"                                                                                                        #
                );
            }

            $db     = shift(@dbs);
            $schema = shift(@schemas);
        }
    }

    my %orm = (
        name    => $name // "orm at $caller->[1] line $caller->[2]",
        created => "$caller->[1] line $caller->[2]",
        plugins => accept_plugins(),
    );

    $orm{schema} //= $schema if $schema;
    $orm{db}     //= $db     if $db;

    $state->{+PLUGINS} = $params{plugins};
    $state->{+ORM}     = \%orm;

    delete $state->{+DB};
    delete $state->{+SCHEMA};
    delete $state->{+RELATION};

    update_subname("orm builder $name", $cb)->(\%orm);

    if (my $db = $state->{+DB}) {
        croak "ORM already has a database defined, but a second one has been built" if $orm{db};
        $orm{db} = $db;
    }

    if (my $schema = $state->{+SCHEMA}) {
        croak "ORM already has a schema defined, but a second one has been built" if $orm{schema};
        $orm{schema} = $schema;
    }

    croak "No database specified" unless $orm{db};
    croak "No schema specified" unless $orm{schema};

    $orm{schema} = _build_schema($orm{schema}) unless blessed($orm{schema});
    $orm{db}     = _build_db($orm{db})         unless blessed($orm{db});

    require DBIx::QuickORM::ORM;
    my $orm = DBIx::QuickORM::ORM->new(%orm);

    if ($mixer) {
        $mixer->{orms}->{$name} = $orm;
    }
    else {
        croak "Cannot be called in void context outside of a mixer without a symbol name"
            unless defined($name) || defined($wantarray);

        if ($name && !defined($wantarray)) {
            no strict 'refs';
            my $subname = "$caller->[0]\::$name";
            *{$subname} = set_subname $subname => sub { $orm };
        }
    }

    return $orm;
};

sub autofill {
    my ($val) = @_;
    $val //= 1;

    my $orm = build_state('ORM') or croak "This can only be used inside a orm builder";

    my $ok;
    if (my $type = ref($val)) {
        $ok = 1 if $type eq 'CODE';
    }
    else {
        $ok = 1 if "$val" == "1" || "$val" == "0";
    }

    croak "Autofill takes either no argument (on), 1 (on), 0 (off), or a coderef (got: $val)"
        unless $ok;

    $orm->{autofill} = $val;
}

sub _new_db_params {
    my ($name, $caller) = @_;

    return (
        name       => $name,
        created    => "$caller->[1] line $caller->[2]",
        db_name    => $name,
        attributes => {},
        plugins    => accept_plugins(),
    );
}

sub _build_db {
    my $params = shift;

    my $class  = delete($params->{class}) or croak "You must specify a db class such as: PostgreSQL, MariaDB, Percona, MySQL, or SQLite";
    $class = "DBIx::QuickORM::DB::$class" unless $class =~ s/^\+// || $class =~ m/^DBIx::QuickORM::DB::/;

    eval { require(mod2file($class)); 1 } or croak "Could not load $class: $@";
    return $class->new(%$params);
}

# sub db {
build_top_builder db => sub {
    my %params = @_;

    my $args   = $params{args};
    my $state  = $params{state};
    my $caller = $params{caller};

    my ($name, $cb) = @$args;

    my $orm   = $state->{+ORM};
    my $mixer = $state->{+MIXER};

    my $db;

    if ($cb) {
        my %db = _new_db_params($name => $caller);

        $state->{+DB} = \%db;

        update_subname("db builder $name", $cb);
        $cb->(\%db);

        $db = _build_db(\%db);

        if ($mixer) {
            croak "Quick ORM mixer already has a db named '$name'" if $mixer->{dbs}->{$name};
            $mixer->{dbs}->{$name} = $db;
        }
    }
    else {
        croak "db() requires a builder block unless it is called under both a 'mixer' and 'orm' block" unless $orm && $mixer;

        $db = $mixer->{dbs}->{$name} or croak "the '$name' database is not defined under the current mixer";
    }

    if ($orm) {
        croak "Quick ORM instance already has a db" if $orm->{db};
        $orm->{db} = $db;
    }

    return $db;
};

sub _get_db {
    my $state = build_state or return;

    return $state->{+DB} if $state->{+DB};
    return unless $state->{+ORM};

    croak "Attempt to use db builder tools outside of a db builder in an orm that already has a db defined"
        if $state->{+ORM}->{db};

    my %params = _new_db_params(default => [caller(1)]);

    $state->{+DB} = \%params;
}

sub db_attributes {
    my %attrs = @_ == 1 ? (%{$_[0]}) : (@_);

    my $db = _get_db() or croak "attributes() must be called inside of a db or orm builer";
    %{$db->{attributes} //= {}} = (%{$db->{attributes} // {}}, %attrs);

    return $db->{attributes};
}

sub db_connect {
    my ($in) = @_;

    my $db = _get_db() or croak "connect() must be called inside of a db or ORM builer";

    if (ref($in) eq 'CODE') {
        return $db->{connect} = $in;
    }

    my $code = do { no strict 'refs'; \&{$in} };
    croak "'$in' does not appear to be a defined subroutine" unless defined(&$code);
    return $db->{connect} = $code;
}

BEGIN {
    for my $db_field (qw/db_class db_name db_dsn db_host db_socket db_port db_user db_password/) {
        my $name = $db_field;
        my $attr = $name;
        $attr =~ s/^db_// unless $attr eq 'db_name';
        my $sub  = sub {
            my $db = _get_db() or croak "$name() must be called inside of a db builer";
            $db->{$attr} = $_[0];
        };

        no strict 'refs';
        *{$name} = set_subname $name => $sub;
    }
}

sub _new_schema_params {
    my ($name, $caller) = @_;

    return (
        name      => $name,
        created   => "$caller->[1] line $caller->[2]",
        includes  => [],
        plugins   => accept_plugins(),
    );
}

sub _build_schema {
    my $params = shift;

    my $state = build_state;

    if (my $pacc = $state->{+ACCESSORS}) {
        for my $tname (%{$params->{tables}}) {
            my $table = $params->{tables}->{$tname};
            $tname = $table->clone(accessors => mesh_accessors($table->accessors, $pacc));
        }
    }

    my $includes = delete $params->{includes};
    my $class    = delete($params->{schema_class}) // first { $_ } (map { $_->schema_class(%$params, state => $state) } @{$params->{plugins}->all}), 'DBIx::QuickORM::Schema';
    eval { require(mod2file($class)); 1 } or croak "Could not load class $class: $@";
    my $schema = $class->new(%$params);
    $schema = $schema->merge($_) for @$includes;

    return $schema;
}

# sub schema {
build_top_builder schema => sub {
    my %params = @_;

    my $args   = $params{args};
    my $state  = $params{state};
    my $caller = $params{caller};

    my ($name, $cb) = @$args;

    my $orm   = $state->{+ORM};
    my $mixer = $state->{+MIXER};

    my $schema;

    if ($cb) {
        my %schema = _new_schema_params($name => $caller);

        $state->{+SCHEMA}    = \%schema;
        $state->{+PLUGINS}   = $schema{plugins};

        delete $state->{+COLUMN};
        delete $state->{+TABLE};
        delete $state->{+RELATION};

        update_subname("schema builder $name", $cb)->(\%schema);

        $schema = _build_schema(\%schema);

        if ($mixer) {
            croak "A schema with name '$name' is already defined" if $mixer->{schemas}->{$name};

            $mixer->{schemas}->{$name} = $schema;
        }
    }
    else {
        croak "schema() requires a builder block unless it is called under both a 'mixer' and 'orm' block" unless $orm && $mixer;

        $schema = $mixer->{schemas}->{$name} or croak "the '$name' schema is not defined under the current mixer";
    }

    if ($orm) {
        croak "This orm instance already has a schema" if $orm->{schema};
        $orm->{schema} = $schema;
    }

    return $schema;
};

sub _get_schema {
    my $state = build_state;
    return $state->{+SCHEMA} if $state->{+SCHEMA};
    my $orm = $state->{+ORM} or return;

    return $orm->{schema} if $orm->{schema};

    my %params = _new_schema_params(default => [caller(1)]);

    $orm->{schema} = $state->{+SCHEMA} = \%params;

    return $state->{+SCHEMA};
}

sub include {
    my @schemas = @_;

    my $state  = build_state;
    my $schema = $state->{+SCHEMA} or croak "'include()' must be used inside a 'schema' builder";
    my $mixer  = $state->{+MIXER};

    for my $item (@schemas) {
        my $it;
        if ($mixer) {
            $it = blessed($item) ? $item : $mixer->{schemas}->{$item};
            croak "'$item' is not a defined schema inside the current mixer" unless $it;
        }
        else {
            $it = $item;
        }

        croak "'" . ($it // $item) . "' is not an instance of 'DBIx::QuickORM::Schema'" unless $it && blessed($it) && $it->isa('DBIx::QuickORM::Schema');

        push @{$schema->{include} //= []} => $it;
    }

    return;
}

sub tables {
    my (@prefixes) = @_;

    my $schema = build_state(SCHEMA) or croak "tables() can only be called under a schema builder";

    my @out;
    for my $mod (find_modules(@prefixes)) {
        my ($mod, $table) = _add_table_class($mod, $schema);
        push @out => $mod;
    }

    return @out;
}

sub _add_table_class {
    my ($mod, $schema) = @_;

    my $state = build_state;

    $schema //= $state->{SCHEMA} or croak "No schema found";

    require (mod2file($mod));

    my $table = $mod->orm_table;
    my $name = $table->name;

    croak "Schema already has a table named '$name', cannot add table from module '$mod'" if $schema->{tables}->{$name};

    my %clone;

    if (my $pacc = $state->{ACCESSORS}) {
        $clone{accessors} = mesh_accessors($pacc, $table->accessors);
    }

    if (my $row_class = $table->{row_class} // $schema->{row_class}) {
        $clone{row_class} = $row_class;
    }

    $table = $table->clone(%clone) if keys %clone;

    $schema->{tables}->{$name} = $table;
    return ($mod, $table);
}

# sub rogue_table {
build_clean_builder rogue_table => sub {
    my %params = @_;

    my $args   = $params{args};
    my $state  = $params{state};
    my $caller = $params{caller};

    my ($name, $cb) = @$args;

    return _table($name, $cb, caller => $caller);
};

sub _table {
    my ($name, $cb, %params) = @_;

    my $caller = delete($params{caller}) // [caller(1)];

    $params{name}    = $name;
    $params{plugins} = accept_plugins();
    $params{created} //= "$caller->[1] line $caller->[2]";
    $params{indexes} //= {};

    my $state = build_state();
    $state->{+TABLE} = \%params;

    update_subname("table builder $name", $cb)->(\%params);

    for my $cname (keys %{$params{columns}}) {
        my $spec = $params{columns}{$cname};

        if (my $conflate = $spec->{conflate}) {
            if (ref($conflate) eq 'HASH') { # unblessed hash
                confess "No inflate callback was provided for conflation" unless $conflate->{inflate};
                confess "No deflate callback was provided for conflation" unless $conflate->{deflate};

                require DBIx::QuickORM::Conflator;
                $spec->{conflate} = DBIx::QuickORM::Conflator->new(%$conflate);
            }
        }

        my $class = delete($spec->{column_class}) || $params{column_class} || ($state->{SCHEMA} ? $state->{SCHEMA}->{column_class} : undef ) || 'DBIx::QuickORM::Table::Column';
        eval { require(mod2file($class)); 1 } or die "Could not load column class '$class': $@";
        $params{columns}{$cname} = $class->new(%$spec);
    }

    my $class = delete($params{table_class}) // first { $_ } (map { $_->table_class(%params, state => $state) } @{$params{plugins}->all}), 'DBIx::QuickORM::Table';
    eval { require(mod2file($class)); 1 } or croak "Could not load class $class: $@";
    return $class->new(%params);
}

# sub update_table {
build_top_builder update_table => sub {
    my %params = @_;

    my $args   = $params{args};
    my $state  = $params{state};
    my $caller = $params{caller};

    my ($name, $cb) = @$args;

    my $schema = _get_schema() or croak "table() can only be used inside a schema builder";

    my $old = $schema->{tables}->{$name};

    delete $state->{+COLUMN};
    delete $state->{+RELATION};

    my $table = _table($name, $cb, caller => $caller);

    $schema->{tables}->{$name} = $old ? $old->merge($table) : $table;

    return $schema->{tables}->{$name}
};

# sub table {
build_top_builder table => sub {
    my %params = @_;

    my $args   = $params{args};
    my $state  = $params{state};
    my $caller = $params{caller};

    return rtable(@$args) if $state->{+RELATION};
    my $schema = _get_schema() or croak "table() can only be used inside a schema builder";

    my ($name, $cb) = @$args;

    croak "Table '$name' is already defined" if $schema->{tables}->{$name};

    if ($name =~ m/::/) {
        croak "Too many arguments for table(\$table_class)" if $cb;
        my ($mod, $table) = _add_table_class($name, $schema);
        return $table;
    }

    delete $state->{+COLUMN};
    delete $state->{+RELATION};

    my $table = _table($name, $cb);

    $schema->{tables}->{$name} = $table;

    return $table;
};

sub _magic_meta_table {
    my $from = shift;
    my %args = @_;

    my $into = $args{into};
    my $name = $args{new_name};
    my $ref  = $args{ref};

    eval { require BEGIN::Lift; BEGIN::Lift->can('install') } or return;

    my $stash = do { no strict 'refs'; \%{"$into\::"} };
    $stash->{_meta_table} = delete $stash->{meta_table};

    BEGIN::Lift::install($into, $name, $ref);
}

sub _gen_meta_table {
    my $from_package = shift;
    my ($into_package, $symbol_name) = @_;

    my %subs;

    my $stash = do { no strict 'refs'; \%{"$into_package\::"} };

    for my $item (keys %$stash) {
        my $sub = $into_package->can($item) or next;
        $subs{$item} = $sub;
    }

    my $me;
    $me = set_subname 'meta_table_wrapper' => sub {
        my $name     = shift;
        my $cb       = pop;
        my $row_base = shift // build_state(DEFAULT_BASE_ROW) // 'DBIx::QuickORM::Row';

        my @caller_parent = caller(1);
        confess "meta_table must be called directly from a BEGIN block (Or you can install 'BEGIN::Lift' to automatically wrap it in a BEGIN block)"
            unless @caller_parent && $caller_parent[3] =~ m/(^BEGIN::Lift::__ANON__|::BEGIN|::import)$/;

        my $table = _meta_table(name => $name, cb => $cb, row_base => $row_base, into => $into_package);

        for my $item (keys %$stash) {
            my $export = $item eq 'meta_table' ? $me : $from_package->can($item) or next;
            my $sub    = $into_package->can($item)                               or next;

            next unless $export == $sub || $item eq '_meta_table';

            my $glob = delete $stash->{$item};

            {
                no strict 'refs';
                no warnings 'redefine';

                for my $type (qw/SCALAR HASH ARRAY FORMAT IO/) {
                    next unless defined(*{$glob}{$type});
                    *{"$into_package\::$item"} = *{$glob}{$type};
                }

                if ($subs{$item} && $subs{$item} != $export) {
                    *{"$into_package\::$item"} = $subs{$item};
                }
            }
        }

        $me = undef;

        return $table;
    };

    return $me;
}

sub meta_table {
    my $name     = shift;
    my $cb       = pop;
    my $row_base = shift // build_state(DEFAULT_BASE_ROW) // 'DBIx::QuickORM::Row';
    my @caller   = caller;

    return _meta_table(name => $name, cb => $cb, row_base => $row_base, into => $caller[0]);
}

# sub _meta_table {
build_clean_builder _meta_table => sub {
    my %params = @_;

    my $args   = $params{args};
    my $state  = $params{state};
    my $caller = $params{caller};

    my %table = @$args;

    my $name     = $table{name};
    my $cb       = $table{cb};
    my $row_base = $table{row_base} // build_state(DEFAULT_BASE_ROW) // 'DBIx::QuickORM::Row';
    my $into     = $table{into};

    require(mod2file($row_base));

    my $table = _table($name, $cb, row_class => $into, accessors => {inject_into => $into});

    {
        no strict 'refs';
        my $subname = "$into\::orm_table";
        *{$subname} = set_subname $subname => sub { $table };
        push @{"$into\::ISA"} => $row_base;
    }

    return $table;
};

# -name - remove a name
# :NONE
# :ALL
# {name => newname} - renames
# [qw/name1 name2/] - includes
# name - include
# sub { my ($name, {col => $col, rel => $rel}) = @_; return $newname } - name generator, return original, new, or undef if it should be skipped
sub accessors {
    return _table_accessors(@_) if build_state(TABLE);
    return _other_accessors(@_) if build_state(ACCESSORS);
    croak "accesors() must be called inside one of the following builders: table, orm, schema, mixer"
}

sub _other_accessors {
    my $acc = build_state(ACCESSORS, {});

    for my $arg (@_) {
        if (ref($arg) eq 'CODE') {
            push @{$acc->{name_cbs}} => $arg;
            next;
        }

        if ($arg =~ m/^:(\S+)$/) {
            my $field = $1;
            my $inverse = accessor_field_inversion($field) or croak "'$arg' is not a valid accessors() argument";

            $acc->{$field} = 1;
            $acc->{$inverse} = 0;

            next;
        }

        croak "'$arg' is not a valid argument to accessors in this builder";
    }

    return;
}

sub _table_accessors {
    my $acc = build_state(TABLE)->{accessors} //= {};

    while (my $arg = shift @_) {
        my $r = ref($arg);

        if ($r eq 'HASH') {
            $acc->{include}->{$_} = $r->{$_} for keys %$r;
            next;
        }

        if ($r eq 'ARRAY') {
            $acc->{include}->{$_} //= $r->{$_} for @$r;
            next;
        }

        if ($r eq 'CODE') {
            push @{$acc->{name_cbs} //= []} => $arg;
            next
        }

        if ($arg =~ m/^-(\S+)$/) {
            $acc->{exclude}->{$1} = $1;
            next;
        }

        if ($arg =~ m/^\+(\$+)$/) {
            $acc->{inject_into} = $1;
        }

        if ($arg =~ m/^:(\S+)$/) {
            my $field = $1;
            my $inverse = accessor_field_inversion($field) or croak "'$arg' is not a valid accessors() argument";

            $acc->{$field} = 1;
            $acc->{$inverse} = 0;

            next;
        }

        $acc->{include}->{$arg} //= $arg;
    }

    return;
}

BEGIN {
    my @CLASS_SELECTORS = (
        [column_class=> (COLUMN, TABLE, SCHEMA)],
        [row_class=>    (TABLE,  SCHEMA)],
        [table_class=>  (TABLE,  SCHEMA)],
        [source_class=> (TABLE)],
    );

    for my $cs (@CLASS_SELECTORS) {
        my ($name, @states) = @$cs;

        my $code = sub {
            my ($class) = @_;
            eval { require(mod2file($class)); 1 } or croak "Could not load class $class: $@";

            for my $state (@states) {
                my $params = build_state($state) or next;
                return $params->{$name} = $class;
            }

            croak "$name() must be called inside one of the following builders: " . join(', ' => map { lc($_) } @states);
        };

        no strict 'refs';
        *{$name} = set_subname $name => $code;
    }
}

sub sql_type {
    my ($type, @dbs) = @_;

    my $col = build_state(COLUMN) or croak "sql_type() may only be used inside a column builder";

    if (@dbs) {
        sql_spec($_ => { type => $type }) for @dbs;
    }
    else {
        sql_spec(type => $type);
    }
}

sub sql_spec {
    my %hash = @_ == 1 ? %{$_[0]} : (@_);

    my $builder = build_meta_state('building') or croak "Must be called inside a builder";

    $builder = uc($builder);

    my $obj = build_state($builder) or croak "Could not find '$builder' state";

    my $specs = $obj->{sql_spec} //= {};

    %$specs = (%$specs, %hash);

    return $specs;
}

sub is_view {
    my $table = build_state(TABLE) or croak "is_view() may only be used in a table builder";
    $table->{is_view} = 1;
}

sub is_temp {
    my $table = build_state(TABLE) or croak "is_temp() may only be used in a table builder";
    $table->{is_temp} = 1;
}

sub column {
    my @specs = @_;

    @specs = @{$specs[0]} if @specs == 1 && ref($specs[0]) eq 'ARRAY';

    my @caller = caller;
    my $created = "$caller[1] line $caller[2]";

    my $table = build_state(TABLE) or croak "columns may only be used in a table builder";

    my $sql_spec = pop(@specs) if $table && @specs && ref($specs[-1]) eq 'HASH';

    while (my $name = shift @specs) {
        my $spec = @specs && ref($specs[0]) ? shift(@specs) : undef;

        if ($table) {
            if ($spec) {
                my $type = ref($spec);
                if ($type eq 'HASH') {
                    $table->{columns}->{$name}->{$_} = $spec->{$_} for keys %$spec;
                }
                elsif ($type eq 'CODE') {
                    my $column = $table->{columns}->{$name} //= {created => $created, name => $name};

                    $spec = update_subname 'column builder' => $spec;

                    build(
                        building => 'column',
                        callback => $spec,
                        args     => [],
                        caller   => \@caller,
                        state    => { %{build_state()}, COLUMN() => $column },
                    );
                }
            }
            else {
                $table->{columns}->{$name} //= {created => $created, name => $name};
            }

            $table->{columns}->{$name}->{name}  //= $name;
            $table->{columns}->{$name}->{order} //= $COL_ORDER++;

            %{$table->{columns}->{$name}->{sql_spec} //= {}} = (%{$table->{columns}->{$name}->{sql_spec} //= {}}, %$sql_spec)
                if $sql_spec;
        }
        elsif ($spec) {
            croak "Cannot specify column data outside of a table builder";
        }
    }
}

sub serial {
    my ($size, @cols) = @_;
    $size //= 1;

    if (@cols) {
        my @caller  = caller;
        my $created = "$caller[1] line $caller[2]";

        my $table = build_state(TABLE) or croak 'serial($size, @cols) must be used inside a table builer';
        for my $cname (@cols) {
            my $col = $table->{columns}->{$cname} //= {created => $created, name => $cname};
            $col->{serial} = $size;
        }
        return;
    }

    my $col = build_state(COLUMN) or croak 'serial($size) must be used inside a column builer';
    $col->{serial} = $size;
    $col->{sql_type} //= 'serial';
}

BEGIN {
    my @COL_ATTRS = (
        [unique      => set_subname(unique_col_val => sub { @{$_[0]} > 1 ? undef : 1 }), {index => 'unique'}],
        [primary_key => set_subname(unique_pk_val => sub { @{$_[0]} > 1 ? undef : 1 }),  {set => 'primary_key', index => 'unique'}],
        [nullable    => set_subname(nullable_val => sub { $_[0] // 1 }),                 {set => 'nullable'}],
        [not_null    => 0,                                                               {set => 'nullable'}],
        [omit        => 1],
        [
            default => set_subname default_col_val => sub {
                my $sub = shift(@{$_[0]});
                croak "First argument to default() must be a coderef" unless ref($sub) eq 'CODE';
                return $sub;
            },
        ],
        [
            conflate => set_subname conflate_col_val => sub {
                my $conf = shift(@{$_[0]});

                if (blessed($conf)) {
                    croak "Conflator '$conf' does not implement inflate()" unless $conf->can('inflate');
                    croak "Conflator '$conf' does not implement deflate()" unless $conf->can('deflate');
                    return $conf;
                }

                eval { require(mod2file($conf)); 1 } or croak "Could not load conflator class '$conf': $@";
                return $conf;
            },
        ],
    );

    for my $col_attr (@COL_ATTRS) {
        my ($attr, $val, $params) = @$col_attr;

        my $code = sub {
            my @cols = @_;

            my $val = ref($val) ? $val->(\@cols) : $val;

            my $table = build_state(TABLE) or croak "$attr can only be used inside a column or table builder";

            if (my $column = build_state(COLUMN)) {
                croak "Cannot provide a list of columns inside a column builder ($column->{created})" if @cols;
                $column->{$attr} = $val;
                @cols = ($column->{name});
                $column->{order} //= $COL_ORDER++;
            }
            else {
                croak "Must provide a list of columns when used inside a table builder" unless @cols;

                my @caller  = caller;
                my $created = "$caller[1] line $caller[2]";

                for my $cname (@cols) {
                    my $col = $table->{columns}->{$cname} //= {created => $created, name => $cname};
                    $col->{$attr} = $val if defined $val;
                    $col->{order} //= $COL_ORDER++;
                }
            }

            # FIXME - Why are we sorting and doing ordered?
            my $ordered;

            if (my $key = $params->{set}) {
                $ordered //= [sort @cols];
                $table->{$key} = $ordered;
            }

            if (my $key = $params->{index}) {
                $ordered //= [sort @cols];
                my $index = join ', ' => @$ordered;
                $table->{$key}->{$index} = $ordered;
            }

            return @cols;
        };

        no strict 'refs';
        *{$attr} = set_subname $attr => $code;
    }
}

sub index {
    my $idx;

    my $table = build_state(TABLE) or croak "Must be used under table builder";

    if (@_ == 0) {
        croak "Arguments are required";
    }
    elsif (@_ > 1) {
        my $name = shift;
        my $sql_spec = ref($_[0]) eq 'HASH' ? shift : undef;
        my @cols = @_;

        croak "A name is required as the first argument" unless $name;
        croak "A list of column names is required" unless @cols;

        $idx = {name => $name, columns => \@cols};
        $idx->{sql_spec} = $sql_spec if $sql_spec;
    }
    else {
        croak "1-argument form must be a hashref, got '$_[0]'" unless ref($_[0]) eq 'HASH';
        $idx = { %{$_[0]} };
    }

    my $name = $idx->{name};

    croak "Index '$name' is already defined on table" if $table->{indexes}->{$name};

    unless ($idx->{created}) {
        my @caller  = caller;
        $idx->{created} = "$caller[1] line $caller[2]";
    }

    $table->{indexes}->{$name} = $idx;
}

sub relate {
    my ($table_a_name, $a_spec, $table_b_name, $b_spec) = @_;

    croak "relate() cannot be used inside a table builder" if build_state(TABLE);
    my $schema = _get_schema or croak "relate() must be used inside a schema builder";

    my $table_a = $schema->{tables}->{$table_a_name} or croak "Table '$table_a_name' is not present in the schema";
    my $table_b = $schema->{tables}->{$table_b_name} or croak "Table '$table_b_name' is not present in the schema";

    $a_spec = [%$a_spec] if ref($a_spec) eq 'HASH';
    $a_spec = [$a_spec] unless ref($a_spec);

    $b_spec = [%$b_spec] if ref($b_spec) eq 'HASH';
    $b_spec = [$b_spec] unless ref($b_spec);

    my ($rel_a, @aliases_a) = _relation(table => $table_b_name, @$a_spec);
    my ($rel_b, @aliases_b) = _relation(table => $table_a_name, @$b_spec);

    $table_a->add_relation($_, $rel_a) for @aliases_a;
    $table_b->add_relation($_, $rel_b) for @aliases_b;

    return ($rel_a, $rel_b);
}

sub relation {
    my $table = build_state(TABLE) or croak "relation() can only be used inside a table builder";
    my ($rel, @aliases) = _relation(@_, method => 'find');
    _add_relation($table, $rel, @aliases);
    return $rel;
}

sub relations {
    my $table = build_state(TABLE) or croak "relations() can only be used inside a table builder";
    my ($rel, @aliases) = _relation(@_, method => 'select');
    _add_relation($table, $rel, @aliases);
    return $rel;
}

sub references {
    my $table  = build_state(TABLE)  or croak "references() can only be used inside a table builder";
    my $column = build_state(COLUMN) or croak "references() can only be used inside a column builder";

    my ($rel, @aliases) = _relation(@_, method => 'find', using => [$column->{name}]);
    _add_relation($table, $rel, @aliases);
    return $rel;
}

sub _add_relation {
    my ($table, $rel, @aliases) = @_;

    my %seen;
    for my $alias (@aliases) {
        next if $seen{$alias}++;
        croak "Table already has a relation named '$alias'" if $table->{relations}->{$alias};
        $table->{relations}->{$alias} = $rel;
    }

    return $rel;
}

sub rtable($) {
    if (my $relation = build_state(RELATION)) {
        $relation->{table} = $_[0];
    }
    else {
        return (table => $_[0]);
    }
}

sub prefetch() {
    if (my $relation = build_state(RELATION)) {
        $relation->{prefetch} = 1;
    }
    else {
        return (prefetch => 1);
    }
}

sub as($) {
    my ($alias) = @_;

    if (my $relation = build_state(RELATION)) {
        push @{$relation->{aliases} //= []} => $alias;
    }
    else {
        return ('as' => $alias);
    }
}

sub on($) {
    my ($cols) = @_;

    croak "on() takes a hashref of primary table column names mapped to join table column names, got '$cols'" unless ref($cols) eq 'HASH';

    if (my $relation = build_state(RELATION)) {
        $relation->{on} = $cols;
    }
    else {
        return (on => $cols);
    }
}

sub using($) {
    my ($cols) = @_;

    $cols = [$cols] unless ref($cols);
    croak "using() takes a single column name, or an arrayref of column names, got '$cols'" unless ref($cols) eq 'ARRAY';

    if (my $relation = build_state(RELATION)) {
        $relation->{using} = $cols;
    }
    else {
        return (using => $cols);
    }
}

sub on_delete($) {
    my ($val) = @_;

    if (my $relation = build_state(RELATION)) {
        $relation->{on_delete} = $val;
    }
    else {
        return (on_delete => $val);
    }
}

sub _relation {
    my (%params, @aliases);
    $params{aliases} = \@aliases;

    while (my $arg = shift @_) {
        my $type = ref($arg);

        if (!$type) {
            if ($arg eq 'table') {
                $params{table} = shift(@_);
            }
            elsif ($arg eq 'alias' || $arg eq 'as') {
                push @aliases => shift(@_);
            }
            elsif ($arg eq 'on') {
                $params{on} = shift(@_);
            }
            elsif ($arg eq 'using') {
                $params{using} = shift(@_);
            }
            elsif ($arg eq 'method') {
                $params{method} = shift(@_);
            }
            elsif ($arg eq 'on_delete') {
                $params{on_delete} = shift(@_);
            }
            elsif ($arg eq 'prefetch') {
                $params{prefetch} = shift(@_);
            }
            elsif (!@aliases) {
                push @aliases => $arg;
            }
            elsif(!$params{table}) {
                $params{table} = $arg;
            }
            else {
                push @aliases => $arg;
            }
        }
        elsif ($type eq 'HASH') {
            $params{on} = $arg;
        }
        elsif ($type eq 'ARRAY') {
            $params{using} = $arg;
        }
        elsif ($type eq 'CODE') {
            build(
                building => 'relation',
                callback => $arg,
                args     => [\%params],
                caller   => [caller(1)],
                state    => { %{build_state()}, RELATION() => \%params },
            );
        }
    }

    delete $params{aliases};
    $params{table} //= $aliases[-1] if @aliases;

    require DBIx::QuickORM::Table::Relation;
    my $rel = DBIx::QuickORM::Table::Relation->new(%params);

    push @aliases => $params{table} unless @aliases;

    return ($rel, @aliases);
}

1;
