#!/usr/bin/perl

# (C) Sergey Kandaurov
# (C) Nginx, Inc.

# Tests for SPDY protocol version 3.1.

###############################################################################

use warnings;
use strict;

use Test::More;

use IO::Select;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

eval {
	require Compress::Raw::Zlib;
	Compress::Raw::Zlib->Z_OK;
	Compress::Raw::Zlib->Z_SYNC_FLUSH;
	Compress::Raw::Zlib->Z_NO_COMPRESSION;
	Compress::Raw::Zlib->WANT_GZIP_OR_ZLIB;
};
plan(skip_all => 'Compress::Raw::Zlib not installed') if $@;
plan(skip_all => 'win32') if $^O eq 'MSWin32';

my $t = Test::Nginx->new()->has(qw/http proxy cache limit_conn rewrite spdy/);

plan(skip_all => 'no SPDY/3.1') unless $t->has_version('1.5.10');

$t->plan(72)->write_file_expand('nginx.conf', <<'EOF');

%%TEST_GLOBALS%%

daemon off;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    proxy_cache_path %%TESTDIR%%/cache    keys_zone=NAME:10m;
    limit_conn_zone  $binary_remote_addr  zone=conn:1m;

    server {
        listen       127.0.0.1:8080 spdy;
        listen       127.0.0.1:8081;
        server_name  localhost;

        location /s {
            add_header X-Header X-Foo;
            return 200 'body';
        }
        location /spdy {
            return 200 $spdy;
        }
        location /prio {
            return 200 $spdy_request_priority;
        }
        location /chunk_size {
            spdy_chunk_size 1;
            return 200 'body';
        }
        location /redirect {
            error_page 405 /s;
            return 405;
        }
        location /proxy {
            add_header X-Body "$request_body";
            proxy_pass http://127.0.0.1:8081/;
            proxy_cache NAME;
            proxy_cache_valid 1m;
        }
        location /t3.html {
            limit_conn conn 1;
        }
    }
}

EOF

$t->run();

# file size is slightly beyond initial window size: 2**16 + 80 bytes

$t->write_file('t1.html',
	join('', map { sprintf "X%04dXXX", $_ } (1 .. 8202)));

$t->write_file('t2.html', 'SEE-THIS');
$t->write_file('t3.html', 'SEE-THIS');

my %cframe = (
	2 => \&syn_reply,
	3 => \&rst_stream,
	4 => \&settings,
	6 => \&ping,
	7 => \&goaway,
	9 => \&window_update
);

###############################################################################

# PING

my $sess = new_session();
spdy_ping($sess, 0x12345678);
my $frames = spdy_read($sess);

my ($frame) = grep { $_->{type} eq "PING" } @$frames;
ok($frame, 'PING frame');
is($frame->{value}, 0x12345678, 'PING payload');

# GET

$sess = new_session();
my $sid1 = spdy_stream($sess, { path => '/s' });
$frames = spdy_read($sess, all => [{ sid => $sid1, fin => 1 }]);

($frame) = grep { $_->{type} eq "SYN_REPLY" } @$frames;
ok($frame, 'SYN_REPLAY frame');
is($frame->{sid}, $sid1, 'SYN_REPLAY stream');
is($frame->{headers}->{':status'}, 200, 'SYN_REPLAY status');
is($frame->{headers}->{'x-header'}, 'X-Foo', 'SYN_REPLAY header');

($frame) = grep { $_->{type} eq "DATA" } @$frames;
ok($frame, 'DATA frame');
is($frame->{length}, length 'body', 'DATA length');
is($frame->{data}, 'body', 'DATA payload');

# GET in new SPDY stream in same session

my $sid2 = spdy_stream($sess, { path => '/s' });
$frames = spdy_read($sess, all => [{ sid => $sid2, fin => 1 }]);

($frame) = grep { $_->{type} eq "SYN_REPLY" } @$frames;
is($frame->{sid}, $sid2, 'SYN_REPLAY stream 2');
is($frame->{headers}->{':status'}, 200, 'SYN_REPLAY status 2');
is($frame->{headers}->{'x-header'}, 'X-Foo', 'SYN_REPLAY header 2');

