package DBIx::QuickORM::Schema;
use strict;
use warnings;

use Carp qw/confess croak/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::Util qw/merge_hash_of_objs mod2file/;

use DBIx::QuickORM::Util::HashBase qw{
    <name
    +tables
    <accessor_name_cb
};

use DBIx::QuickORM::Util::Has qw/Created Plugins/;

sub init {
    my $self = shift;

    croak "'name' is a required attribute" unless $self->{+NAME};
}

sub compile {
    my $self = shift;

    my $tables = $self->{+TABLES};

    for my $tname (keys %$tables) {
        my $table = $tables->{$tname};

        my $rels = $table->relations;
        for my $alias (keys %$rels) {
            my $rel = $rels->{$alias};
            my $t2 = $rel->table;
            next if $self->{+TABLES}->{$t2};

            confess "Relation '$alias' in table '$tname' points to table '$t2' but that table does not exist";
        }

        my $acc = $table->accessors or next;
        my $pkg = $acc->{inject_into} // $self->_gen_row_package($table->row_class);

        my ($meta);

        {
            no strict 'refs';
            if (defined(&{"$pkg\::_quickorm_compile_meta"})) {
                $meta = $pkg->_quickorm_compile_meta;
            }
            else {
                $meta = {};
                *{"$pkg\::_quickorm_compile_meta"} = sub { $meta };
            }
        }

        my $inj = $meta->{injected_accessors} //= {};

        my $accessors = $table->generate_accessors($pkg);
        for my $name (keys %$accessors) {
            my $spec = $accessors->{$name};

            if ($pkg->can($name)) {
                my $i = $inj->{$name};
                croak "Accessor '$name' for $spec->{debug} would override existing sub" unless $i;
                croak "Accessor '$name' was originally injected for $i->debug, attempt to override it for $spec->{debug}" unless $i->{debug} eq $spec->{debug};
            }

            $inj->{$name} = $spec;

            no strict 'refs';
            no warnings 'redefine';
            *{"$pkg\::$name"} = $spec->{sub};
        }

        $tables->{$tname} = $table->clone(row_class => $pkg) unless $pkg eq $table->row_class;
    }
}

my $GEN_ID = 1;
sub _gen_row_package {
    my $self = shift;
    my ($parent) = @_;

    $parent //= 'DBIx::QuickORM::Row';
    require(mod2file($parent));

    my $pkg = "DBIx::QuickORM::Row::__GEN" . ($GEN_ID++) . "__";
    my $file = mod2file($pkg);
    $INC{$file} = __FILE__;

    {
        no strict 'refs';
        no warnings 'once';
        push @{"$pkg\::ISA"} => $parent;
    }

    return $pkg;
}

sub tables       { values %{$_[0]->{+TABLES}} }
sub table        { $_[0]->{+TABLES}->{$_[1]} or croak "Table '$_[1]' is not defined" }
sub maybe_table  { return $_[0]->{+TABLES}->{$_[1]} // undef }

sub add_table {
    my $self = shift;
    my ($name, $table) = @_;

    croak "Table '$name' already defined" if $self->{+TABLES}->{$name};

    return $self->{+TABLES}->{$name} = $table;
}

sub merge {
    my $self = shift;
    my ($other, %params) = @_;

    $params{+TABLES}  //= merge_hash_of_objs($self->{+TABLES}, $other->{+TABLES}, \%params);
    $params{+PLUGINS} //= $self->{+PLUGINS}->merge($other->{+PLUGINS});
    $params{+NAME}    //= $self->{+NAME};

    return ref($self)->new(%$self, %params);
}

sub clone {
    my $self   = shift;
    my %params = @_;

    $params{+TABLES}    //= [map { $_->clone } $self->tables];
    $params{+NAME}      //= $self->{+NAME};
    $params{+PLUGINS}   //= $self->{+PLUGINS}->clone();

    return ref($self)->new(%$self, %params);
}

1;

__END__

