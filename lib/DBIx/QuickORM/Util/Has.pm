package DBIx::QuickORM::Util::Has;
use strict;
use warnings;

use Carp qw/confess/;

use DBIx::QuickORM::Util qw/mod2file/;

sub import {
    my $class = shift;
    my $into = caller;

    my $HAS;
    if ($into->can('QORM_HAS')) {
        $HAS = $into->QORM_HAS;
    }
    else {
        $HAS = {};
        no strict 'refs';
        *{"$into\::QORM_HAS"} = sub { $HAS };
    }

    while (my $name = shift @_) {
        my $have_list = @_ && ref($_[0]) eq 'ARRAY';
        my $list = $have_list ? shift(@_) : undef;

        my $has = "DBIx::QuickORM::Util::Has::$name";

        local $@;
        eval { require(mod2file($has)); 1 } or confess "Could not load '$has': $@";

        $has->apply($into, $HAS, $list);
        $HAS->{$name}++;
    }

    return;
}

1;