($frame) = grep { $_->{type} eq "DATA" } @$frames;
ok($frame, 'DATA frame 2');
is($frame->{sid}, $sid2, 'SYN_REPLAY stream 2');
is($frame->{length}, length 'body', 'DATA length 2');
is($frame->{data}, 'body', 'DATA payload 2');

# HEAD

$sess = new_session();
$sid1 = spdy_stream($sess, { path => '/s', method => 'HEAD' });
$frames = spdy_read($sess, all => [{ sid => $sid1, fin => 1 }]);

($frame) = grep { $_->{type} eq "SYN_REPLY" } @$frames;
is($frame->{sid}, $sid1, 'SYN_REPLAY stream HEAD');
is($frame->{headers}->{':status'}, 200, 'SYN_REPLAY status HEAD');
is($frame->{headers}->{'x-header'}, 'X-Foo', 'SYN_REPLAY header HEAD');

($frame) = grep { $_->{type} eq "DATA" } @$frames;
is($frame, undef, 'HEAD no body');

# request header

$sess = new_session();
$sid1 = spdy_stream($sess, { path => '/t1.html',
	headers => { "range" =>  "bytes=10-19" }
});
$frames = spdy_read($sess, all => [{ sid => $sid1, fin => 1 }]);

($frame) = grep { $_->{type} eq "SYN_REPLY" } @$frames;
is($frame->{headers}->{':status'}, 206, 'SYN_REPLAY status range');

($frame) = grep { $_->{type} eq "DATA" } @$frames;
is($frame->{length}, 10, 'DATA length range');
is($frame->{data}, '002XXXX000', 'DATA payload range');

# $spdy

$sess = new_session();
$sid1 = spdy_stream($sess, { path => '/spdy' });
$frames = spdy_read($sess, all => [{ sid => $sid1, fin => 1 }]);

($frame) = grep { $_->{type} eq "DATA" } @$frames;
is($frame->{data}, '3.1', 'spdy variable');

# spdy_chunk_size=1

$sess = new_session();
$sid1 = spdy_stream($sess, { path => '/chunk_size' });
$frames = spdy_read($sess, all => [{ sid => $sid1, fin => 1 }]);

my @data = grep { $_->{type} eq "DATA" } @$frames;
is(@data, 4, 'chunk_size body chunks');
is($data[0]->{data}, 'b', 'chunk_size body 1');
is($data[1]->{data}, 'o', 'chunk_size body 2');
is($data[2]->{data}, 'd', 'chunk_size body 3');
is($data[3]->{data}, 'y', 'chunk_size body 4');

# redirect

$sess = new_session();
$sid1 = spdy_stream($sess, { path => '/redirect' });
$frames = spdy_read($sess, all => [{ sid => $sid1, fin => 1 }]);

($frame) = grep { $_->{type} eq "SYN_REPLY" } @$frames;
is($frame->{headers}->{':status'}, 405, 'SYN_REPLAY status with redirect');

($frame) = grep { $_->{type} eq "DATA" } @$frames;
ok($frame, 'DATA frame with redirect');
is($frame->{data}, 'body', 'DATA payload with redirect');

# ensure that HEAD-like requests, i.e., without response body, do not lead to
# client connection close due to cache filling up with upstream response body

TODO: {
local $TODO = 'premature client connection close';

$sess = new_session();
$sid1 = spdy_stream($sess, { path => '/proxy/t2.html', method => 'HEAD' });
$frames = spdy_read($sess, all => [{ sid => $sid1, fin => 1 }]);

$sid2 = spdy_stream($sess, { path => '/' });
$frames = spdy_read($sess, all => [{ sid => $sid1, fin => 1 }]);
ok(grep ({ $_->{type} eq "SYN_REPLY" } @$frames), 'proxy cache headers only');

}

# simple proxy cache test

$sess = new_session();
$sid1 = spdy_stream($sess, { path => '/proxy/t2.html' });
$frames = spdy_read($sess, all => [{ sid => $sid1, fin => 1 }]);

($frame) = grep { $_->{type} eq "SYN_REPLY" } @$frames;
is($frame->{headers}->{':status'}, '200 OK', 'proxy cache unconditional');

