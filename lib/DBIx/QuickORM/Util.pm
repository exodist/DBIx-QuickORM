package DBIx::QuickORM::Util;
use strict;
use warnings;

use Module::Pluggable sub_name => '_find_mods';
BEGIN {
    *_find_paths = \&search_path;
    no strict 'refs';
    delete ${\%{__PACKAGE__ . "\::"}}{search_path};
}

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    load_class
    find_modules
};

=head1 EXPORTS

=over 4

=item $class_or_false = load_class($class) or die "Error: $@"

Loads the class.

On success it returns the class name.

On Failure it returns false and the $@ variable is set to the error.

=cut

sub load_class {
    my ($class, $prefix) = @_;

    if ($prefix) {
        $class = "${prefix}::${class}" unless $class =~ s/^\+// or $class =~ m/^$prefix\b/;
    }

    my $file = $class;
    $file =~ s{::}{/}g;
    $file .= ".pm";

    eval { require $file; $class };
}

sub find_modules {
    my (@prefixes) = @_;

    __PACKAGE__->_find_paths(new => @prefixes);
    return __PACKAGE__->_find_mods();
}


1;

__END__

=back
