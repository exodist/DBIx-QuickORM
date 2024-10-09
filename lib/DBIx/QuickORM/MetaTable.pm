package DBIx::QuickORM::MetaTable;
use strict;
use warnings;

use Carp qw/confess/;

sub import {
    my $class = shift;
    my ($name, $cb, $extra) = @_;

    my $level = 0;
    my $caller = caller($level++);
    $caller = caller($level++) while $caller =~ m/BEGIN::Lift/;

    my $meta_table = $caller->can('_meta_table') // $caller->can('meta_table')
        or confess "Package '$caller' does not have the meta_table() function. Did you forget to `use DBIx::QuickORM ':META_TABLE';` first?";

    confess "loading $class requires a table name as the first argument" unless $name && !ref($name);
    confess "loading $class requires a subroutine reference as the second argument" unless $cb and ref($cb) eq 'CODE';
    confess "Too many arguments when loading $class" if $extra;

    $meta_table->($name, $cb);
}

1;