my $etag = $frame->{headers}->{'etag'};

SKIP: {
skip 'no etag', 1 unless defined $etag;

$sid2 = spdy_stream($sess, { path => '/proxy/t2.html',
	headers => { "if-none-match" =>  $etag }
});
$frames = spdy_read($sess, all => [{ sid => $sid2, fin => 1 }]);

($frame) = grep { $_->{type} eq "SYN_REPLY" } @$frames;
is($frame->{headers}->{':status'}, 304, 'proxy cache conditional');

}

# request body (uses proxied response)

$sess = new_session();
$sid1 = spdy_stream($sess, { path => '/proxy/t2.html', body => 'TEST' });
$frames = spdy_read($sess, all => [{ sid => $sid1, fin => 1 }]);

($frame) = grep { $_->{type} eq "SYN_REPLY" } @$frames;
is($frame->{headers}->{'x-body'}, 'TEST', 'request body');

($frame) = grep { $_->{type} eq "DATA" } @$frames;
is($frame->{length}, length 'SEE-THIS', 'proxied response length');
is($frame->{data}, 'SEE-THIS', 'proxied response');

# WINDOW_UPDATE (client side)

$sess = new_session();
$sid1 = spdy_stream($sess, { path => '/t1.html' });
$frames = spdy_read($sess, all => [{ sid => $sid1, fin => 0 }]);

@data = grep { $_->{type} eq "DATA" } @$frames;
my $sum = eval join '+', map { $_->{length} } @data;
is($sum, 2**16, 'iws - stream blocked on initial window size');

spdy_ping($sess, 0xf00ff00f);
$frames = spdy_read($sess);

($frame) = grep { $_->{type} eq "PING" } @$frames;
ok($frame, 'iws - PING not blocked');

spdy_window($sess, 2**16, $sid1);
$frames = spdy_read($sess);
is(@$frames, 0, 'iws - updated stream window');

spdy_window($sess, 2**16);
$frames = spdy_read($sess, all => [{ sid => $sid1, fin => 1 }]);

@data = grep { $_->{type} eq "DATA" } @$frames;
$sum = eval join '+', map { $_->{length} } @data;
is($sum, 80, 'iws - updated connection window');

# SETTINGS (initial window size, client side)

$sess = new_session();
spdy_settings($sess, 7 => 2**17);
spdy_window($sess, 2**17);

$sid1 = spdy_stream($sess, { path => '/t1.html' });
$frames = spdy_read($sess, all => [{ sid => $sid1, fin => 1 }]);

@data = grep { $_->{type} eq "DATA" } @$frames;
$sum = eval join '+', map { $_->{length} } @data;
is($sum, 2**16 + 80, 'increased initial window size');

# probe for negative available space in a flow control window

$sess = new_session();
$sid1 = spdy_stream($sess, { path => '/t1.html' });
spdy_read($sess, all => [{ sid => $sid1, fin => 0 }]);

spdy_window($sess, 1);
spdy_settings($sess, 7 => 42);
spdy_window($sess, 1024, $sid1);

$frames = spdy_read($sess);
is(@$frames, 0, 'negative window - no data');

spdy_window($sess, 2**16 - 42 - 1024, $sid1);
$frames = spdy_read($sess);
is(@$frames, 0, 'zero window - no data');

spdy_window($sess, 1, $sid1);
$frames = spdy_read($sess, all => [{ sid => $sid1, fin => 0 }]);
is(@$frames, 1, 'positive window - data');
is(@$frames[0]->{length}, 1, 'positive window - data length');

# stream multiplexing

$sess = new_session();
$sid1 = spdy_stream($sess, { path => '/t1.html' });
$frames = spdy_read($sess, all => [{ sid => $sid1, fin => 0 }]);

@data = grep { $_->{type} eq "DATA" } @$frames;
$sum = eval join '+', map { $_->{length} } @data;
is($sum, 2**16, 'multiple - stream1 data');

$sid2 = spdy_stream($sess, { path => '/t1.html' });
$frames = spdy_read($sess, all => [{ sid => $sid2, fin => 0 }]);

