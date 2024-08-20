package DBIx::QuickORM::Util;
use strict;
use warnings;

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

our @EXPORT = qw/ mod2file delegate alias parse_hash_arg /;

use base 'Exporter';

sub parse_hash_arg {
    my $self = shift;
    return $_[0] if @_ == 1 && ref($_[0]) eq 'HASH';
    return {@_};
}

sub mod2file {
    my ($mod) = @_;

    my $file = $mod;
    $file =~ s{::}{/}g;
    $file .= ".pm";

    return $file;
}

sub delegate {
    my ($meth, $to, $to_meth) = @_;
    my $caller = caller;
    $to_meth //= $meth;

    croak "A method name must be provided as the first argument" unless $meth;
    croak "A method that returns an object to which we will delegate must be provided" unless $to;
    croak "The '$meth' method is already defined for $caller" if $caller->can($meth);
    croak "The '$to' method has not been defined for $caller" unless $caller->can($to);

    my $code = sub {
        my $self = shift;
        my $del = $self->$to or croak "'$caller->$to' did not return an object for delegation";
        return $del->$to_meth(@_);
    };

    no strict 'refs';
    *{"$caller\::$meth"} = $code;
}

sub alias {
    my ($from, $to) = @_;
    my $caller = caller;

    croak "$caller already defines the '$to' method" if $caller->can($to);

    my $sub = $caller->can($from) or croak "$caller does not have the '$from' method defined";
    no strict 'refs';
    *{"$caller\::$to"} = $sub;
}

1;
