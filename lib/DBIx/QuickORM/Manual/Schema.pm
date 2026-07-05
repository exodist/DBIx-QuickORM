package DBIx::QuickORM::Manual::Schema;
use strict;
use warnings;

our $VERSION = '0.000028';

1;

__END__

=head1 NAME

DBIx::QuickORM::Manual::Schema - Build your schema with the DSL.

=head1 DESCRIPTION

This guide walks through using the L<DBIx::QuickORM> DSL to compose schemas,
tables, columns, and whole ORMs - from a single self-contained ORM package up
to more advanced compositions where servers, databases, and schemas are defined
separately and combined into multiple ORMs.

This page focuses on B<how to put the pieces together>. For the
function-by-function reference (every DSL builder, what it accepts, and what it
returns) see L<DBIx::QuickORM>.

If you have not yet, start with L<DBIx::QuickORM::Manual::QuickStart> for a
fast introduction, and L<DBIx::QuickORM::Manual::Concepts> for the key concepts
(dialects, schema, affinity, ...) that the rest of this guide assumes.

=head1 YOUR ORM PACKAGE

The simplest layout is a single package that uses L<DBIx::QuickORM>, defines an
C<orm> containing a C<db> (the connection) and a C<schema> (the tables). When
your app code does C<use My::ORM>, it gets a C<qorm()> accessor.
C<qorm('name')> returns a ready-to-query L<DBIx::QuickORM::Connection>, while
C<< qorm(orm => 'name') >> returns the underlying L<DBIx::QuickORM::ORM>
object. The accessor name can be changed at import time; see
L<DBIx::QuickORM::Manual::Recipes>.

There are two ways to populate the schema: define it by hand (manual schema) or
let DBIx::QuickORM introspect the live database and fill it in for you
(automagic schema).

=head2 MANUAL SCHEMA

Define every table and column yourself. This gives you complete control and
does not require the database to exist when the schema is defined.

    package My::ORM;
    use DBIx::QuickORM;

    # Define your ORM
    orm my_orm => sub {
        # Define your object
        db my_db => sub {
            dialect 'PostgreSQL'; # Or MySQL, MariaDB, SQLite
            host 'mydb.mydomain.com';
            port 1234;

            # Best not to hardcode these, read them from a secure place and pass them in here.
            user $USER;
            pass $PASS;
        };

        # Define your schema
        schema myschema => sub {
            table my_table => sub {
                column id => sub {
                    identity;
                    primary_key;
                    not_null;
                };

                column name => sub {
                    type \'VARCHAR(128)';    # Exact SQL for the type
                    affinity 'string';       # required if other information does not make it obvious to DBIx::QuickORM
                    unique;
                    not_null;
                };

                column added => sub {
                    type 'DateTime';         # Short for DBIx::QuickORM::Type::DateTime
                    not_null;

                    # Exact SQL to use if DBIx::QuickORM generates the table SQL
                    default \'NOW()';

                    # Perl code to generate a default value when rows are created by DBIx::QuickORM
                    default sub { ... };
                };
            };
        };
    };

=head2 AUTOMAGIC SCHEMA

