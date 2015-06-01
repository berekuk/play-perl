package Play::Route::Users;

use Dancer ':syntax';

use LWP::UserAgent;
use JSON qw(decode_json);

use Dancer::Plugin::Auth::Twitter;
auth_twitter_init();

use Play::Config;
use Play::DB qw(db);

use Play::App::Util qw( login try_login );

use Image::Resize;

get '/auth/twitter' => sub {
    if (not session('twitter_user')) {
        redirect auth_twitter_authenticate_url;
    } else {

        my $twitter_login = session('twitter_user')->{screen_name} or die "no twitter login in twitter_user session field";
        my $user = db->users->get_by_twitter_login($twitter_login);
        if ($user) {
            session 'login' => $user->{login};
        }
        redirect "/register";
    }
};

post '/auth/persona' => sub {
    session 'persona_email' => undef;

    my $assertion = param('assertion') or die "no assertion specified";
    my $ua = LWP::UserAgent->new;
    my $response = $ua->post('https://verifier.login.persona.org/verify', {
        assertion => $assertion,
        audience => setting('hostport'),
    });
    die "Invalid response from persona.org: ".$response->status_line unless $response->is_success;

    my $json = $response->decoded_content;
    my $verification_data = decode_json($json);

    my $status = $verification_data->{status};
    die "verification_data status is not okay (it's $status); json: $json" unless $status eq 'okay';

    my $email = $verification_data->{email};
    unless ($email) {
        die "No email in verification_data";
    }
    session 'persona_email' => $email;

    my $user = db->users->get_by_email($email);
    if ($user) {
        session 'login' => $user->{login};

        if (not $user->{settings}{email_confirmed}) {
            # TODO - upgrade email_confirmed to persona?
        }
    }

    return { result => 'ok' };
};

prefix '/api';

get '/current_user' => sub {
    my $user = {};
    my $login = try_login;

    if ($login) {
        $user = db->users->get_by_login($login);
        unless ($user) {
            die "user '$login' not found";
        }
        $user->{registered} = 1;

        $user->{settings} = db->users->get_settings($login);
        $user->{notifications} = db->notifications->list($login);
        $user->{default_upic} = db->images->is_upic_default($login);
    }
    else {
        $user->{registered} = 0;
    }

    if (session('twitter_user')) {
        $user->{twitter} = session('twitter_user');
    }

    if (session('persona_email') and not $user->{registered}) {
        $user->{settings}{email} = session('persona_email');
        $user->{settings}{email_confirmed} = 'persona';
    }
    $user->{persona_user} = session('persona_email') if session('persona_email');

    return $user;
};

# user settings are private; you can't get settings of other users
get '/current_user/settings' => sub {
    return db->users->get_settings(login);
};

post '/current_user/pic' => sub {
    my $login = login;
    my $file = upload('pic');
    unless ($file) {
        die "No pic provided";
    }

    db->images->store_upic_by_content($login, $file->content);
    redirect '/settings';
};

any ['put', 'post'] => '/current_user/settings' => sub {
    my $login = login;

    db->users->set_settings(
        $login => _expand_settings(scalar params()),
        (session('persona_email') ? 1 : 0) # force 'email_confirmed' setting
    );
    return { result => 'ok' };
};

post "/settings/set/:name/:value" => sub {
    my $login = login;

    db->users->set_setting(
        $login,
        param('name'),
        param('value')
    );
    return { result => 'ok' };
};

post '/current_user/generate_api_token' => sub {
    my $login = login;

    my $token = db->users->generate_api_token(login);
    return { result => 'ok', api_token => $token };
};

post '/current_user/dismiss_notification/:id' => sub {
    my $login = login;

    db->notifications->remove(param('id'), $login);
    return { result => 'ok' };
};

get '/user/:login' => sub {
    my $login = param('login');
    my $user = db->users->get_by_login($login);
    unless ($user) {
        die "user '$login' not found";
    }

    return $user;
};

get '/user/:login/stat' => sub {
    my $login = param('login');
    return db->users->stat($login);
};

get '/user/:login/pic' => sub {
    my $size = param('s');
    my $file = db->images->upic_file(param('login'), $size);
    send_file($file, content_type => 'image/jpg', system_path => 1);
};


