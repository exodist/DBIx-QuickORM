package DBIx::QuickORM;
use strict;
use warnings;

our $VERSION = 0.001;

use DBIx::QuickORM::DB;
use DBIx::QuickORM::Row;
use DBIx::QuickORM::Schema;
use DBIx::QuickORM::Meta::Table;
use DBIx::QuickORM::Meta::Column;
use DBIx::QuickORM::Meta::Relation;

use DBIx::QuickORM::Util qw/mod2file alias/;

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use Importer Importer => 'import';

my @EXPORT_DB = qw{
    attr attribute attributes attrs
    db   db_type   dbd
    dsn  connect
    host hostname  socket
    pass password
    port
    user username
};

my @EXPORT_COL = qw{
    col cols         column        columns
    pk  primary_key
    unique
    inflate

    sql_type
    sql_default
    sql_serial sql_autoinc
    not_null
    nullable
    on_delete
};

my @EXPORT_RELATION = qw{
    relation
    member
};

my @EXPORT_TABLE = (
    qw/table row_class/,
    @EXPORT_RELATION,
    @EXPORT_COL,
);

my @EXPORT_META = (
    qw/table_meta generate_methods/,
    @EXPORT_RELATION,
    @EXPORT_COL,
);

my @EXPORT_SCHEMA = (
    qw/schema auto_fill/,
    @EXPORT_TABLE,
    @EXPORT_DB,
);

our @EXPORT_OK = @EXPORT_SCHEMA;

our %EXPORT_TAGS = (
    DB     => \@EXPORT_DB,
    META   => \@EXPORT_META,
    ROWS   => \@EXPORT_COL,
    SCHEMA => \@EXPORT_SCHEMA,
    TABLE  => \@EXPORT_TABLE,
);

sub unimport { Importer->new(from => $_[0])->do_unimport() }

alias attr        => 'attribute';
alias attr        => 'attributes';
alias attr        => 'attrs';
alias column      => 'col';
alias column      => 'cols';
alias column      => 'columns';
alias host        => 'hostname';
alias hostname    => 'socket';
alias pass        => 'password';
alias primary_key => 'pk';
alias user        => 'username';
alias sql_serial  => 'sql_autoinc';

our %STATE;

sub schema {
    my $code = pop;
    my $name = shift;

    local %STATE;

    unless ($name) {
        my @caller = caller;
        $name = "DBIx::QuickORM::Schema created at $caller[1] line $caller[2]";
    }

    my $schema = DBIx::QuickORM::Schema->new(name => $name);
    local $STATE{SCHEMA} = $schema;

    $code->(%STATE);

    $schema->recompile() if $schema->db;

    __PACKAGE__->unimport_from(scalar caller);

    return $schema;
}

sub auto_fill {
    my $schema = $STATE{SCHEMA} or croak "Must be called inside of a schema builder";
    $schema->set_auto_fill;
}

sub table_class {
    my ($class) = @_;
    eval { require(mod2file($class)); 1 } or croak "Could not load table class '$class': $@";
    my $schema = $STATE{SCHEMA} or croak "Must be inside a schema builder";
    $schema->set_table_class($class);
}

sub table_meta {
    my $caller = caller;
    my $table = table(@_);

    {
        no strict 'refs';
        *{"$caller\::orm_tiny_table_meta"} = sub { $table };
        push @{"$caller\::ISA"} => 'DBIx::QuickORM::Row';
    }

    $table->set_row_class($caller);

    $table->inject_methods;

    return $table;
}

