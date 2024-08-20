package DBIx::QuickORM;
use strict;
use warnings;

use Carp qw/croak/;
use List::Util qw/first/;
use Scalar::Util qw/blessed/;
use DBIx::QuickORM::Util qw/mod2file alias/;
use DBIx::QuickORM::Util::Has Plugins => [qw/ordered_plugins/];

use DBIx::QuickORM::DB;
use DBIx::QuickORM::Mixer;
use DBIx::QuickORM::ORM;
use DBIx::QuickORM::Relation::Member;
use DBIx::QuickORM::Relation;
use DBIx::QuickORM::Schema::RelationSet;
use DBIx::QuickORM::Schema;
use DBIx::QuickORM::Source::Join;
use DBIx::QuickORM::Source;
use DBIx::QuickORM::Table::Column;
use DBIx::QuickORM::Table;

use Importer 'Importer' => 'import';

our @EXPORT = qw{
    attributes autofill column_class column columns conflate connect db
    db_class db_name default dsn host include index member member_class
    meta_table mixer omit password plugin port primary_key orm relation
    relation_class row_base_class schema socket sql_spec table table_class
    source_class unique user is_temp is_view
};

our %STATE;

alias columns => 'column';

sub plugins { $STATE{PLUGINS} // {} }

sub plugin {
    my ($in, %params) = @_;

    my $plugins = $STATE{PLUGINS} or croak "Must be used under a supported builder, no builder that accepts plugins found";

    my ($class, $instance);
    if ($class = blessed($in)) {
        croak "'$in' is not an instance of 'DBIx::QuickORM::Plugin' or a subclass of it" unless $in->isa('DBIx::QuickORM::Plugin');
        $instance = $in;
    }
    else {
        $class = "DBIx::QuickORM::Plugin::$in" unless $in =~ s/^\+// || $in =~ m/^DBIx::QuickORM::Plugin::/;
        eval { require(mod2file($class)); 1 } or croak "Could not load plugin '$in' ($class): $@";
        croak "Plugin '$in' ($class) is not a subclass of 'DBIx::QuickORM::Plugin'" unless $class->isa('DBIx::QuickORM::Plugin');
    }

    unless ($params{clean}) {
        if (my $have = $plugins->{$class}) {
            croak "Already have a plugin of class '$class', and it is not the same instance (Pass in `clean => 1` to override)" if $instance && $instance != $have;
            return $have;
        }
    }

    push @{$plugins->{__ORDER__}} => $class;
    return $plugins->{$class} = $instance // $class->new;
}

sub mixer {
    my $cb = pop;
    my $name = shift;

    my @caller = caller;

    my %params = (
        name    => $name // 'orm mixer',
        created => "$caller[1] line $caller[2]",
        dbs     => {},
        schemas => {},
        plugins => _push_plugins(),
    );

    local $STATE{PLUGINS} = $params{plugins};
    local $STATE{MIXER}   = \%params;
    local $STATE{STACK}   = ['MIXER', @{$STATE{STACK} // []}];
    local $STATE{ORM};

    $cb->(%STATE);

    my $mixer = DBIx::QuickORM::Mixer->new(\%params);

    croak "Cannot be called in void context without a symbol name"
        unless defined($name) || defined(wantarray);

    if ($name) {
        no strict 'refs';
        *{"$caller[0]\::$name"} = sub { $mixer };
    }

    return $mixer;
}

sub _push_plugins {
    if (my $parent = $STATE{PLUGINS}) {
        return {
            %$parent,
            __ORDER__ => [@{$parent->{__ORDER__} // []}],
        };
    }

    return {__ORDER__ => []};
}

sub orm {
    my $cb       = ref($_[-1]) eq 'CODE' ? pop : undef;
    my $new_args = ref($_[-1]) eq 'HASH' ? pop : {};
    my ($name, $db, $schema) = @_;

    my @caller = caller;

    my %params = (
        name    => $name // 'orm',
        created => "$caller[1] line $caller[2]",
        plugins => _push_plugins(),
    );

    if ($db || $schema) {
        my $mixer = $STATE{MIXER} or croak "The `orm(name, db, schema)` from can only be used under a mixer builder";

        if ($db) {
            $params{db} = $mixer->db($db) or croak "The '$db' database is not defined";
        }
        if ($schema) {
            $params{schema} = $mixer->schema($schema) or croak "The '$schema' schema is not defined";
        }
    }

    local $STATE{PLUGINS} = $params{plugins};
    local $STATE{ORM}    = \%params;
    local $STATE{STACK}   = ['ORM', @{$STATE{STACK} // []}];

    $cb->(%STATE);

    my $orm = DBIx::QuickORM::ORM->new(%params, %$new_args);

    if (my $mixer = $STATE{MIXER}) {
        $mixer->{orms}->{$name} = $orm;
    }
    else {
        croak "Cannot be called in void context outside of a mixer without a symbol name"
            unless defined($name) || defined(wantarray);

        if ($name) {
            no strict 'refs';
            *{"$caller[0]\::$name"} = sub { $orm };
        }
    }

    return $orm;
}

sub autofill {
    my ($val) = @_;
    $val //= 1;

    my $orm = $STATE{ORM} or croak "This can only be used inside a orm builder";

    $orm->{autofill} = $val;
}

sub db {
    my ($name, $cb) = @_;

    my @caller = caller;

    my %params = (
        name       => $name,
        created    => "$caller[1] line $caller[2]",
        db_name    => $name,
        attributes => {},
        plugins => _push_plugins(),
    );

    local $STATE{PLUGINS} = $params{plugins};
    local $STATE{DB}      = \%params;
    local $STATE{STACK}   = ['DB', @{$STATE{STACK} // []}];

    $cb->(%STATE);

    my $class = delete($params{db_class}) or croak "You must specify a db class such as: PostgreSQL, MariaDB, Percona, MySQL, or SQLite";
    $class = "DBIx::QuickORM::DB::$class" unless $class =~ s/^\+// || $class =~ m/^DBIx::QuickORM::DB::/;

    eval { require(mod2file($class)); 1 } or croak "Could not load $class: $@";
    my $db = $class->new(%params);

    if (my $orm = $STATE{ORM}) {
        croak "Quick ORM instance already has a db"
            if $orm->{db};
        $orm->{db} = $db;
    }
    elsif (my $mixer = $STATE{MIXER}) {
        croak "Quick ORM mixer already has a db named '$name'"
            if $mixer->{dbs}->{$name};
        $mixer->{dbs}->{$name} = $db;
    }

    return $db;
}

sub attributes {
    my %attrs = @_ == 1 ? (%{$_[0]}) : (@_);

    my $db = $STATE{DB} or croak "attributes() must be called inside of a db builer";
    %{$db->{attributes} //= {}} = (%{$db->{attributes} // {}}, %attrs);

    return $db->{attributes};
}

sub connect {
    my ($in) = @_;

    my $db = $STATE{DB} or croak "connect() must be called inside of a db builer";

    if (ref($in) eq 'CODE') {
        return $db->{connect} = $in;
    }

    my $code = do { no strict 'refs'; \&{$in} };
    croak "'$in' does not appear to be a defined subroutine" unless defined(&$code);
    return $db->{connect} = $code;
}

BEGIN {
    for my $db_field (qw/db_class db_name dsn host socket port user password/) {
        my $name = $db_field;
        my $sub  = sub {
            my $db = $STATE{DB} or croak "$name() must be called inside of a db builer";
            $db->{$name} = $_[0];
        };

        no strict 'refs';
        *{$name} = $sub;
    }
}

sub schema {
    my ($name, $cb) = @_;

    my @caller = caller;

    my @relations;
    my %params = (
        name      => $name,
        created   => "$caller[1] line $caller[2]",
        relations => \@relations,
        plugins => _push_plugins(),
    );

    local $STATE{SOURCES}   = {};
    local $STATE{PLUGINS}   = $params{plugins};
    local $STATE{SCHEMA}    = \%params;
    local $STATE{RELATIONS} = \@relations;
    local $STATE{STACK}     = ['SCHEMA', @{$STATE{STACK} // []}];

    local $STATE{COLUMN};
    local $STATE{RELATION};
    local $STATE{MEMBER};
    local $STATE{TABLE};

    $cb->(%STATE);

    $params{relations} = DBIx::QuickORM::Schema::RelationSet->new(@relations);

    my $class = delete($params{schema_class}) // first { $_ } (map { $_->schema_class(%params, %STATE) } ordered_plugins($params{plugins})), 'DBIx::QuickORM::Schema';
    eval { require(mod2file($class)); 1 } or croak "Could not load class $class: $@";
    my $schema = $class->new(%params);

    if (my $orm = $STATE{ORM}) {
        croak "This orm instance already has a schema" if $orm->{schema};
        $orm->{schema} = $schema;
    }
    elsif (my $mixer = $STATE{MIXER}) {
        croak "A schema with name '$name' is already defined" if $mixer->{schemas}->{$name};
        $mixer->{schemas}->{$name} = $schema;
    }

    return $schema;
}

sub include {
    my @schemas = @_;

    my $schema = $STATE{SCHEMA} or croak "include() can only be used inside a schema builder";

    for my $item (@schemas) {
        if (blessed($item) && $item->isa('DBIx::QuickORM::Schema')) {
            push @{$schema->{include} //= []} => $item;
        }
        else {
            my $mixer = $STATE{MIXER} or croak "include cannot take bare schema names outside of a mixer builder";
            my $it = $mixer->{schemas}->{$item} or croak "the '$item' schema is not defined";
            push @{$schema->{include} //= []} => $it;
        }
    }

    return;
}

sub _table {
    my ($name, $cb, %params) = @_;

    my @caller = caller(1);
    $params{name} = $name;
    $params{created} //= "$caller[1] line $caller[2]";
    $params{plugins} = _push_plugins();

    local $STATE{PLUGINS} = $params{plugins};
    local $STATE{TABLE}   = \%params;
    local $STATE{STACK}   = ['TABLE', @{$STATE{STACK} // []}];

    $cb->(%STATE);

    for my $cname (keys %{$params{columns}}) {
        my $spec = $params{columns}{$cname};
        my $class = delete($spec->{column_class}) || $params{column_class} || ($STATE{SCHEMA} ? $STATE{SCHEMA}->{column_class} : undef ) || 'DBIx::QuickORM::Table::Column';
        $params{columns}{$cname} = $class->new(%$spec);
    }

    my $class = delete($params{table_class}) // first { $_ } (map { $_->table_class(%params, %STATE) } ordered_plugins( $params{plugins} )), 'DBIx::QuickORM::Table';
    eval { require(mod2file($class)); 1 } or croak "Could not load class $class: $@";
    return $class->new(%params);
}

sub table {
    return _member_table(@_) if $STATE{MEMBER};

    my $schema = $STATE{SCHEMA} or croak "table() can only be used inside a schema or member builder";

    my ($name, $cb) = @_;

    my %params;

    local $STATE{COLUMN};
    local $STATE{RELATION};
    local $STATE{MEMBER};

    my $table = _table($name, $cb, %params);

    if (my $names = $STATE{NAMES}) {
        if (my $have = $names->{$name}) {
            croak "There is already a source named '$name' ($have) from " . ($have->created // '');
        }

        $names->{$name} = $table;
    }

    croak "Table '$table' is already defined" if $schema->{tables}->{$name};
    $schema->{tables}->{$name} = $table;

    return $table;
}

sub meta_table {
    my ($name, $cb) = @_;

    my $caller = caller;

    local %STATE;

    my @relations;
    local $STATE{RELATIONS} = \@relations;
    my $table = _table($name, $cb, row_base_class => $caller);

    my $relations = DBIx::QuickORM::Schema::RelationSet->new(@relations);

    {
        no strict 'refs';
        *{"$caller\::orm_table"}     = sub { $table };
        *{"$caller\::orm_relations"} = sub { $relations };
        push @{"$caller\::ISA"} => 'DBIx::QuickORM::Row';
    }

    return $table;
}

BEGIN {
    my @CLASS_SELECTORS = (
        ['column_class',   'COLUMN',   'TABLE',    'SCHEMA'],
        ['member_class',   'MEMBER',   'RELATION', 'SCHEMA'],
        ['relation_class', 'RELATION', 'SCHEMA'],
        ['row_base_class', 'TABLE',    'SCHEMA'],
        ['table_class',    'TABLE',    'SCHEMA'],
        ['source_class',   'TABLE'],
    );

    for my $cs (@CLASS_SELECTORS) {
        my ($name, @states) = @$cs;

        my $code = sub {
            my ($class) = @_;
            eval { require(mod2file($class)); 1 } or croak "Could not load class $class: $@";

            for my $state (@states) {
                my $params = $STATE{$state} or next;
                return $params->{$name} = $class;
            }

            croak "$name() must be called inside one of the following builders: " . join(', ' => map { lc($_) } @states);
        };

        no strict 'refs';
        *{$name} = $code;
    }
}

sub sql_spec {
    my %hash = @_ == 1 ? %{$_[0]} : (@_);

    my ($state) = @{$STATE{STACK} // []};
    croak "Must be called inside a builder" unless $state;

    my $params = $STATE{$state} or croak "Must be called inside a builder";

    my $specs = $params->{sql_spec} //= {};

    %$specs = (%$specs, %hash);

    return $specs;
}

sub relation {
    my ($name, $cb, @extra) = @_;

    croak "Too many arguments for relation" if @extra;

    my $relations = $STATE{RELATIONS} or croak "No 'relations' store found, must be nested under a schema or meta_table builder";

    my @caller = caller;
    my %params = (
        created => "$caller[1] line $caller[2]",
        members => [],
        plugins => _push_plugins(),
    );

    local $STATE{PLUGINS}  = $params{plugins};
    local $STATE{RELATION} = \%params;
    local $STATE{STACK}    = ['RELATION', @{$STATE{STACK} // []}];
    local $STATE{MEMBER};

    $cb->(%STATE);

    if (my $member = $STATE{MEMBER}) {
        my $class = first { $_ } (map { $_->member_class(%params, %STATE) } ordered_plugins($params{plugins})), 'DBIx::QuickORM::Relation::Member';
        eval { require(mod2file($class)); 1 } or croak "Could not load class $class: $@";
        my $mem = $class->new(%$member);
        push @{$params{members}} => $mem;
    }

    my $class = delete($params{relation_class}) // first { $_ } (map { $_->relation_class(%params, %STATE) } ordered_plugins($params{plugins})), 'DBIx::QuickORM::Relation';
    eval { require(mod2file($class)); 1 } or croak "Could not load class $class: $@";
    my $rel = $class->new(%params);

    if (my $names = $STATE{NAMES}) {
        if (my $have = $names->{$name}) {
            unless ($have->isa('DBIx::QuickORM::Relation') && $have->index eq $rel->index) {
                croak "There is already a source named '$name' ($have) from " . ($have->created // '');
            }
        }

        $names->{$name} = $rel;
    }

    push @$relations => $rel;

    return $rel;
}

sub member {
    my (@specs) = @_;

    my $relation = $STATE{RELATION} or croak "member() must be nested under a relation builder";

    my ($cb);
    my @caller = caller;
    my %params = (
        created => "$caller[1] line $caller[2]",
        plugins => {__ORDER__ => []},
    );

    # @specs may contain these in any order:
    # coderef  - callback to run
    # arrayref - list of columns
    # string   - table name
    # hashref  - contains all of the above

    for my $item (@specs) {
        my $type = ref($item);
        if ($type eq 'HASH') {
            %params = (%params, %$item);
        }
        elsif ($type eq 'CODE') {
            $cb = $item;
        }
        else {
            croak "'$item' is not a valid argument for member()";
        }
    }

    if ($cb) {
        local $STATE{TABLE}; # Mask the table so that columns() cannot accidentally pick it up in here
        local $STATE{MEMBER} = \%params;
        local $STATE{STACK} = ['MEMBER', @{$STATE{STACK} // []}];

        $cb->(%STATE);
    }

    my $class = delete($params{member_class}) // first { $_ } (map { $_->member_class(%params, %STATE) } ordered_plugins($params{plugins})), 'DBIx::QuickORM::Relation::Member';
    eval { require(mod2file($class)); 1 } or croak "Could not load class $class: $@";
    my $mem = $class->new(%params);

    push @{$relation->{members} //= []} => $mem;

    return $mem;
}

sub _member_table {
    my ($name, @extra) = @_;
    croak "Too many arguments for table under a member builder ($STATE{MEMBER}->{name}, $STATE{MEMBER}->{created})" if @extra;
    my $member = $STATE{MEMBER}->{table};
    $member->{table} = $name;
}

sub is_view {
    my $table = $STATE{TABLE} or croak "is_view() may only be used in a table builder";
    $table->{is_view} = 1;
}

sub is_temp {
    my $table = $STATE{TABLE} or croak "is_temp() may only be used in a table builder";
    $table->{is_temp} = 1;
}

sub columns {
    my @specs = @_;

    my @caller = caller;
    my $created = "$caller[1] line $caller[2]";

    my $member = $STATE{MEMBER};

    my $table;
    if ($member) {
        if (my $schema = $STATE{SCHEMA}) {
            $table = $schema->{tables}->{$member->{table}} if $member->{table};
        }
    }
    else {
        $table = $STATE{TABLE} or croak "columns may only be used in a table or member builder";
    }

    while (my $name = shift @specs) {
        my $spec = @specs && ref($specs[0]) ? shift(@specs) : undef;
        croak "Cannot specify column data or builder under a member builder" if $member && $spec;

        push @{$member->{columns} //= []} => $name if $member;

        if ($table) {
            if ($spec) {
                my $type = ref($spec);
                if ($type eq 'HASH') {
                    $table->{columns}->{$name}->{$_} = $spec->{$_} for keys %$spec;
                }
                elsif ($type eq 'CODE') {
                    local $STATE{COLUMN} = $table->{columns}->{$name} //= {created => $created, name => $name};
                    local $STATE{STACK}  = ['COLUMN', @{$STATE{STACK} // []}];
                    eval { $spec->(%STATE); 1 } or croak "Failed to build column '$name': $@";
                }
            }
            else {
                $table->{columns}->{$name} //= {created => $created, name => $name};
            }

            $table->{columns}->{$name}->{name} //= $name;
        }
        elsif ($spec) {
            croak "Cannot specify column data outside of a table builder";
        }
    }
}

BEGIN {
    my @COL_ATTRS = (
        [unique      => sub { @{$_[0]} > 1 ? undef : 1 }, {index => 'unique'}],
        [primary_key => 1, {set => 'primary_key', index => 'unique'}],
        [omit        => 1],
        [
            default => sub {
                my $sub = shift(@{$_[0]});
                croak "First argument to default() must be a coderef" unless ref($sub) eq 'CODE';
                return $sub;
            },
        ],
        [
            conflate => sub {
                my $class = shift(@{$_[0]});
                eval { require(mod2file($class)); 1 } or croak "Could not load class $class: $@";
                return $class;
            },
        ],
    );
    for my $col_attr (@COL_ATTRS) {
        my ($attr, $val, $params) = @$col_attr;

        my $code = sub {
            my @cols = @_;

            my $val = ref($val) ? $val->(\@cols) : $val;

            my $table = $STATE{TABLE} or croak "$attr can only be used inside a column or table builder";

            if (my $column = $STATE{COLUMN}) {
                croak "Cannot provide a list of columns inside a column builder ($column->{created})" if @cols;
                $column->{$attr} = $val;
                @cols = ($column->{name});
            }
            else {
                croak "Must provide a list of columns when used inside a table builder" unless @cols;

                my @caller  = caller;
                my $created = "$caller[1] line $caller[2]";

                for my $cname (@cols) {
                    my $col = $table->{columns}->{$cname} //= {created => $created};
                    $col->{$attr} = $val if defined $val;
                }
            }

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
        *{$attr} = $code;
    }
}

sub index {
    my $name = shift;
    my $cols = pop;
    my ($table_name) = @_;

    croak "A name is required as the first argument" unless $name;
    croak "A list of columns is required as the final argument" unless $cols && @$cols;

    my $indexes = $STATE{INDEXES} or croak "Must be used under either a schema builder, or a meta_table builder";

    if (my $table = $STATE{TABLE}) {
        croak "Must not provide a table name (omit the second argument: `index($name, \@cols)`) when used under a table builder"
            if $table_name;

        $table_name = $table->name;
    }
    elsif (!$table_name) {
        croak "You must specify a table name as the second argument unless used under a table or meta_table builder";
    }

    croak "Index '$name' is already defined on table" if $indexes->{$name};

    my @caller  = caller;
    my $created = "$caller[1] line $caller[2]";
    $indexes->{$name} = {table => $table_name, columns => $cols, name => $name, created => $created};
}

1;
