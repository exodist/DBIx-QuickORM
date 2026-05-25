package DBIx::QuickORM::Manual::QuickStart;
use strict;
use warnings;

our $VERSION = '0.000020';

1;

__END__

=head1 NAME

DBIx::QuickORM::Manual::QuickStart - A friendly first tour of
L<DBIx::QuickORM>.

=head1 DESCRIPTION

This is the first page to read if you are new to L<DBIx::QuickORM>. It walks
you from an empty script to fetching rows, inserting rows, following relations,
and running a transaction - all using the C<quick()> interface, which needs no
schema definition at all.

The idea: point C<quick()> at a database, and DBIx::QuickORM introspects all
the table and column metadata directly from the live database. You get back a
ready-to-use connection and start treating rows as objects immediately.

When you want more control (defining your own schema, custom row classes,
joins, and so on) follow the links at the end of this page. For the bigger
picture and the full set of guides, see L<DBIx::QuickORM::Manual>.

=head1 CONNECT

Use the C<quick()> class method. Provide exactly one of C<credentials> or
C<connect>. The SQL dialect is detected automatically from the DSN (or the
C<dbd>), so you usually do not need to think about it.

    use DBIx::QuickORM;

    my $con = DBIx::QuickORM->quick(
        credentials => {
            dsn   => $dsn,        # e.g. "dbi:Pg:dbname=myapp;host=..."
            user  => $user,
            pass  => $pass,
        },

        # Type classes (under DBIx::QuickORM::Type unless fully qualified)
        # used to auto inflate/deflate matching columns.
        auto_types => ['JSON', 'UUID'],
    );

If you would rather hand DBIx::QuickORM a callback that produces a fresh DBI
handle, use C<connect> instead of C<credentials>:

    my $con = DBIx::QuickORM->quick(
        connect => sub { DBI->connect($dsn, $user, $pass) },
    );

C<$con> is a L<DBIx::QuickORM::Connection>. It self-heals: it can reconnect in
place and retry work, preserving its row cache. That is the only object you
need to keep around.

=head1 FETCH ROWS

A B<handle> is the interface for talking to a table. Get one with
C<< $con->handle('table_name') >>, then ask it for rows.

    # Every row in the 'users' table, as Row objects:
    my @users = $con->handle('users')->all;

    # Narrow it down with a where clause, then fetch:
    my @smiths = $con->handle('users')->where({surname => 'smith'})->all;

    # Exactly one matching row (dies if more than one matches):
    my $user = $con->handle('users')->where({email => $email})->one;

When you want a row by primary key, C<by_id> is the shortcut:

    my $user = $con->by_id(users => 5);

For convenience the connection proxies the common handle methods directly, so
the simple cases need no explicit handle:

    my @users = $con->all('users');
    my $user  = $con->one(users => {email => $email});
    my $count = $con->count('users');

Read a column off a row with C<field>:

    print $user->field('name'), "\n";

If you connected with an C<autorow> base class (see L<DBIx::QuickORM> and
L<DBIx::QuickORM::Manual::Schema>), each column also gets a named accessor, so
you can write C<< $user->name >> instead of C<< $user->field('name') >>.

For everything handles can do - ordering, limiting, iterators, and more - see
L<DBIx::QuickORM::Manual::Querying>.

=head1 INSERT ROWS

Insert with a hashref of column values. You get back the new row object,
populated with anything the database filled in (auto-increment ids, defaults,
and so on).

    my $bob = $con->insert(users => {name => 'bob', email => 'bob@example.com'});

    print "new id: ", $bob->field('id'), "\n";

You can also go through a handle, which is handy once you have a handle around:

    my $bob = $con->handle('users')->insert({name => 'bob'});

To change an existing row, update it and save:

    $bob->update({name => 'robert'});

See L<DBIx::QuickORM::Manual::Querying> for create, update, and delete in
depth.

=head1 FOLLOW RELATIONS

If the database has foreign keys, DBIx::QuickORM picks them up during
introspection, and you can walk from one row to its related rows by the link
name.

Use C<obtain> for a link that points at a single row, and C<follow> for a link
that points at many. C<follow> returns a handle, so you can refine it before
fetching:

    # A link to one row (e.g. the author of a post):
    my $author = $post->obtain('author');

    # A link to many rows (e.g. all posts by a user):
    my @posts = $user->follow('posts')->all;

    # follow gives you a handle, so you can keep narrowing:
    my @recent = $user->follow('posts')->where({year => 2026})->all;

With an C<autorow> base class these also become named accessors on the row,
matching the link name, so you can write C<< $post->author >> or
C<< $user->posts->all >> directly.

For defining links yourself, naming them, and joining across them, see
L<DBIx::QuickORM::Manual::Relations>.

=head1 RUN A TRANSACTION

Wrap related work in C<txn>. Hand it a callback: if the callback returns
normally the transaction commits; if it throws, the transaction rolls back.

    $con->txn(sub {
        my $txn = shift;

        my $user = $con->insert(users => {name => 'carol'});
        $con->insert(posts => {user_id => $user->field('id'), title => 'Hello'});

        # Returning normally commits. You can also commit or roll back
        # explicitly, which exits the callback immediately:
        #   $txn->commit;
        #   $txn->rollback;
    });

Transactions nest using savepoints, and DBIx::QuickORM can retry a transaction
automatically when the database reports a transient conflict. For all of that,
see L<DBIx::QuickORM::Manual::Transactions>.

=head1 WHERE TO NEXT

You now know enough to be productive. From here:

=over 4

=item L<DBIx::QuickORM::Manual::Concepts>

The key ideas (dialects, schema, affinity) that make everything else easier.

=item L<DBIx::QuickORM::Manual::Schema>

Define your own schema, tables, columns, and custom row classes instead of
introspecting everything.

=item L<DBIx::QuickORM::Manual::Querying>

The full handle interface: where clauses, ordering, limiting, iterators,
create, update, and delete.

=item L<DBIx::QuickORM::Manual::Relations>

Define links (foreign keys), follow them, and join across them.

=item L<DBIx::QuickORM::Manual::Transactions>

Nested transactions, savepoints, callbacks, and automatic retry.

=item L<DBIx::QuickORM::Manual>

The documentation hub, linking every tutorial, guide, and reference.

=back

=head1 SOURCE

The source code repository for DBIx-QuickORM can be found at
L<https://github.com/exodist/DBIx-QuickORM/>.

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
