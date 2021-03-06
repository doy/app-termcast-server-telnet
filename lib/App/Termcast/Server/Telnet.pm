#!perl
package App::Termcast::Server::Telnet;
use Moose;
use AnyEvent::Socket;
use AnyEvent::Handle;
use App::Termcast::Handle;
use App::Termcast::Session;
use Time::Duration;
use AE;
use YAML;
use Data::UUID::LibUUID;
use Scalar::Util qw(weaken);
use namespace::autoclean;

use constant CLEAR => "\e[2J\e[H";

=head1 NAME

App::Termast::Server::Telnet - telnet interface for the termcast server

=head1 SYNOPSIS


=head1 DESCRIPTION


=cut

has telnet_port => (
    is  => 'ro',
    isa => 'Int',
    default => 23,
);

has client_handle => (
    is  => 'rw',
    isa => 'AnyEvent::Handle',
);

has stream_data => (
    is      => 'rw',
    isa     => 'HashRef',
    traits  => ['Hash'],
    default => sub { +{} },
    handles => {
        set_stream         => 'set',
        stream_ids         => 'keys',
        get_stream         => 'get',
        delete_stream      => 'delete',
        clear_stream_data  => 'clear',
    },
);

has handles => (
    is      => 'ro',
    isa     => 'HashRef',
    traits  => ['Hash'],
    default => sub { +{} },
    handles => {
        set_handle    => 'set',
        delete_handle => 'delete',
        handle_ids    => 'keys',
        handle_list   => 'values',
    },
);

sub BUILD {
    my $self = shift;

    my $host        = 'localhost';
    my $server_port = 9092;
    my $telnet_port = $self->telnet_port;

    tcp_connect $host, $server_port, sub { $self->client_connect(@_) };
    tcp_server  undef, $telnet_port, sub { $self->telnet_accept(@_) };
}

sub client_connect {
    my $self = shift;
    my ($fh) = @_
        or die "localhost connect failed: $!";

    my $h = AnyEvent::Handle->new(
        fh => $fh,
        on_read => sub {
            my ($h, $host, $port) = @_;
            $h->push_read(
                json => sub {
                    my ($h, $data) = @_;
                    if ($data->{notice}) {
                        $self->handle_server_notice($data);
                    }
                    elsif ($data->{response}) {
                        $self->handle_server_response($data);
                    }
                }
            );
        },
        on_error => sub {
            my ($h, $fatal, $error) = @_;
            warn $error;
            exit 1 if $fatal;
        },
    );

    $h->push_write(
        json => +{
            request => 'sessions',
        }
    );

    $self->client_handle($h);
}

sub telnet_accept {
    my $self = shift;
    my ($fh, $host, $port) = @_;
    my $h = App::Termcast::Handle->new(
        fh => $fh,
        on_read => sub {
            my $h = shift;
            $h->push_read(
                chunk => 1, sub {
                    my ($h, $buf) = @_;
                    if (ord $buf == 255) {
                        $h->push_read(
                            chunk => 2,
                            sub { $self->handle_telnet_codes(@_) },
                        );
                    }
                    else {
                        $self->dispatch_telnet_input($h, $buf);
                    }
                }
            );
        },
        on_error => sub {
            my ($h, $fatal, $error) = @_;

            if ($fatal) {
                $self->delete_handle($h->handle_id);
            }
            else {
                warn $error;
            }
        },
        handle_id => new_uuid_string()
    );

    $h->push_write(
        join(
            '',
            (
                map { chr }
                (
                    255, 251,  1, # iac will echo
                    255, 251,  3, # iac will suppres go_ahead
                    255, 254, 34, # iac wont linemode
                )
            )
        )
    );

    my $session = App::Termcast::Session->with_traits(
        'App::Termcast::Server::Telnet::SessionData'
    )->new();
    $h->session($session);

    $self->set_handle($h->handle_id => $h);
    $self->send_connection_list($h);
}

