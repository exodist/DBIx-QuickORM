package DBIx::QuickORM::Cache;
use strict;
use warnings;

sub new {
    my $class = shift;
    return bless({}, $class);
}

sub new_transaction { }

sub find_row  { undef }
sub clear     { undef }
sub prune     { undef }

sub prune_source  { undef }
sub remove_source { undef }

sub add_row            { $_[1] }
sub add_source_row     { $_[1] }
sub uncache_source_row { $_[2] }

1;