@data = grep { $_->{type} eq "DATA" } @$frames;
is(@data, 0, 'multiple - stream2 no data');

spdy_window($sess, 2**17, $sid1);
spdy_window($sess, 2**17, $sid2);
spdy_window($sess, 2**17);

$frames = spdy_read($sess, all => [
	{ sid => $sid1, fin => 1 },
	{ sid => $sid2, fin => 1 }
]);

@data = grep { $_->{type} eq "DATA" && $_->{sid} == $sid1 } @$frames;
$sum = eval join '+', map { $_->{length} } @data;
is($sum, 80, 'multiple - stream1 remain data');

@data = grep { $_->{type} eq "DATA" && $_->{sid} == $sid2 } @$frames;
$sum = eval join '+', map { $_->{length} } @data;
is($sum, 2**16 + 80, 'multiple - stream2 full data');

# request priority parsing in $spdy_request_priority

$sess = new_session();
$sid1 = spdy_stream($sess, { path => '/prio', prio => 0 });
$frames = spdy_read($sess, all => [{ sid => $sid1, fin => 1 }]);

($frame) = grep { $_->{type} eq "DATA" } @$frames;
is($frame->{data}, 0, 'priority 0');

$sid1 = spdy_stream($sess, { path => '/prio', prio => 1 });
$frames = spdy_read($sess, all => [{ sid => $sid1, fin => 1 }]);

($frame) = grep { $_->{type} eq "DATA" } @$frames;
is($frame->{data}, 1, 'priority 1');

$sid1 = spdy_stream($sess, { path => '/prio', prio => 7 });
$frames = spdy_read($sess, all => [{ sid => $sid1, fin => 1 }]);

($frame) = grep { $_->{type} eq "DATA" } @$frames;
is($frame->{data}, 7, 'priority 7');

# stream muliplexing + priority

TODO: {
local $TODO = 'reversed priority' unless $t->has_version('1.5.11');

$sess = new_session();
$sid1 = spdy_stream($sess, { path => '/t1.html', prio => 7 });
$sid2 = spdy_stream($sess, { path => '/t2.html', prio => 0 });
spdy_read($sess);

spdy_window($sess, 2**17, $sid1);
spdy_window($sess, 2**17, $sid2);
spdy_window($sess, 2**17);

$frames = spdy_read($sess, all => [
	{ sid => $sid1, fin => 1 },
	{ sid => $sid2, fin => 1 }
]);

@data = grep { $_->{type} eq "DATA" } @$frames;
is(join (' ', map { $_->{sid} } @data), "$sid2 $sid1", 'multiple priority 1');

# and vice versa

$sess = new_session();
$sid1 = spdy_stream($sess, { path => '/t1.html', prio => 0 });
$sid2 = spdy_stream($sess, { path => '/t2.html', prio => 7 });
spdy_read($sess);

spdy_window($sess, 2**17, $sid1);
spdy_window($sess, 2**17, $sid2);
spdy_window($sess, 2**17);

$frames = spdy_read($sess, all => [
	{ sid => $sid1, fin => 1 },
	{ sid => $sid2, fin => 1 }
]);

@data = grep { $_->{type} eq "DATA" } @$frames;
is(join (' ', map { $_->{sid} } @data), "$sid1 $sid2", 'multiple priority 2');

}

# limit_conn

$sess = new_session();
spdy_settings($sess, 7 => 1);
$sid1 = spdy_stream($sess, { path => '/t3.html' });
$sid2 = spdy_stream($sess, { path => '/t3.html' });
$frames = spdy_read($sess, all => [
	{ sid => $sid1, fin => 0 },
	{ sid => $sid2, fin => 0 }
]);

($frame) = grep { $_->{type} eq "SYN_REPLY" && $_->{sid} == $sid1 } @$frames;
is($frame->{headers}->{':status'}, 200, 'conn_limit 1');

($frame) = grep { $_->{type} eq "SYN_REPLY" && $_->{sid} == $sid2 } @$frames;
is($frame->{headers}->{':status'}, 503, 'conn_limit 2');

# limit_conn + client's RST_STREAM

