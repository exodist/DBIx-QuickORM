package DBIx::QuickORM::Connection::Aside;
use strict;
use warnings;

use Carp qw/croak/;

use parent 'DBIx::QuickORM::Connection::Async';
use DBIx::QuickORM::Util::HashBase;

sub clear { $_[0]->{+CONNECTION}->clear_aside($_[0]) }

1;
