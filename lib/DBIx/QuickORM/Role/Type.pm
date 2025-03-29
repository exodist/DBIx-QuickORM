package DBIx::QuickORM::Role::Type;
use strict;
use warnings;

our $VERSION = '0.000005';

use Role::Tiny;

requires qw{
    qorm_inflate
    qorm_deflate
    qorm_compare
    qorm_affinity
};

1;