Let DBIx::QuickORM introspect the live database and fill the schema in for you.
The C<autofill> builder reads columns, indexes, primary keys, and so on from the
connected database; the rest of the builders inside it tune that process
(automatic type handling, skipping tables, generating row classes, and custom
naming).

    package My::ORM;
    use DBIx::QuickORM;

    # Define your ORM
    orm my_orm => sub {
        # Define your object
        db my_db => sub {
            dialect 'PostgreSQL'; # Or MySQL, MariaDB, SQLite
            host 'mydb.mydomain.com';
            port 1234;

            # Best not to hardcode these, read them from a secure place and pass them in here.
            user $USER;
            pass $PASS;
        };

        # Introspect the connected database and fill in the schema. The
        # autofill builder goes directly inside orm(), not inside schema() -
        # it produces the schema for you. The class name is optional; the one
        # shown here is the default.
        autofill 'DBIx::QuickORM::Schema::Autofill' => sub {
            autotype 'UUID';    # Automatically handle UUID fields
            autotype 'JSON';    # Automatically handle JSON fields

            # Do not autofill these tables. autoskip takes a single name per
            # call, so call it once per table you want to skip.
            autoskip table => 'foo';
            autoskip table => 'bar';
            autoskip table => 'baz';

            # To skip a single column instead of a whole table, name both the
            # table and the column:
            autoskip column => 'some_table', 'some_column';

            # autorow will automatically create row classes for you with
            # accessors for links and fields. With a base of 'My::Row', a
            # table named "table" becomes My::Row::Table; if My/Row/Table.pm
            # exists it is loaded and anything missing is autofilled.
            autorow 'My::Row';

            # autorow can instead take a subref that accepts a table name and
            # returns the class name to use. Use this form OR the plain form
            # above, not both - a second autorow call croaks. The subref below
            # is the default name generator, used if none is provided:
            #
            #   autorow 'My::Row' => sub {
            #       my $name = shift;
            #       my @parts = split /_/, $name;
            #       return join '' => map { ucfirst(lc($_)) } @parts;
            #   };

            # You can provide custom names for tables. It will still refer to
            # the correct name in queries, but will provide an alternate name
            # for the orm to use in perl code.
            autoname table => sub {
                my %params = @_;
                my $table_hash = $params{table}; # unblessed ref that will become a table
                my $name = $params{name}; # The name of the table
                ...
                return $new_name;
            };

            # You can provide custom names for link (foreign key) accessors when using autorow
            autoname link_accessor => sub {
                my %params = @_;
                my $link = $params{link};

                return "obtain_" . $link->other_table if $params{link}->unique;
                return "select_" . $link->other_table . "s";
            };

            # You can provide custom names for field accessors when using autorow
            autoname field_accessor => sub {
                my %params = @_;
                return "get_$params{name}";
            };
        };
    };

=head1 DEFINE TABLES IN THEIR OWN PACKAGES/FILES

If you have many tables, or want each to have a custom row class (custom
methods for items returned by tables), then you probably want to define tables
in their own files.

When you follow this example you create the table C<My::ORM::Table::Foo>. The
package will automatically subclass L<DBIx::QuickORM::Row> unless you use
C<row_class()> to set an alternative base.

Any methods added in the file will be callable on the rows returned when
querying this table.

First create F<My/ORM/Table/Foo.pm>:

    package My::ORM::Table::Foo;
    use DBIx::QuickORM type => 'table';

    # Calling this will define the table. It will also:
    #  * Remove all functions imported from DBIx::QuickORM
    #  * Set the base class to DBIx::QuickORM::Row, or to whatever class you specify with 'row_class'.
    table foo => sub {
        column a => sub { ... };
        column b => sub { ... };
        column c => sub { ... };

        ....

        # This is the default, but you can change it to set an alternate base class.
        row_class 'DBIx::QuickORM::Row';
    };

    sub custom_row_method {
        my $self = shift;
        ...
    }

Then in your ORM package:

    package My::ORM;

    schema my_schema => sub {
        table 'My::ORM::Table::Foo'; # Bring in the table
    };

Or if you have many tables and want to load all the tables under C<My::ORM::Table::> at once:

    schema my_schema => sub {
        tables 'My::ORM::Table';
    };

=head1 ADVANCED COMPOSING

You can define databases and schemas on their own and create multiple ORMs that
combine them. You can also define a C<server> that has multiple databases.

    package My::ORM;
    use DBIx::QuickORM;

    server pg => sub {
        dialect 'PostgreSQL';
        host 'pg.myapp.com';
        user $USER;
        pass $PASS;

        db 'myapp';       # Points at the 'myapp' database on this db server
        db 'otherapp';    # Points at the 'otherapp' database on this db server
    };

    schema myapp => sub { ... };
    schema otherapp => sub { ... };

    orm myapp => sub {
        db 'pg.myapp';
        schema 'myapp';
    };

    orm otherapp => sub {
        db 'pg.otherapp';
        schema 'otherapp';
    };

Then to use them (each C<qorm('name')> call returns a ready-to-query
L<DBIx::QuickORM::Connection>; use C<< qorm(orm => 'name') >> if you want the
L<DBIx::QuickORM::ORM> object itself):

    use My::ORM;

    my $myapp    = qorm('myapp');
    my $otherapp = qorm('otherapp');

Also note that C<< alt(variant => sub { ... }) >> can be used in any of the
above builders to create MySQL/PostgreSQL/etc. variants on the databases and
schemas. Then access them like:

    my $myapp_pgsql = qorm('myapp:pgsql');
    my $myapp_mysql = qorm('myapp:mysql');

The MySQL/PostgreSQL variant recipe is covered in full in
L<DBIx::QuickORM::Manual::Recipes>.

=head1 MORE RECIPES

