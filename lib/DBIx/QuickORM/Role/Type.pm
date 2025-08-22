package DBIx::QuickORM::Role::Type;
use strict;
use warnings;

our $VERSION = '0.000018';

use Scalar::Util qw/blessed/;
use Carp qw/croak confess/;

use Role::Tiny;

requires qw{
    qorm_inflate
    qorm_deflate
    qorm_compare
    qorm_affinity
    qorm_sql_type
};

sub qorm_register_type {
    my $this = shift;
    my $class = ref($this) || $this;
    croak "'$class' does not implement qorm_register_type() and cannot be used with autotype()";
}

sub parse_conflate_args {
    my ($proto, %params);
    $proto = shift if @_ % 2;

    if (!blessed($_[0]) && eval { $_[0]->does(__PACKAGE__) ? 1 : 0 }) {
        (@params{qw/class value/}) = (shift(@_), shift(@_));
        %params = (%params, @_);
    }
    else {
        %params = @_;
    }

    if ($proto) {
        if (blessed($proto)) {
            $params{value} //= $proto;
        }
        else {
            my $ref = ref($proto);
            my $is_class;
            if ($ref) {
                $is_class = 0;
            }
            else {
                my $file = "$proto.pm";
                $file =~ s{::}{/}g;
                $is_class = $INC{$file} ? 1 : 0;
            }

            if ($is_class) {
                $params{class} //= $proto;
            }
            else {
                $params{value} //= $proto;
            }
        }
    }

    confess "'value' argument must be present unless called on an instance of a type class" unless exists $params{value};

    $params{class} //= blessed($params{value}) // caller;

    return \%params if $params{affinity};

    my $source  = $params{source}  // return \%params;
    my $dialect = $params{dialect} // return \%params;
    my $field   = $params{field}   // return \%params;
    $params{affinity} = $source->field_affinity($field, $dialect);

    return \%params;
}

1;
