package DBIx::QuickORM::Cache;
use strict;
use warnings;

require DBIx::QuickORM::RowState;
sub row_state_class() { 'DBIx::QuickORM::RowState' }

sub new {
    my $class = shift;
    return bless({}, $class);
}

sub find_row  { undef }
sub clear     { undef }
sub prune     { undef }

sub prune_source_cache  { undef }
sub remove_source_cache { undef }

sub add_row            { $_[1] }
sub add_source_row     { $_[1] }
sub uncache_source_row { $_[2] }

1;

