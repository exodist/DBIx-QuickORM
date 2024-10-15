package DBIx::QuickORM::Conflator::DateTime;
use strict;
use warnings;

use Scalar::Util();
use Carp();

use overload '""' => \&as_string;

sub as_string { $_[0]->{string} //= $_[0]->{datetime}->()->stringify }

sub qorm_sql_type {
    my $class = shift;
    my %params = @_;

    my $con = $params{connection};

    if (my $type = $con->supports_datetime) {
        return $type;
    }

    return 'DATETIME';
}

sub qorm_inflate {
    my $class = shift;
    my %params = @_;

    my $val = $params{value} or return undef;

    my $dt;
    if (Scalar::Util::blessed($val)) {
        return $val if $val->isa(__PACKAGE__);
        $dt = $val if $val->isa('DateTime');
    }

    unless ($dt) {
        my $fmt = $params{source}->db->datetime_formatter;
        $dt = $fmt->parse_datetime($val);
    }

    return bless({datetime => sub { $dt }, string => $dt->stringify}, $class);
}

sub qorm_deflate {
    my $in = shift;
    my %params = @_;

    $params{value} //= $in if Scalar::Util::blessed($in);

    my $val = $params{value} or return undef;
    my $inf = $in->qorm_inflate(\%params);

    my $dt = $val->{datetime}->();

    my $fmt = $params{source}->db->datetime_formatter;
    return $fmt->format_datetime($dt);
}

sub import {}
sub DESTROY {}

our $AUTOLOAD;
sub AUTOLOAD {
    my ($self) = @_;

    my $meth = $AUTOLOAD;
    $meth =~ s/^.*:://g;

    my $class = Scalar::Util::blessed($self) // $self;

    Carp::croak(qq{Can't locate object method "$meth" via package "$self"})
        unless Scalar::Util::blessed($self);

    my $sub = $self->can($meth) or Carp::croak(qq{Can't locate object method "$meth" via package "$class"});

    goto &$sub;
}

sub can {
    my $self = shift;

    return $self->UNIVERSAL::can(@_) unless Scalar::Util::blessed($self);

    if (my $sub = $self->UNIVERSAL::can(@_)) {
        return $sub;
    }

    my ($name) = @_;

    return sub { shift->{datetime}->()->$name(@_) }
        if $self->{datetime}->()->can(@_);

    return undef;
}

1;
