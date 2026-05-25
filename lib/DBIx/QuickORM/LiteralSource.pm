package DBIx::QuickORM::LiteralSource;
use strict;
use warnings;

our $VERSION = '0.000020';

use Role::Tiny::With qw/with/;

use Carp qw/croak/;

with 'DBIx::QuickORM::Role::Source';

=pod

=encoding UTF-8

=head1 NAME

DBIx::QuickORM::LiteralSource - A raw SQL fragment used as a query source.

=head1 DESCRIPTION

A source (see L<DBIx::QuickORM::Role::Source>) backed by a literal SQL
string rather than a table, view, or join. The object is a blessed scalar
reference holding the SQL; C<source_db_moniker> returns that SQL verbatim.

Literal sources carry no schema metadata: they expose no fields, no primary
key, and no row class, so the field/key accessors return nothing and the
source is not cachable. C<fields_to_fetch> is C<['*']>.

=head1 SYNOPSIS

    my $source = DBIx::QuickORM::LiteralSource->new("SELECT * FROM users");

=cut

sub new {
    my $class = shift;
    my ($literal) = @_;

    unless (ref($literal)) {
        my $sql = $literal;
        $literal = \$sql;
    }

    croak "'$literal' is not a scalar reference" unless ref($literal) eq 'SCALAR';

    return bless($literal, $class);
}

# {{{ Role::Source interface

sub cachable { 0 }

sub source_db_moniker { ${$_[0]} }
sub source_orm_name   { 'LITERAL' }

sub fields_list_all { ['*'] }
sub fields_to_fetch { ['*'] }

sub field_affinity { 'string' }

sub field_type     { }
sub fields_to_omit { }
sub has_field      { }
sub primary_key    { }
sub row_class      { }

# }}} Role::Source interface

1;

__END__

=head1 SOURCE

The source code repository for DBIx::QuickORM can be found at
L<https://github.com/exodist/DBIx-QuickORM>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
