package DBIx::QuickORM::Util::Has::SQLSpec;
use strict;
use warnings;

use Carp qw/confess croak/;
use Scalar::Util qw/blessed/;
use Importer Importer => 'import';

use DBIx::QuickORM::SQLSpec;

our @EXPORT = qw/SQL_SPEC sql_spec/;

sub SQL_SPEC() { 'sql_spec' }

sub apply {
    my $class = shift;
    my ($into, $HAS, $list) = @_;

    if ($into->can('add_pre_init')) {
        $into->add_pre_init(sub {
            my $self = shift;
            $self->{+SQL_SPEC} //= DBIx::QuickORM::SQLSpec->new;
            $self->{+SQL_SPEC} = DBIx::QuickORM::SQLSpec->new($self->{+SQL_SPEC}) unless blessed($self->{+SQL_SPEC});
        });
    }
    elsif (!$list || !@$list) {
        confess "Consuming class is not built with Object::HashBase, and no import list was specified";
    }

    $list //= \@EXPORT;
    no strict 'refs';
    *{"$into\::$_"} = $class->can($_) for @$list;
}

sub sql_spec { $_[0]->{+SQL_SPEC} }

1;
