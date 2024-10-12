package DBIx::QuickORM::Conflator::UUID;
use strict;
use warnings;

use Carp qw/confess/;
use Scalar::Util qw/blessed/;

use UUID qw/unparse_upper parse uuid7/;

use DBIx::QuickORM::Util::HashBase qw{
    +as_string
    +as_binary
};

sub looks_like_uuid {
    my ($in) = @_;
    return $in if $in && $in =~ m/^[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}$/i;
    return undef;
}

sub init {
    my $self = shift;

    $self->{+AS_STRING} //= delete $self->{string} if $self->{string};
    $self->{+AS_BINARY} //= delete $self->{binary} if $self->{binary};

    if (my $str = $self->{+AS_STRING}) {
        confess "String '$str' does not look like a UUID" unless looks_like_uuid($str);
    }
    elsif(!$self->{+AS_BINARY}) {
        confess q{You must provide either ('as_string' => $UUID_STRING) or ('as_binary' => $UUID_BINARY)};
    }
}

sub create { $_[0]->new(AS_STRING() => uc(uuid7())) }

sub as_string { $_[0]->{+AS_STRING} //= do {my $out; unparse_upper($_[0]->{+AS_BINARY}, $out); $out } }
sub as_binary { $_[0]->{+AS_BINARY} //= do {my $out; parse($_[0]->{+AS_STRING}, $out); $out } }

sub qorm_sql_type {
    my $class = shift;
    my %params = @_;

    my $con = $params{connection};

    if (my $type = $con->supports_uuid) {
        return $type;
    }

    return 'BYTEA' if $con->db->isa('DBIx::QuickORM::DB::PostgreSQL');
    return 'BINARY(16)';
}

sub qorm_inflate {
    my $class = shift;
    my %params = @_;

    my $val = $params{value};

    return undef unless defined $val;

    return $val if blessed($val) && $val->isa($class);

    if(looks_like_uuid($val)) {
        return $class->new(AS_STRING() => uc($val));
    }

    return $class->new(AS_BINARY() => $val);
}

sub qorm_deflate {
    my $in = shift;
    my %params = @_;

    $params{value} //= $in if blessed($in);

    my $type = $params{type}->{data_type};

    my $inf = $in->qorm_inflate(%params) // return undef;

    if ($type =~ m/(bin|byte|blob)/i) {
        my $out = $inf->as_binary;
        if (my $con = $params{quote_bin}) {
            return \($con->dbh->quote($out, DBI::SQL_BINARY())) if $con->db->quote_binary_data;
        }
        return $out;
    }

    return $inf->as_string;
}

1;
