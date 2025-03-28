package DBIx::QuickORM::Dialect::MySQL::Community;
use strict;
use warnings;

our $VERSION = '0.000005';

use Carp qw/croak/;

use parent 'DBIx::QuickORM::Dialect::MySQL';
use DBIx::QuickORM::Util::HashBase;

sub dialect_name { 'MySQL::Community' }

sub init {
    my $self = shift;

    $self->SUPER::init();

    my $vendor = $self->db_vendor;
    croak "The mysql vendor is '$vendor' not Community" unless $vendor =~ m/Community/i;
}

1;