$sess = new_session();
spdy_settings($sess, 7 => 1);
$sid1 = spdy_stream($sess, { path => '/t3.html' });
spdy_rst($sess, $sid1, 5);
$sid2 = spdy_stream($sess, { path => '/t3.html' });
$frames = spdy_read($sess, all => [
	{ sid => $sid1, fin => 0 },
	{ sid => $sid2, fin => 0 }
]);

($frame) = grep { $_->{type} eq "SYN_REPLY" && $_->{sid} == $sid1 } @$frames;
is($frame->{headers}->{':status'}, 200, 'RST_STREAM 1');

($frame) = grep { $_->{type} eq "SYN_REPLY" && $_->{sid} == $sid2 } @$frames;
is($frame->{headers}->{':status'}, 200, 'RST_STREAM 2');

# GOAWAY on SYN_STREAM with even StreamID

TODO: {
local $TODO = 'not yet';

$sess = new_session();
spdy_stream($sess, { path => '/s' }, 2);
$frames = spdy_read($sess);

($frame) = grep { $_->{type} eq "GOAWAY" } @$frames;
ok($frame, 'even stream - GOAWAY frame');
is($frame->{code}, 1, 'even stream - error code');
is($frame->{sid}, 0, 'even stream - last used stream');

}

# GOAWAY on SYN_STREAM with backward StreamID

TODO: {
local $TODO = 'not yet';

$sess = new_session();
$sid1 = spdy_stream($sess, { path => '/s' }, 3);
spdy_read($sess);

$sid2 = spdy_stream($sess, { path => '/s' }, 1);
$frames = spdy_read($sess);

($frame) = grep { $_->{type} eq "GOAWAY" } @$frames;
ok($frame, 'backward stream - GOAWAY frame');
is($frame->{code}, 1, 'backward stream - error code');
is($frame->{sid}, $sid1, 'backward stream - last used stream');

}

# RST_STREAM on the second SYN_STREAM with same StreamID

TODO: {
local $TODO = 'not yet';

$sess = new_session();
$sid1 = spdy_stream($sess, { path => '/s' }, 3);
spdy_read($sess, all => [{ sid => $sid1, fin => 1 }]);
$sid2 = spdy_stream($sess, { path => '/s' }, 3);
$frames = spdy_read($sess);

($frame) = grep { $_->{type} eq "RST_STREAM" } @$frames;
ok($frame, 'dup stream - RST_STREAM frame');
is($frame->{code}, 1, 'dup stream - error code');
is($frame->{sid}, $sid1, 'dup stream - stream');

}

# awkward protocol version

TODO: {
local $TODO = 'not yet' unless $t->has_version('1.5.11');

$sess = new_session();
$sid1 = spdy_stream($sess, { path => '/s', version => 'HTTP/1.10' });
$frames = spdy_read($sess, all => [{ sid => $sid1, fin => 1 }]);

($frame) = grep { $_->{type} eq "SYN_REPLY" } @$frames;
is($frame->{headers}->{':status'}, 200, 'awkward version');

}

# missing mandatory request header

$sess = new_session();
$sid1 = spdy_stream($sess, { path => '/s', version => '' });
$frames = spdy_read($sess, all => [{ sid => $sid1, fin => 1 }]);

($frame) = grep { $_->{type} eq "SYN_REPLY" } @$frames;
is($frame->{headers}->{':status'}, 400, 'incomplete headers');

# GOAWAY before closing a connection by server

$t->stop();

TODO: {
local $TODO = 'not yet';

$frames = spdy_read($sess);

($frame) = grep { $_->{type} eq "GOAWAY" } @$frames;
ok($frame, 'GOAWAY on connection close');

}

###############################################################################

sub spdy_ping {
	my ($sess, $payload) = @_;

	raw_write($sess->{socket}, pack("N3", 0x80030006, 0x4, $payload));
}

sub spdy_rst {
	my ($sess, $sid, $error) = @_;

	raw_write($sess->{socket}, pack("N4", 0x80030003, 0x8, $sid, $error));
}