This guide does not cover every composition trick. For defining the database
connection separately and attaching it later, renaming the exported C<qorm()>
accessor, supporting nearly-identical MySQL and PostgreSQL databases from one
codebase, and other focused tasks, see L<DBIx::QuickORM::Manual::Recipes>.

=head1 VOLATILE COLUMNS

A B<volatile> column is one whose stored value the database may set or change
during a write, so the value you sent cannot be trusted as the in-memory truth.
Typical sources are generated/computed columns, identity / auto-increment /
sequence-backed columns, server-side C<DEFAULT>s, C<ON UPDATE> clauses, and
triggers.

Mark a column volatile with the C<volatile> marker:

    column updated_at => sub {
        affinity 'string';
        volatile;
    };

QuickORM also B<auto-detects> the volatile columns it can recognize reliably
during introspection: generated columns and identity / sequence-backed columns.
It does B<not> auto-detect server-side defaults or C<ON UPDATE> columns -- a
default only applies when you omit the column, the databases report defaults
inconsistently, and an omitted column already lazy-fetches on access -- so mark
those yourself when you want the volatile behavior. Trigger effects cannot be
determined in general (a trigger runs arbitrary code); QuickORM makes a
best-effort attempt to flag the columns a simple trigger is seen to set, and
otherwise warns once per table that a trigger was found whose column effects it
could not resolve.

=head2 WHAT VOLATILE DOES ON A WRITE

=over 4

=item A volatile column that is B<not> omitted

is re-fetched eagerly as part of the write (added to C<RETURNING>, or via a
post-write refresh on dialects without C<RETURNING>), so the in-memory value is
the real stored value rather than the value you sent.

=item A column that is B<both> volatile and omitted

is neither trusted nor eagerly fetched: after the write it is cleared from the
in-memory row, and the next access lazily fetches the real value on demand.
Being on the omit list signals a deliberate reason not to pull it eagerly (a
huge value, an expensive inflation), so QuickORM drops the untrusted written
value and waits until you actually ask for it.

=back

C<RETURNING> reflects generated/default and C<BEFORE>-trigger values, but not
C<AFTER>-trigger effects (the row is captured before C<AFTER> triggers run). To
keep behavior the same on every database, QuickORM detects a table's triggers
during introspection and, for a table that has any, reads the written row back
with a follow-up fetch instead of trusting C<RETURNING> -- just as it does on
databases without C<RETURNING>. So a trigger-changed volatile column reads back
correctly whether you are on SQLite, PostgreSQL, MySQL, or MariaDB. (This applies
to introspected schemas; if you declare a schema by hand for a table with
triggers, mark such a column B<omit + volatile>, which works the same on every
dialect.)

=head2 ASSERTING A TABLE IS VOLATILE-FREE

If you know a table has no volatile columns -- in particular that its triggers
do not make any column volatile -- you can say so, which also silences the
per-table trigger warning. In the DSL:

    table events => sub {
        no_volatile;
        ...
    };

Or from the C<quick> interface, for one or more tables (or C<< => 1 >> for every
table):

    my $con = DBIx::QuickORM->quick(
        credentials => { dsn => $dsn },
        no_volatile => [ 'events', 'audit_log' ],
    );

A volatile-free assertion skips both the best-effort trigger flagging and the
warning for that table; it does not clear the generated/identity auto-detection,
which is based on declared facts rather than trigger guesses.

To see which tables are safe (every column non-volatile) at a glance:

    my @safe = $con->volatile_free_tables;   # sorted table names

C<< $schema->volatile_free_tables >> and C<< $table->has_volatile_columns >> are
also available.

Note the term overlaps PostgreSQL I<function> volatility
(C<VOLATILE>/C<STABLE>/C<IMMUTABLE>); that is about functions, not columns.

=head1 SEE ALSO

=over 4

=item L<DBIx::QuickORM>

The DSL reference: every builder function documented one by one.

=item L<DBIx::QuickORM::Manual::QuickStart>

Connect, query, and get going in a few lines.

=item L<DBIx::QuickORM::Manual::Concepts>

Dialects, schema, affinity, and the other key concepts.

=item L<DBIx::QuickORM::Manual::Relations>

Define links (foreign keys) and follow them between rows.

=item L<DBIx::QuickORM::Manual::Recipes>

Focused recipes for specific composition tasks.

=item L<DBIx::QuickORM::Manual>

The documentation hub linking every tutorial, guide, and reference.

=back

=head1 SOURCE

The source code repository for DBIx-QuickORM can be found at
L<https://github.com/exodist/DBIx-QuickORM/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
