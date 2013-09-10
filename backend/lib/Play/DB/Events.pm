package Play::DB::Events;

=head1 FORMAT

Events can be of different types and contain different loosely-typed fields.

See C<API.md> for the description of its structure.

=cut

use 5.010;

use Moo;
with 'Play::DB::Role::Common';

use Log::Any qw($log);

use Play::Mongo;
use Play::Flux;
use Play::Config qw(setting);
use Play::DB qw(db);

use Type::Params qw(validate);
use Types::Standard qw(Undef Int Str Optional HashRef ArrayRef Dict);
use Play::Types qw(Login Realm);

sub _prepare_event {
    my $self = shift;
    my ($event) = @_;
    $event->{ts} = $event->{_id}->get_time;
    $event->{_id} = $event->{_id}->to_string;
    return $event;
}

sub add {
    my $self = shift;
    my ($event) = validate(\@_, HashRef);

    my $realm = $event->{realm};
    die "'realm' is not defined" unless $realm;
    db->realms->validate_name($realm);

    my $id = $self->collection->insert($event);

    my $events_queue = Play::Flux->events;
    $events_queue->write($event);
    $events_queue->commit;

    return 1;
}

sub email {
    my $self = shift;
    my ($item) = validate(\@_, Dict[
        address => Str,
        subject => Str,
        body => Str,
        notify_field => Optional[Str],
        login => Optional[Login],
    ]);

    my $email_storage = Play::Flux->email;
    $email_storage->write($item);
    $email_storage->commit;
}

sub expand_events {
    my $self = shift;
    my ($events) = validate(\@_, ArrayRef);

    my @events = @$events;

    # fetch comments
    {
        my @comment_events = grep {
            defined $_->{comment_id}
        } @events;
        my @comment_ids = map { $_->{comment_id} } @comment_events;

        if (@comment_ids) {
            my $comments = db->comments->bulk_get(\@comment_ids);

            for my $event (@comment_events) {
                $event->{comment} = $comments->{$event->{comment_id}};
                $event->{deleted} = 1 unless $event->{comment};
            }
        }
    }

    # fetch quests and stencils
    for my $entity (qw( quest stencil )) {
        my @events_data;
        for my $event (@events) {
            my $eid = $event->{"${entity}_id"};
            $eid = $event->{comment}{eid} if not defined $eid and defined $event->{comment} and $event->{comment}{entity} eq $entity;
            next unless $eid;
            push @events_data, [$event, $eid];
        }

        if (@events_data) {
            my $db =
                ($entity eq 'quest') ? db->quests :
                ($entity eq 'stencil') ? db->stencils :
                die "internal error - unknown entity $entity";

            my $objects = $db->bulk_get([ map { $_->[1] } @events_data ]);

            for my $data (@events_data) {
                my ($event, $eid) = @$data;
                $event->{$entity} = $objects->{$eid};
                $event->{deleted} = 1 unless $event->{$entity};
            }
        }
    }

    @events = grep { not $_->{deleted} } @events;

    return \@events;
}

