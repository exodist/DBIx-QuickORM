package DBIx::QuickORM::Conflator::UUID;
use strict;
use warnings;

sub qorm_parse {
    my $class = shift;
    my %params = @_;

    my $val = $params{value};

    return ($val->deflate(%params), $val) if blessed($val) && $val->isa($class);
    return ($val, undef);
}

sub qorm_inflate {
    my $class = shift;
    my %params = @_;

    my $val  = $params{value};
    my $col  = $params{column};
    my $type = $params{type};

}

sub qorm_deflate {
    my $class = shift;
    my %params = @_;

    my $val  = $params{value};
    my $col  = $params{column};
    my $type = $params{type};

}

1;