sub _expand_settings {
    my ($settings) = @_;

    my $more_settings = {};
    if (session('persona_email')) {
        $more_settings->{email} = session('persona_email');
    }
    return { %$settings, %$more_settings };
}

post '/register' => sub {
    my $login = param('login') or die 'no login specified';

    unless ($login =~ /^\w+$/) {
        status 'bad request';
        return "Invalid login '$login', only alphanumericals are allowed";
    }

    if (db->users->get_by_login($login)) {
        return { status => 'conflict', reason => 'login', message => "User $login already exists" };
    }

    my $user = { login => $login };

    my $settings = param('settings') || '{}';
    $settings = decode_json($settings);

    if (session('twitter_user')) {
        my $twitter_login = session('twitter_user')->{screen_name};

        if (db->users->get_by_twitter_login($twitter_login)) {
            die "Twitter login $twitter_login is already bound";
        }

        $user->{twitter} = {
            screen_name => $twitter_login,
            profile_image_url => session('twitter_user')->{profile_image_url},
        };
    }
    elsif (not session('persona_email')) {
        die "not authorized by any 3rd party (either twitter or persona)";
    }

    $settings = _expand_settings($settings);
    if ($settings->{email} and db->users->get_by_email($settings->{email})) {
        return { status => 'conflict', reason => 'email', message => "Someone already uses this email" };
    }

    # note that race condition is still possible after these checks
    # that's ok, mongodb will throw an exception

    db->users->add(
        $user,
        $settings,
        (session('persona_email') ? 1 : 0) # force 'email_confirmed' setting
    );

    session 'login' => $login;

    return { status => "ok", user => $user };
};

post '/register/cancel' => sub {
    if (session('login')) {
        die "too late, you're already logged in";
    }
    session 'twitter_user' => undef;
    session 'persona_email' => undef;
    return { status => 'ok' };
};

post '/register/resend_email_confirmation' => sub {
    my $login = login;

    db->users->resend_email_confirmation($login);
    return { result => 'ok' };
};

# user doesn't need to be logged to use this route
post '/register/confirm_email' => sub {
    # throws an exception if something's wrong
    db->users->confirm_email(param('login') => param('secret'));
    return { confirmed => 1 };
};

get '/user' => sub {
    # optional fields
    my $params = {
        map { param($_) ? ($_ => param($_)) : () } qw/ sort order limit offset /,
    };
    # required fields
    for (qw/ realm /) {
        my $value = param($_) or die "'$_' is not set";
        $params->{$_} = $value;
    }
    $params->{limit} ||= 50;

    return db->users->list($params);
};

get '/user/:login/unsubscribe/:field' => sub {
    my $secret = param('secret') or die "secret is not set";

    eval {
        db->users->unsubscribe({
            login => param('login'),
            notify_field => param('field'),
            secret => $secret,
        });
    };

    my $redirect = '/player/' . param('login') . '/unsubscribe/' . param('field');
    if ($@) {
        redirect "$redirect/fail";
    }
    else {
        redirect "$redirect/ok";
    }
};

for my $method (qw( follow_realm unfollow_realm )) {
    post "/$method/:realm" => sub {
        my $login = login;

        db->users->$method($login, param('realm'));

        return { status => 'ok' };
    };
}

for my $method (qw( follow unfollow )) {
    post "/user/:login/$method" => sub {
        my $login = login;

        my $full_method = "${method}_user";
        db->users->$full_method($login, param('login'));

        return { status => 'ok' };
    };
}

post '/logout' => sub {
    session->destroy(session); #FIXME: workaround a buggy Dancer::Session::MongoDB
    return { status => 'ok' };
};

get '/user/:prefix/autocomplete' => sub {
    return db->users->autocomplete(param('prefix'));
};

if ($ENV{QH_DEV}) {
    get '/fakeuser/:login' => sub {
        my $login = param('login');
        session 'login' => $login;

        my $user = { login => $login, realms => [map { $_->{id} } @{ db->realms->list }] };

        unless (param('notwitter')) {
            session 'twitter_user' => { screen_name => $login } unless param('notwitter');
            $user->{twitter} = { screen_name => $login };
        }

        db->users->get_by_login($login) or db->users->add($user);
        return { status => 'ok', user => $user };
    };
}

true;