sub list {
    my $self = shift;
    my ($params) = validate(\@_, Undef|Dict[
        limit => Optional[Int],
        offset => Optional[Int],
        realm => Optional[Str],
        for => Optional[Str],
        author => Optional[Login],
        type => Optional[Str],
    ]);
    $params //= {};
    $params->{limit} //= 100;
    $params->{offset} //= 0;

    my $search_opt = {};

    if (defined $params->{realm}) {
        $search_opt->{realm} = $params->{realm};
    }
    elsif (defined $params->{for}) {
        my $user = db->users->get_by_login($params->{for}) or die "User '$params->{for}' not found";

        my @subqueries;
        if ($user->{fr}) {
            push @subqueries, { realm => { '$in' => $user->{fr} } };
        }
        $user->{fu} ||= [];
        push @{ $user->{fu} }, $user->{login};
        push @subqueries, { author => { '$in' => $user->{fu} } };

        if (@subqueries) {
            $search_opt->{'$or'} = \@subqueries;
        }
        else {
            $search_opt->{no_such_field} = 'no_such_value';
        }
    }

    $search_opt->{author} = $params->{author} if defined $params->{author};
    $search_opt->{type} = $params->{type} if defined $params->{type};

    my ($limit, $offset) = ($params->{limit}, $params->{offset});

    my $got_more = 1;
    my @result;
    my $trials = 0;

    # expand_events can filter out some events, but we need to return *exactly* $limit queries
    # so we're increasing $offset and fetching more if necessary
    while (@result < $limit and $got_more) {
        my @events = $self->collection->query($search_opt)
            ->sort({ _id => -1 })
            ->limit($limit - scalar @result) # TODO - fetch more than necessary to reduce the chance of follow-up queries
            ->skip($offset)
            ->all;

        $got_more = 0 if @events < $limit;

        $self->_prepare_event($_) for @events;
        $offset += @events;
        @events = @{ $self->expand_events(\@events) };

        push @result, @events; # TODO - filter possible duplicates?

        $trials++;
        if ($trials > 10) {
            $log->warn('events->list tried to refetch events too many times');
            last;
        }
    }

    return \@result;
}

sub _feed_for_query {
    my $self = shift;
    my ($params) = validate(\@_, Undef|Dict[
        for => Str,
    ]);

    my $query = {};
    {
        my $user = db->users->get_by_login($params->{for}) or die "User '$params->{for}' not found";

        my @subqueries;
        if ($user->{fr}) {
            push @subqueries, { realm => { '$in' => $user->{fr} } };
        }
        $user->{fu} ||= [];
        push @{ $user->{fu} }, $user->{login};
        push @subqueries, { team => { '$in' => $user->{fu} } };
        push @subqueries, { author => { '$in' => $user->{fu} } };
        push @subqueries, { watchers => $user->{login} };

        if (@subqueries) {
            $query->{'$or'} = \@subqueries;
        }
        else {
            $query->{no_such_field} = 'no_such_value';
        }
        $query->{status} = { '$ne' => 'deleted' };
    }
    return $query;
}

sub _feed_realm_query {
    my $self = shift;
    my ($params) = validate(\@_, Undef|Dict[
        realm => Realm,
    ]);

    my $query = {};
    $query->{realm} = $params->{realm};
    $query->{status} = { '$ne' => 'deleted' };
    return $query;

}

sub feed {
    my $self = shift;
    my ($params) = validate(\@_, Undef|Dict[
        limit => Optional[Int],
        offset => Optional[Int],
        for => Optional[Str],
        realm => Optional[Realm],
    ]);
    $params->{limit} //= 30;
    $params->{sort} = 'bump';

    my $query;
    $query = $self->_feed_for_query({ for => $params->{for} }) if defined $params->{for};
    $query = $self->_feed_realm_query({ realm => $params->{realm} }) if defined $params->{realm};
    die "no for and no realm" unless $query;
    my $cursor = Play::Mongo->db->get_collection('posts')->find($query);

    $cursor = $cursor->limit($params->{limit});
    $cursor = $cursor->skip($params->{offset}) if $params->{offset};
    $cursor = $cursor->sort({ bump => -1 });
    my @posts = $cursor->all;

    $_ = db->quests->prepare($_) for grep { $_->{entity} eq 'quest' } @posts;
    $_ = db->stencils->prepare($_) for grep { $_->{entity} eq 'stencil' } @posts;
    db->stencils->_fill_quests($_) for grep { $_->{entity} eq 'stencil' } @posts;

    my @items = map {
        { post => $_ }
    } @posts;

    @items = sort {
        ($b->{post}{bump} || 0)
        <=>
        ($a->{post}{bump} || 0)
    } @items;

    for my $item (@items) {
        $item->{comments} = db->comments->list($item->{post}{entity}, $item->{post}{_id}); # TODO - slow, optimize
    }
    return \@items;
}

1;