sub spdy_window {
	my ($sess, $win, $stream) = @_;

	$stream = 0 unless defined $stream;
	raw_write($sess->{socket}, pack("N4", 0x80030009, 8, $stream, $win));
}

sub spdy_settings {
	my ($sess, %extra) = @_;

	my $cnt = keys %extra;
	my $len = 4 + 8 * $cnt;

	my $buf = pack "N3", 0x80030004, $len, $cnt;
	$buf .= join '', map { pack "N2", $_, $extra{$_} } keys %extra;
	raw_write($sess->{socket}, $buf);
}

sub spdy_read {
	my ($sess, %extra) = @_;
	my ($skip, $length, $buf, @got);
	my $tries = 0;
	my $maxtried = 3;

again:
	do {
		$buf = raw_read($sess->{socket});
	} until (defined $buf || $tries++ >= $maxtried);

	$buf = '' if !defined $buf;

	for ($skip = 0; $skip < length $buf; $skip += $length + 8) {
		my $type = unpack("\@$skip B", $buf);
		$length = hex unpack("\@$skip x5 H6", $buf);
		if ($type == 0) {
			push @got, dframe($skip, $buf);
			test_fin($got[-1], $extra{all});
			next;
		}

		my $ctype = unpack("\@$skip x2 n", $buf);
		push @got, $cframe{$ctype}($sess, $skip, $buf);
		test_fin($got[-1], $extra{all});
	}
	goto again if %extra && @{$extra{all}} && $tries < $maxtried;
	return \@got;
}

sub test_fin {
	my ($frame, $all) = @_;

	@{$all} = grep {
		!($_->{sid} == $frame->{sid} && $_->{fin} == $frame->{fin})
	} @{$all} if defined $frame->{fin};
}

sub dframe {
	my ($skip, $buf) = @_;
	my %frame;

	my $stream = unpack "\@$skip B32", $buf; $skip += 4;
	substr($stream, 0, 1) = 0;
	$stream = unpack("N", pack("B32", $stream));
	$frame{sid} = $stream;

	my $flags = unpack "\@$skip B8", $buf; $skip += 1;
	$frame{fin} = substr($flags, 7, 1);

	my $length = hex (unpack "\@$skip H6", $buf); $skip += 3;
	$frame{length} = $length;

	$frame{data} = substr($buf, $skip, $length);
	$frame{type} = "DATA";
	return \%frame;
}

sub spdy_stream {
	my ($ctx, $uri, $stream) = @_;
	my ($input, $output, $buf);
	my ($d, $status);

	my $host = $uri->{host} || '127.0.0.1:8080';
	my $method = $uri->{method} || 'GET';
	my $headers = $uri->{headers} || {};
	my $body = $uri->{body};
	my $prio = defined $uri->{prio} ? $uri->{prio} : 4;
	my $version = defined $uri->{version} ? $uri->{version} : "HTTP/1.1";

	if ($stream) {
		$ctx->{last_stream} = $stream;
	} else {
		$ctx->{last_stream} += 2;
	}

	$buf = pack("NC", 0x80030001, not $body);
	$buf .= pack("xxx");			# Length stub
	$buf .= pack("N", $ctx->{last_stream});	# Stream-ID
	$buf .= pack("N", 0);			# Assoc. Stream-ID
	$buf .= pack("n", $prio << 13);

	my $ent = 4 + keys %{$headers};
	$ent++ if $body;
	$ent++ if $version;

	$input = pack("N", $ent);
	$input .= hpack(":host", $host);
	$input .= hpack(":method", $method);
	$input .= hpack(":path", $uri->{path});
	$input .= hpack(":scheme", "http");
	if ($version) {
		$input .= hpack(":version", $version);
	}
	if ($body) {
		$input .= hpack("content-length", length $body);
	}
	$input .= join '', map { hpack($_, $headers->{$_}) } keys %{$headers};

	$d = $ctx->{zlib}->{d};
	$status = $d->deflate($input => \my $start);
	$status == Compress::Raw::Zlib->Z_OK or fail "deflate failed";
	$status = $d->flush(\my $tail => Compress::Raw::Zlib->Z_SYNC_FLUSH);
	$status == Compress::Raw::Zlib->Z_OK or fail "flush failed";
	$output = $start . $tail;

	my $len = '';
	vec($len, 7, 8) = (length $output) + 10;
	$buf |= $len;
	$buf .= $output;

	if (defined $body) {
		$buf .= pack "NCxn", $ctx->{last_stream}, 0x01, length $body;
		$buf .= $body;
	}

	raw_write($ctx->{socket}, $buf);
	return $ctx->{last_stream};
}

