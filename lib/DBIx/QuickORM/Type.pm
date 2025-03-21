package DBIx::QuickORM::Type;
use strict;
use warnings;

use Carp qw/croak/;

sub inflate { croak "'inflate' is not implemented" }
sub deflate { croak "'deflate' is not implemented" }

1;
