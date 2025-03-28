package DBIx::QuickORM::Type;
use strict;
use warnings;

our $VERSION = '0.000005';

use Carp qw/croak confess/;

use DBIx::QuickORM::Util::HashBase;

sub to_storage {  }
sub to_perl    {  }

1;
