package DBIx::QuickORM::Source;
use strict;
use warnings;

use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use DBIx::QuickORM::Util qw/parse_hash_arg/;

use DBIx::QuickORM::Source::Join;

use DBIx::QuickORM::Util::HashBase qw{
    <table
    <join_order
    <joins
    <orm
    +db
    +schema
    <as
};

use DBIx::QuickORM::Util::Has qw/Created/;
use DBIx::QuickORM::Util::Has Plugins => [qw/PLUGINS add_plugin ordered_plugins/];

sub db      { $_[0]->{+DB}      //= $_[0]->{+ORM}->db }
sub schema  { $_[0]->{+SCHEMA}  //= $_[0]->{+ORM}->schema }
sub plugins { $_[0]->{+PLUGINS} //= $_[0]->{+ORM}->plugins }

sub find   {  }
sub fetch  {  }
sub select {  }
sub insert {  }
sub delete {  }

sub formulate_search { }

sub init {
    my $self = shift;

    croak "The 'table' attribute must be provided" unless $self->{+TABLE};

    croak "The 'table' attribute must be an instance of 'DBIx::QuickORM::Table'"
        unless $self->{+TABLE}->isa('DBIx::QuickORM::Table');

    my $jo = $self->{+JOIN_ORDER} //= [];
    my $j = $self->{+JOINS} //= {};

    my %seen;
    for my $join_name (@$jo) {
        $seen{$join_name}++;
        croak "'join_order' should be a list of join names (as), got '$join_name'" if ref($join_name);
        my $join = $j->{$join_name} or croak "No join under name '$join_name'";
        croak "Joins must be instances of 'DBIx::QuickORM::Source::Join', got `$join_name => $join`" unless blessed($join) && $join->isa('DBIx::QuickORM::Source::Join');
    }

    if (my @bad = grep { !$seen{$_} } keys %$j) {
        croak "The following join are provided, but are not in the ordered list: " . join(', ' => @bad);
    }
}

sub clone {
    my $self   = shift;
    my %params = @_;
    my $class  = blessed($self);

    unless ($params{+CREATED}) {
        my @caller = caller();
        $params{+CREATED} = "$caller[1] line $caller[2]";
    }

    return $class->new(
        %$self,
        join_order => [@{$self->{+JOIN_ORDER} // []}],
        joins      => {%{$self->{+JOINS}      // {}}},
        %params,
    );
}

sub join {
    my $self = shift;
    my ($table, %params) = @_;

    unless ($params{+CREATED}) {
        my @caller = caller();
        $params{+CREATED} = "$caller[1] line $caller[2]";
    }

    my $join = DBIx::QuickORM::Source::Join->new(table => $self->{+SCHEMA}->table($table), plugins => $self->plugins, %params);
    my $as = $join->as;

    my $new = $self->clone(created => $params{+CREATED});
    my $jo  = $new->{+JOIN_ORDER};
    my $j   = $new->{+JOINS};

    croak "There is already a join with the name (as) '$as'" if $j->{$as};
    $j->{$as} = $join;
    push @{$jo} => $as;

    return $new;
}

sub update_or_insert {
    my $self = shift;
    my $row_data = $self->parse_hash_arg(@_);

    my $row;
    $self->db->transaction(sub {
        my $search = $self->formulate_search($row_data);
        if ($row = $self->find($search)) {
            $row->update($row_data);
        }
        else {
            $row = $self->insert($row_data);
        }
    });

    return $row;
}

sub find_or_insert {
    my $self = shift;
    my $row_data = $self->parse_hash_arg(@_);

    my $row;
    $self->db->transaction(sub {
        my $search = $self->formulate_search($row_data);
        $row = $self->find($search) // $self->insert($row_data);
    });

    return $row;
}

1;
