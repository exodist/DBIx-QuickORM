package DBIx::QuickORM::Util::Has::Created;
use strict;
use warnings;

use Carp qw/confess/;

use Importer Importer => 'import';

our @EXPORT = qw/CREATED created gen_created/;

sub CREATED() { 'created' }

sub apply {
    my $class = shift;
    my ($into, $HAS, $list) = @_;

    if ($into->can('add_pre_init')) {
        $into->add_pre_init(sub {
            my $self = shift;
            $self->{+CREATED} //= $self->gen_created();
        });
    }
    elsif (!$list || !@$list) {
        confess "Consuming class is not built with Object::HashBase, and no import list was specified";
    }

    $list //= \@EXPORT;
    no strict 'refs';
    *{"$into\::$_"} = $class->can($_) for @$list;
}

sub created { $_[0]->{+CREATED} }

sub gen_created {
    my $self = shift;

    my @caller;
    if (@_ <= 1) {
        my ($level) = @_;
        $level //= 0;
        $level += 2;
        @caller = caller($level);
    }
    else {
        @caller = @_;
    }

    confess "Could not find caller info" unless @caller;

    return "$caller[1] line $caller[2]";
}

1;
