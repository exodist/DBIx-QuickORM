package DBIx::QuickORM::Conflator;
use strict;
use warnings;

use Scalar::Util qw/blessed/;
use Carp qw/confess/;

use DBIx::QuickORM::Util::HashBase qw{
    +inflate
    +deflate
    +parse
};

sub init {
    my $self = shift;

    my $parse   = $self->{+PARSE}   or confess "The 'parse' attribute is required";
    my $inflate = $self->{+INFLATE} or confess "The 'inflate' attribute is required";
    my $deflate = $self->{+DEFLATE};    # Not required

    confess "The 'parse' attribute must be a coderef, got '$parse'"     unless ref($parse) eq 'CODE';
    confess "The 'inflate' attribute must be a coderef, got '$inflate'" unless ref($inflate) eq 'CODE';
    confess "The 'deflate' attribute must be a coderef, got '$deflate'" if $deflate && ref($deflate) ne 'CODE';

    $self->{+DEFLATE} //= sub { confess "$_[0]->deflate() is not implemented" }
}

sub quickorm_parse   { shift->{+PARSE}->(@_) }
sub quickorm_inflate { shift->{+INFLATE}->(@_) }
sub quickorm_deflate { shift->{+DEFLATE}->(@_) }

1;
