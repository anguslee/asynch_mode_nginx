#!/usr/bin/perl

# Copyright (C) Intel, Inc.
# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Tests for HTTP/2 protocol with ssl.

###############################################################################

use warnings;
use strict;

use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Test::Nginx::HTTP2;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

eval { require IO::Socket::SSL; };
plan(skip_all => 'IO::Socket::SSL not installed') if $@;

my $t = Test::Nginx->new()->has(qw/http http_ssl http_v2/)
    ->has_daemon('openssl');

$t->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080 http2 ssl %%SSL_ASYNCH%%;
        server_name  localhost;

        ssl_certificate_key localhost.key;
        ssl_certificate localhost.crt;

        lingering_close off;

        location / { }
    }
}

EOF

$t->write_file('openssl.conf', <<EOF);
[ req ]
default_bits = 2048
encrypt_key = no
distinguished_name = req_distinguished_name
[ req_distinguished_name ]
EOF

my $d = $t->testdir();

foreach my $name ('localhost') {
    system('openssl req -x509 -new '
        . "-config $d/openssl.conf -subj /CN=$name/ "
        . "-out $d/$name.crt -keyout $d/$name.key "
        . ">>$d/openssl.out 2>&1") == 0
        or die "Can't create certificate for $name: $!\n";
}

$t->write_file('tbig.html',
    join('', map { sprintf "XX%06dXX", $_ } (1 .. 500000)));

open OLDERR, ">&", \*STDERR; close STDERR;
$t->run();
open STDERR, ">&", \*OLDERR;

plan(skip_all => 'no ALPN/NPN negotiation') unless defined getconn(port(8080));
$t->plan(1);

###############################################################################

# client cancels 2nd stream after HEADERS has been created
# while some unsent data was left in the SSL buffer
# HEADERS frame may stuck in SSL buffer and won't be sent producing alert

my $s = getconn(port(8080));
ok($s, 'ssl connection');

my $sid = $s->new_stream({ path => '/tbig.html' });

select undef, undef, undef, 0.2;
$s->h2_rst($sid, 8);

$sid = $s->new_stream({ path => '/tbig.html' });

select undef, undef, undef, 0.2;
$s->h2_rst($sid, 8);

$t->stop();

###############################################################################

sub getconn {
    my ($port) = @_;
    my $s;

    eval {
        my $sock = Test::Nginx::HTTP2::new_socket($port, SSL => 1,
            alpn => 'h2');
        $s = Test::Nginx::HTTP2->new($port, socket => $sock)
            if $sock->alpn_selected();
    };

    return $s if defined $s;

    eval {
        my $sock = Test::Nginx::HTTP2::new_socket($port, SSL => 1,
            npn => 'h2');
        $s = Test::Nginx::HTTP2->new($port, socket => $sock)
            if $sock->next_proto_negotiated();
    };

    return $s;
}

###############################################################################