sub syn_reply {
	my ($ctx, $skip, $buf) = @_;
	my ($i, $status);
	my %payload;

	$skip += 4;
	my $flags = unpack "\@$skip B8", $buf; $skip += 1;
	$payload{fin} = substr($flags, 7, 1);

	my $length = hex unpack "\@$skip H6", $buf; $skip += 3;
	$payload{length} = $length;
	$payload{type} = 'SYN_REPLY';

	my $stream = unpack "\@$skip B32", $buf; $skip += 4;
	substr($stream, 0, 1) = 0;
	$stream = unpack("N", pack("B32", $stream));
	$payload{sid} = $stream;

	my $input = substr($buf, $skip, $length - 4);
	$i = $ctx->{zlib}->{i};

	$status = $i->inflate($input => \my $out);
	fail "Failed: $status" unless $status == Compress::Raw::Zlib->Z_OK;
	$payload{headers} = hunpack($out);
	return \%payload;
}

sub rst_stream {
	my ($ctx, $skip, $buf) = @_;
	my %payload;

	$skip += 5;
	$payload{length} = hex(unpack "\@$skip H6", $buf); $skip += 3;
	$payload{type} = 'RST_STREAM';
	$payload{sid} = unpack "\@$skip N", $buf; $skip += 4;
	$payload{code} = unpack "\@$skip N", $buf;
	return \%payload;
}

sub settings {
	my ($ctx, $skip, $buf) = @_;
	my %payload;

	$skip += 4;
	$payload{flags} = unpack "\@$skip H", $buf; $skip += 1;
	$payload{length} = hex(unpack "\@$skip H6", $buf); $skip += 3;
	$payload{type} = 'SETTINGS';

	my $nent = unpack "\@$skip N", $buf; $skip += 4;
	for (1 .. $nent) {
		my $flags = hex unpack "\@$skip H2", $buf; $skip += 1;
		my $id = hex unpack "\@$skip H6", $buf; $skip += 3;
		$payload{$id}{flags} = $flags;
		$payload{$id}{value} = unpack "\@$skip N", $buf; $skip += 4;
	}
	return \%payload;
}

sub ping {
	my ($ctx, $skip, $buf) = @_;
	my %payload;

	$skip += 5;
	$payload{length} = hex(unpack "\@$skip H6", $buf); $skip += 3;
	$payload{type} = 'PING';
	$payload{value} = unpack "\@$skip N", $buf;
	return \%payload;
}

sub goaway {
	my ($ctx, $skip, $buf) = @_;
	my %payload;

	$skip += 5;
	$payload{length} = hex unpack "\@$skip H6", $buf; $skip += 3;
	$payload{type} = 'GOAWAY';
	$payload{sid} = unpack "\@$skip N", $buf; $skip += 4;
	$payload{code} = unpack "\@$skip N", $buf;
	return \%payload;
}

sub window_update {
	my ($ctx, $skip, $buf) = @_;
	my %payload;

	$skip += 5;

	$payload{length} = hex(unpack "\@$skip H6", $buf); $skip += 3;
	$payload{type} = 'WINDOW_UPDATE';

	my $stream = unpack "\@$skip B32", $buf; $skip += 4;
	substr($stream, 0, 1) = 0;
	$stream = unpack("N", pack("B32", $stream));
	$payload{sid} = $stream;

	my $value = unpack "\@$skip B32", $buf;
	substr($value, 0, 1) = 0;
	$payload{wdelta} = unpack("N", pack("B32", $value));
	return \%payload;
}

sub hpack {
	my ($name, $value) = @_;

	pack("N", length($name)) . $name . pack("N", length($value)) . $value;
}

