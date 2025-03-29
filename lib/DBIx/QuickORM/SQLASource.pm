package DBIx::QuickORM::SQLASource;
use strict;
use warnings;

use Role::Tiny::With qw/with/;
with 'DBIx::QuickORM::Role::SQLASource';

sub new {
    my $class = shift;
    my ($sql_ref) = @_;

    return bless(\$sql_ref, $class);
}

sub name        { ${$_[0]} }
sub sqla_source { ${$_[0]} }
sub sqla_fields { '*' }

sub sqla_rename { undef }
sub row_class   { undef }
sub primary_key { undef }
sub column      { undef }

1;