sub row_class {
    my ($class, %params) = @_;

    my $schema = $STATE{SCHEMA} or croak "Must be used inside a schema builder";
    my $table  = $STATE{TABLE}  or croak "Must be used inside a table builder";

    my $file = mod2file($class);
    unless (eval { require($file); 1 }) {
        my $err = $@;
        croak "Could not load row class '$class': $err"
            unless $params{generate} && $err =~ m{^Can't locate \Q$file\E in \@INC};

        $INC{$file} ||= 1;
    }

    $table->set_row_class($class);

    if ($class->can('orm_tiny_table_meta')) {
        my $merge = $class->orm_tiny_table_meta;
        $table->fill(schema => $schema, from_db => $table);
    }

    $table->inject_methods unless $params{no_inject};

    return $class;
}

sub table {
    my ($name, $code_or_class) = @_;
    my $type = ref($code_or_class);

    my $schema = $STATE{SCHEMA};

    my $table;
    if ($type && $type eq 'CODE') {
        my $tc = $schema ? $schema->table_class // 'DBIx::QuickORM::Meta::Table' : 'DBIx::QuickORM::Meta::Table';
        eval { require(mod2file($tc)); 1 } or croak "Could not load table class '$tc': $@";
        $table = $tc->new(name => $name);

        my $code = $code_or_class;
        local $STATE{TABLE} = $table;
        $code->(%STATE);
    }
    else {
        my $class = $code_or_class;
        eval { require(mod2file($class)); 1 } or croak "Could not load row class '$class': $@";

        croak "Class '$class' cannot be used here as it does not implement orm_tiny_table_meta()"
            unless $class->can('orm_tiny_table_meta');

        $table = $class->orm_tiny_table_meta->clone;
    }

    return $schema->add_table($table) if $schema;
    return $table;
}

sub column {
    my $code = pop if @_ && ref($_[-1]) eq 'CODE';
    my @names = @_;

    croak "Must provide at least 1 column name" unless @names;

    my @out;
    for my $name (@names) {
        my $col = DBIx::QuickORM::Meta::Column->new(name => $name);

        next unless $code;

        local $STATE{COL} = $col;
        $code->(%STATE);

        if (my $table = $STATE{TABLE}) {
            push @out => $table->add_column($col);
        }
        else {
            push @out => $col;
        }
    }

    return @out;
}

sub primary_key {
    my @cols = @_;

    if (my $col = $STATE{COL}) {
        croak "primary_key() does not take arguments inside a column builder" if @cols;
        $col->set_primary_key(1);
        return;
    }

    my $table = $STATE{TABLE} or croak "Must be used inside a table or column builder";

    for my $name (@cols) {
        if (my $col = $table->has_column($name)) {
            $col->set_primary_key(1);
        }
        else {
            $table->add_column(DBIx::QuickORM::Meta::Column->new(name => $name, primary_key => 1));
        }
    }
}

sub unique {
    my @cols = @_;
    if (my $col = $STATE{COL}) {
        croak "unique() does not take arguments inside a column builder" if @cols;
        $col->set_unqiue(1);

        if (my $table = $STATE{TABLE}) {
            $table->add_unique($col->name);
        }

        return;
    }

    my $table = $STATE{TABLE} or croak "Must be used inside a table or column builder";

    for my $name (@cols) {
        next if $table->has_column($name);
        $table->add_column(DBIx::QuickORM::Meta::Column->new(name => $name));
    }

    $table->add_unique(@cols);
}

sub inflate {
    my $type = pop or croak "Must specify an inflation type as the final argument to inflate()";
    my @cols = @_;

    $type =~ s/^::/DBIx::QuickORM::Inflate::/;
    eval { require(mod2file($type)); 1 } or croak "Invalid inflation type '$type': $@";
    croak "Type '$type' does not implement the orm_tiny_inflate() class method" unless $type->can('orm_tiny_inflate');
    croak "Type '$type' does not implement the orm_tiny_deflate() class method" unless $type->can('orm_tiny_deflate');

    if (my $col = $STATE{COL}) {
        croak "unique() does not take column names inside a column builder" if @cols;
        $col->set_inflate($type);
        return;
    }

    my $table = $STATE{TABLE} or croak "Must be used inside a table or column builder";

    for my $name (@cols) {
        if (my $col = $table->has_column($name)) {
            $col->set_inflate($type);
        }
        else {
            $table->add_column(DBIx::QuickORM::Meta::Column->new(name => $name, inflate => $type));
        }
    }
}

sub relation {
    my ($name, $code_or_name2) = @_;

    my ($code, $name2);
    if (ref($code_or_name2) eq 'CODE') {
        $code = $code_or_name2;
    }
    else {
        $name2 = $code_or_name2;
    }

    my $rel = DBIx::QuickORM::Meta::Relation->new(name => $name);

    if (my $table = $STATE{TABLE}) {
        if (my $col = $STATE{col}) {
            $rel->add_member(table => $table->name, columns => [$col->name], name => $name2 || $name);
        }
        else {
            croak "A relation may be added in a schema builder, or in a column builder, but not directly in a table builder";
        }

        $table->add_relation($rel);
    }
    elsif($name2) {
        croak "Second argument must be a coderef unless used inside a column builder";
    }

    local $STATE{RELATION} = $rel;

    $code->($rel) if $code;

    $STATE{SCHEMA}->add_relation($rel) if $STATE{SCHEMA};

    return $rel;
}

sub member {
    my ($table, $cols, $name) = @_;

    $cols = [$cols] unless ref($cols);
    my $m = {table => $table, columns => $cols, name => $name};

    if (my $rel = $STATE{RELATION}) {
        $rel->add_member($m);

        if (my $schema = $STATE{SCHEMA}) {
            if (my $table = $schema->meta_table($table)) {
                $table->add_relation($rel);
            }
            else {
                croak "Table '$table' has not been defined yet";
            }
        }
    }

    return $m;
}

sub not_null { $STATE{COL} ? $STATE{COL}->set_nullable(0)                        : croak "Must be called inside a column builder" }
sub nullable { $STATE{COL} ? $STATE{COL}->set_nullable(@_ ? ($_[0] ? 1 : 0) : 1) : croak "Must be called inside a column builder" }

# sql_type can also take a hashref {DRIVER => TYPE} or a function sub($driver) { return TYPE }
sub sql_type    { $STATE{COL} ? $STATE{COL}->set_sql_type(@_)    : croak "Must be called inside a column builder" }
sub sql_default { $STATE{COL} ? $STATE{COL}->set_sql_default(@_) : croak "Must be called inside a column builder" }
sub sql_serial  { $STATE{COL} ? $STATE{COL}->set_sql_serial(@_)  : croak "Must be called inside a column builder" }
sub on_delete   { $STATE{COL} ? $STATE{COL}->set_on_delete(@_)   : croak "Must be called inside a column builder" }

sub db {
    if (@_ == 1 && blessed($_[0]) && $_[0]->isa('DBIx::QuickORM::DB')) {
        croak "Must be inside a schema builder" unless $STATE{SCHEMA};
        $STATE{SCHEMA}->set_db($_[0]);
        return $_[0];
    }

    my ($name, $code) = @_;

    my $db = DBIx::QuickORM::DB->new(name => $name);

    local $STATE{DB} = $db;
    $code->(%STATE);

    $db->set_type($1) if $name =~ m/(PostgreSQL|Pg|MySQL|MariaDB|Percona|SQLite)/ && !$db->type;
    $db->set_dbd($1)  if $name =~ m/^(DBD::\S+)/                                  && !$db->dbd;

    $db->recompile();

    if ($STATE{SCHEMA}) {
        $STATE{SCHEMA}->set_db($db);
    }

    return $db;
}

sub db_type    { $STATE{DB} ? $STATE{DB}->set_type(@_)     : croak "Must be inside a DB builder" }
sub dbd        { $STATE{DB} ? $STATE{DB}->set_dbd(@_)      : croak "Must be inside a DB builder" }
sub port       { $STATE{DB} ? $STATE{DB}->set_port(@_)     : croak "Must be inside a DB builder" }
sub host       { $STATE{DB} ? $STATE{DB}->set_hostname(@_) : croak "Must be inside a DB builder" }
sub dsn        { $STATE{DB} ? $STATE{DB}->set_dsn(@_)      : croak "Must be inside a DB builder" }
sub user       { $STATE{DB} ? $STATE{DB}->set_username(@_) : croak "Must be inside a DB builder" }
sub pass       { $STATE{DB} ? $STATE{DB}->set_password(@_) : croak "Must be inside a DB builder" }
sub connect(&) { $STATE{DB} ? $STATE{DB}->set_connect(@_)  : croak "Must be inside a DB builder" }

sub attr {
    my $db = $STATE{DB} or croak "Not inside a DB builder";
    my $attrs = $db->attributes;
    %$attrs = (%$attrs, @_);
}

1;
