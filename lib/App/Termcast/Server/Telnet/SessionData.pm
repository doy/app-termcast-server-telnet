#!/usr/bin/env perl
package App::Termcast::Server::Telnet::SessionData;
use Moose::Role;

=head1 NAME

App::Termcast::Server::Telnet::Session -

=head1 SYNOPSIS


=head1 DESCRIPTION


=cut

has viewing => (
    is  => 'rw',
    isa => 'Maybe[Str]',
    clearer => '_clear_viewing',
);

has page => (
    is      => 'rw',
    isa     => 'Int',
    default => 0,
);

has stream_handle => (
    is  => 'rw',
    isa => 'AnyEvent::Handle',
    clearer => '_clear_stream_handle',
);

no Moose::Role;

1;

__END__

=head1 METHODS


=head1 AUTHOR

Jason May C<< <jason.a.may@gmail.com> >>

=head1 LICENSE

This program is free software; you can redistribute it and::or modify it under the same terms as Perl itself.

