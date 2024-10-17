package DBIx::QuickORM;
use strict;
use warnings;

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

DBIx::QuickORM - Actively maintained, quick to start, powerful ORM tool.

=head1 DESCRIPTION

An actively maintained ORM tool that is qucik and easy to start with, but
powerful and expandable for long term and larger projects. An alternative to
L<DBIx::Class>, but not a drop-in replacement.

=head1 SYNOPSIS

FIXME!

=head1 PRIMARY INTERFACE

See L<DBIx::QuickORM::V0> for the primary interface documentation,

=head1 RECIPES

See L<DBIx::QuickORM::Recipes> for documentation on specific scenarios that may
fit your need.

=head1 MOTIVATION

The most widely accepted ORM for perl, L<DBIx::Class> is for all intents and
purposes, dead. There is only 1 maintainer, and that person has stated that the
project is feature complete. The project will recieve no updates apart from
critical bugs. The distribution has been marked such that it absolutely can
never be transferred to anyone else.

There are 4 ways forward:

=over 4

=item Use DBIx::Class it as it is.

Many people continue to do this.

=item Monkeypatch DBIx::Class

I know a handful of people who are working on a way to do this that is not
terrible and will effectively keep L<DBIx::Class> on life support.

=item Fork DBIx::Class

I was initially going to take this route. But after a couple hours in the
codebase I realized I dislike the internals of DBIx::Class almost as much as I
dislike using it as an app developer.

=item Write an alternative

I decided to take this route. I have never liked DBIx::Class, I find it
difficult to approach, and it is complicated to start a project with it. The
interface is unintuitive, and the internals are very opaque.

My goal is to start with the interface, make it approachable, easy to start,
etc. I also want the interface to be intuitive to use. I also want
expandability. I also want to make sure I adopt the good ideas and capabilities
from DBIx::Class. Only a fol would say DBIx::Class has nothing of value.

=back

=head1 GOALS

=over 4

=item Quick to start

It should be very simple to start a project. The ORM should stay out of your
way until you want to make it do something for you.

=item Intuitive

Names, interfaces, etc should make sense and be obvious.

=item Declarative Syntax

DBIx::Class had an abysmal interface calling C<< __PACKAGE__->blah >> all over
the place. You also had to create a lot of classes to line up with your tables.
With DBIx::QuickORM You can declare your table structure anywhere, and they do
not need associated clases per table. That said it is also trivial to define a
class for any given table and add your own custom methods.

=item Make as few assumptions as possible

DBIx::Class and other orms tend to make some assumptions such as:

=over 4

=item Only 1 database connection at a time

=item Only 1 database server at a time

=item Only 1 instance of the schema at a time

=back

=item Expandability

Should be easy to extend and expand the functionality.

=item Inflation/Deflation should be trivial, and "just work" in fetched objects, inserts, selects, etc.

The way DBIx::Class handled inflation and deflation left a lot of places where
you had to ask "Can I pass an inflated form here? or do I need to deflate it
first?". In DBIx::QuickORM this should never be a question, there will be few
if any places where inflation and deflation is not automatic.

In this project I am calling it "conflation", yes it is a terrible pun, and thr
word "conflate" has no real connection to "inflate" or "deflate" as far as I
know... but I like it as a blanket term to encapsulate both "inflate" and
"deflate". Most inflation and deflation occurs with conflator classes.

=item Easy to generate the perl side orm from the database itself if the schema is already in the database

If you tell the orm how to connect to the database, you can ask it to just
generate the table based data. If it does not generate them exactly how you
want (object or relationship names are not ideal) then you have hooks to use to
tell it how to name them.

This is a core functionality of DBIx::QuickORM, not a secondary project or
side-thought.

=item Easy to generate the sql to initialize the database if you have the perl code already defined

If you write perl code that defines your database structure, table layout,
relations, etc. Then you can ask the orm to give you an SQL dump in whatever
supported SQL variant you want. You can then take this SQL and load it into
your database. You can even tell the DB to load the schema into a database once
you are connected.

This is a core functionality of DBIx::QuickORM, not a secondary project or
side-thought.

=item Built-in support for PostgreSQL, MariaDB, SQLite and MySQL.

These are my big 4 for initial support. Additional DB's can be supported, and
you can write your own database-orm inferface modules if you want something
else supported.

With a properly written DB class the ORM can even handle translating concepts
from one database to another. For example MySQL is the only one of the big 4
that does not have a builtin UUID type. The ORM will let you use BINARY(16),
VARCHAR(36) on MySQL, or even other types to store the UUID, and with the UUID
conflator (inflation/deflation) you can make it completely transparent to the
app. The same schema definition (on perls side) will work just as well on any
of the 4 database servers.

=item Async capabilities

Async is supported in multiple ways:

=over 4

=item Using native Async functionality on the current connection

Send off a query, then do somthing else until it is ready. Even works inside
transactions! The caveat is you cannot use the db connection for anything else
while you wait.

This feature is accessed as C<< $select->async >>. See
L<DBIx::QuickORM::Select>.

=item Using native Async functionality with multiple connections

You can make Async requests where each one operates on a different connection
so they can operate concurrently. The caching is managed for you as well. The
main caveat here is that you cannot use it with transactions and multiple
connections cannot share a transaction.

Exceptions will be thrown if you start one of these during a transaction.

Exceptions will be thrown if you start a transaction while one of these is
running.

This feature is accessed as C<< $select->aside >>. See
L<DBIx::QuickORM::Select>.

=item Using fork + Different connections

The queries each run on their own connection and in their own processes, then
the data will be send to the primary process. This is useful for databases that
do not support async queries natively, such as SQLite.

Exceptions will be thrown if you start one of these during a transaction.

Exceptions will be thrown if you start a transaction while one of these is
running.

This feature is accessed as C<< $select->forked >>. See
L<DBIx::QuickORM::Select>.

=back

=item Transaction Management

DBIx::QuickORM provides easy ways to start and mnage transactions, as well as
using savepoints for an effective "nested transactions" functionality.

Caveat: If combined with external transaction management, things can go bad, or
be confusing.

=item Cache Management

DBIx::QuickORM provides a caching layer that associates cache with a specific
connection. You can clear all the cache for the connection, or all the cache
for a specific table in the connection. You can also disable cache or ignore
cache at any time. There is also sane handling of caching with transactions.

=back

=head1 SCOPE

The primary scope of this project is to write a good ORM for perl. It is very
easy to add scope, and try to focus on things outside this scope. I am not
opposed to such things being written around the ORM fucntionality, afterall the
project has a lot of useful code, and knowledge of the database. But th primary
focus must always be the ORM functionality, and it must not suffer in favor of
functionality beyond that scope.

=head1 MAINTENANCE COMMITMENT

I want to be sure that what happened to L<DBIx::Class> cannot happen to this
project. I will maintain this as long as I am able. When I am not capable I
will let others pick up where I left off.

I am stating here, in the docs, for all to see for all time:

B<If I become unable to maintain this project, I approve of others being given
cpan and github permissions to develop and release this distribution.>

Peferably maint will be handed off to someone who has been a contributor, or to
a group of contributors, If none can be found, or none are willing, I trust the
cpan toolchain group to takeover.

=head1 SOURCE

The source code repository for DBIx-QuickORM can be found at
L<http://github.com/exodist/DBIx-QuickORM/>.

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

See L<http://dev.perl.org/licenses/>

=cut

