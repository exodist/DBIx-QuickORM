package DBIx::QuickORM::Schema::Autofill;
use strict;
use warnings;

use List::Util qw/first/;

use DBIx::QuickORM::Util::HashBase qw{
    <types
    <affinities
    <hooks
};

sub hook {
    my $self = shift;
    my ($hook) = @_;

}

sub process_column {
    my $self = shift;
    my ($col) = @_;

    my $type = $col->{type};
    my $tref = ref($type);
    return unless $tref && $tref eq 'SCALAR';

    my $new_type;
    $new_type = $self->{+TYPES}->{$$type} // $self->{+TYPES}->{uc($$type)} // $self->{+TYPES}->{lc($$type)};

    unless ($new_type) {
        if (my $aff = $col->{affinity}) {
            if (my $list = $self->{+AFFINITIES}->{$aff}) {
                for my $cb (@$list) {
                    $new_type = $cb->(%$col) and last;
                }
            }
        }
    }

    return unless $new_type;

    $col->{type} = $new_type;
    $col->{affinity} = $new_type->qorm_affinity(sql_type => $$type);
}

1;

__END__

        $params{autofill}->hook(pre_table => {table => $table, class => \$class});
        $params{autofill}->hook(columns => {columns => $table->{columns}, table => $table});
        $params{autofill}->hook(indexes => {indexes => $table->{indexes}, table => $table});
        $params{autofill}->hook(post_table => {table => $table, class => \$class});
        $params{autofill}->hook(table => {table => $tables{$tname}});
    $params{autofill}->hook(links       => {links       => \@links, table_name => $table});
    $params{autofill}->hook(primary_key => {primary_key => $pk, table_name => $table});
    $params{autofill}->hook(unique_keys => {unique_keys => \%unique, table_name => $table});
        $params{autofill}->hook(pre_column => {column => $col, table_name => $table, column_info => $res});
        $params{autofill}->hook(post_column => {column => $col, table_name => $table, column_info => $res});
        $params{autofill}->hook(column => {column => $columns{$col->{name}}, table_name => $table, column_info => $res});
        $params{autofill}->hook(index => {index => $out[-1], table_name => $table, definition => $def});
