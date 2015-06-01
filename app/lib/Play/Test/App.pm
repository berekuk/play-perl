package Play::Test::App;

use strict;
use warnings;

use 5.010;

use parent qw(Exporter);
our @EXPORT = qw( http_json register_email );

use lib '../backend/lib';

BEGIN {
    $ENV{QH_DEV} = 1;
}

use Import::Into;

sub http_json {
    my ($method, $url, @rest) = @_;
    my $response = Dancer::Test::dancer_response($method => $url, @rest);
    Test::More::is($response->status, 200, "$method => $url status code") or Test::More::diag($response->content);

    if (ref $response->content eq 'GLOB') {
        my $fh = $response->content;
        local $/ = undef;
        $response->content(join '', <$fh>);
    }

    my $result = JSON::decode_json($response->content);
    Dancer::SharedData->reset_all; # necessary because Dancer::Session::Simple somehow revives even after session->destroy
    return $result;
}

# register_email 'foo' => { email => 'a@b.com', notify_likes => 1 }
# email will be confirmed automatically
# user must be logged in
sub register_email {
    my ($user, $settings) = @_;

    http_json PUT => '/api/current_user/settings', { params => $settings };

    my @deliveries = Play::Test::process_email_queue();
    my ($secret) = $deliveries[0]->{email}->get_body =~ qr/(\d+)</;
    http_json POST => "/api/register/confirm_email", { params => { login => $user, secret => $secret } };
    Play::Test::process_email_queue();
    return;
}

sub import {
    my $target = caller;

    require JSON; JSON->import::into($target, qw(decode_json encode_json));
    require Play::Test; Play::Test->import::into($target);

    # the order is important
    require Dancer; Dancer->import::into($target);
    Dancer::set(log => 'info');

    require Play; Play->import::into($target);
    require Dancer::Test; Dancer::Test->import::into($target);

    __PACKAGE__->export_to_level(1, @_);
}

1;