sub hunpack {
	my ($data) = @_;
	my %headers;
	my $skip = 0;

	my $nent = unpack "\@$skip N", $data; $skip += 4;
	for (1 .. $nent) {
		my $len = unpack("\@$skip N", $data); $skip += 4;
		my $name = unpack("\@$skip A$len", $data); $skip += $len;

		$len = unpack("\@$skip N", $data); $skip += 4;
		my $value = unpack("\@$skip A$len", $data); $skip += $len;

		$headers{$name} = $value;
	}
	return \%headers;
}

sub raw_read {
	my ($s) = @_;
	my ($got, $buf);

	$s->blocking(0);
	while (IO::Select->new($s)->can_read(0.4)) {
		my $n = $s->sysread($buf, 1024);
		last unless $n;
		$got .= $buf;
	};
	log_in($got);
	return $got;
}

sub raw_write {
	my ($s, $message) = @_;

	local $SIG{PIPE} = 'IGNORE';

	$s->blocking(0);
	while (IO::Select->new($s)->can_write(0.4)) {
		log_out($message);
		my $n = $s->syswrite($message);
		last unless $n;
		$message = substr($message, $n);
		last unless length $message;
	}
}

sub new_session {
	my ($d, $i, $status);

	($d, $status) = Compress::Raw::Zlib::Deflate->new(
		-WindowBits => 12,
		-Dictionary => dictionary(),
		-Level => Compress::Raw::Zlib->Z_NO_COMPRESSION
	);
	fail "Zlib failure: $status" unless $d;

	($i, $status) = Compress::Raw::Zlib::Inflate->new(
		-WindowBits => Compress::Raw::Zlib->WANT_GZIP_OR_ZLIB,
		-Dictionary => dictionary()
	);
	fail "Zlib failure: $status" unless $i;

	return { zlib => { i => $i, d => $d },
		socket => new_socket(), last_stream => -1 };
}

sub new_socket {
	my $s;

	eval {
		local $SIG{ALRM} = sub { die "timeout\n" };
		local $SIG{PIPE} = sub { die "sigpipe\n" };
		alarm(2);
		$s = IO::Socket::INET->new(
			Proto => 'tcp',
			PeerAddr => '127.0.0.1:8080',
		);
		alarm(0);
	};
	alarm(0);

	if ($@) {
		log_in("died: $@");
		return undef;
	}

	return $s;
}

sub dictionary {
	join('', (map pack('N/a*', $_), qw(
		options
		head
		post
		put
		delete
		trace
		accept
		accept-charset
		accept-encoding
		accept-language
		accept-ranges
		age
		allow
		authorization
		cache-control
		connection
		content-base
		content-encoding
		content-language
		content-length
		content-location
		content-md5
		content-range
		content-type
		date
		etag
		expect
		expires
		from
		host
		if-match
		if-modified-since
		if-none-match
		if-range
		if-unmodified-since
		last-modified
		location
		max-forwards
		pragma
		proxy-authenticate
		proxy-authorization
		range
		referer
		retry-after
		server
		te
		trailer
		transfer-encoding
		upgrade
		user-agent
		vary
		via
		warning
		www-authenticate
		method
		get
		status), "200 OK",
		qw(version HTTP/1.1 url public set-cookie keep-alive origin)),
		"100101201202205206300302303304305306307402405406407408409410",
		"411412413414415416417502504505",
		"203 Non-Authoritative Information",
		"204 No Content",
		"301 Moved Permanently",
		"400 Bad Request",
		"401 Unauthorized",
		"403 Forbidden",
		"404 Not Found",
		"500 Internal Server Error",
		"501 Not Implemented",
		"503 Service Unavailable",
		"Jan Feb Mar Apr May Jun Jul Aug Sept Oct Nov Dec",
		" 00:00:00",
		" Mon, Tue, Wed, Thu, Fri, Sat, Sun, GMT",
		"chunked,text/html,image/png,image/jpg,image/gif,",
		"application/xml,application/xhtml+xml,text/plain,",
		"text/javascript,public", "privatemax-age=gzip,deflate,",
		"sdchcharset=utf-8charset=iso-8859-1,utf-,*,enq=0."
	);
}

###############################################################################