sub dispatch_telnet_input {
    my $self = shift;
    my ($handle, $buf) = @_;

    if ($handle->session->viewing) {
        $self->dispatch_stream_inputs(@_);
    }
    else {
        $self->dispatch_menu_inputs(@_);
    }
}

sub dispatch_stream_inputs {
    my $self = shift;
    my ($handle, $buf) = @_;

    if ($buf eq 'q') {
        $handle->session->_clear_viewing;
        $handle->session->_clear_stream_handle;
        $self->send_connection_list($handle);
    }
}

sub dispatch_menu_inputs {
    my $self = shift;
    my ($handle, $buf) = @_;

    if ($buf eq 'q') {
        $handle->push_write(CLEAR);
        $handle->destroy;
        $self->delete_handle($handle->handle_id);
        return;
    }

    my $session = $self->get_session_from_key($buf);

    if ($session) {
        $handle->session->viewing($session);
        $handle->push_write(CLEAR);

        weaken(my $weakself = $self);
        my $file = $self->get_stream($session)->{socket};
        tcp_connect 'unix/', $file, sub {
            my $fh = shift or die "$file: $!";
            my $h = AnyEvent::Handle->new(
                fh => $fh,
                on_read => sub {
                    my $h = shift;
                    $handle->push_write($h->rbuf);
                    $h->{rbuf} = '';
                },
                on_error => sub {
                    my ($h, $fatal, $error) = @_;

                    if ($fatal) {
                        $handle->session->_clear_viewing;
                        $handle->session->_clear_stream_handle;
                        $weakself->send_connection_list($handle);
                    }
                    else {
                        warn $error;
                    }
                }
            );
            $handle->session->stream_handle($h);
        };
    }
    else {
        $self->send_connection_list($handle);
    }
}

sub handle_telnet_codes {
    my $self             = shift;
    my $handle           = shift;
    my ($verb, $feature) = split '', shift;
    # I don't know enough about telnet to do stuff properly here
}

sub handle_server_notice {
    my $self = shift;
    my $data = shift;

    if ($data->{notice} eq 'connect') {
        $self->set_stream(
            $data->{connection}{session_id} => $data->{connection},
        );
    }
    elsif ($data->{notice} eq 'disconnect') {
        $self->delete_stream($data->{session_id});
    }
    $self->send_connection_list($_) for $self->handle_list;
}

sub handle_server_response {
    my $self = shift;
    my $data = shift;

    if ($data->{response} eq 'sessions') {
        my @sessions = @{ $data->{sessions} };
        if (@sessions) {
            $self->clear_stream_data;
            for (@sessions) {
                $self->set_stream($_->{session_id} => $_);
            }
        }
    }
}

sub send_connection_list {
    my $self   = shift;
    my $handle = shift;
    my $output;

    my $letter = 'a';
    my @stream_data = $self->get_stream(sort $self->stream_ids);
    foreach my $stream (@stream_data) {
        $output .= sprintf "%s) %s - Active %s\r\n",
                   $letter,
                   $stream->{user},
                   ago(time() - $stream->{last_active});
        $letter++;
    }

    $output = "No active termcast sessions!\r\n" if !$output;

    $handle->push_write(CLEAR . "Users connected:\r\n\r\n$output");
}

sub get_session_from_key {
    my $self = shift;
    my $key = shift;
    my %id_map;

    my @stream_ids = $self->stream_ids;
    my @keys       = ('a' .. 'p', 'r' .. 'z', 'A' .. 'Z');
    @id_map{ map { $keys[$_] } 0 .. @stream_ids } = sort @stream_ids;

    return $id_map{$key};
}

sub run { AE::cv->recv }


__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 METHODS


=head1 AUTHOR

Jason May C<< <jason.a.may@gmail.com> >>

=head1 LICENSE

This program is free software; you can redistribute it and::or modify it under the same terms as Perl itself.

