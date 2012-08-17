package Clustericious::Client;

use strict; no strict 'refs';
use warnings;

our $VERSION = '0.64';

=head1 NAME

Clustericious::Client - Constructor for clients of Clustericious apps.

=head1 SYNOPSIS

 package Foo::Client;

 use Clustericious::Client;

 route 'welcome' => '/';                   # GET /

 route status;                             # GET /status

 route myobj => [ 'MyObject' ];            # GET /myobj

 route something => GET => '/some/';

 route remove => DELETE => '/something/';

 object 'obj';                             # Defaults to /obj

 object 'foo' => '/something/foo';         # Can override the URL

 route status => \"Get the status";        # Scalar refs are documentation

 route_doc status => "Get the status";     # or you can use route_doc

 route_meta status => { auto_failover => 1 } # route_meta sets attributes of routes

 ----------------------------------------------------------------------

 use Foo::Client;

 my $f = Foo::Client->new();
 my $f = Foo::Client->new(server_url => 'http://someurl');
 my $f = Foo::Client->new(app => 'MyApp'); # For testing...

 my $welcome = $f->welcome();              # GET /

 my $status = $f->status();                # GET /status

 my $myobj = $f->myobj('key');             # GET /myobj/key, MyObject->new()

 my $something = $f->something('this');    # GET /some/this

 $f->remove('foo');                        # DELETE /something/foo

 my $obj = $f->obj('this', 27);            # GET /obj/this/27
 # Returns either 'Foo::Client::Obj' or 'Clustericious::Client::Object'

 $f->obj({ set => 'this' });               # POST /obj

 $f->obj('this', 27, { set => 'this' });   # POST /obj/this/27

 $f->obj_delete('this', 27);               # DELETE /obj/this/27

 my $obj = $f->foo('this');                # GET /something/foo/this

=head1 DESCRIPTION

Some very simple helper functions with a clean syntax to build a REST
type client suitable for Clustericious applications.

The builder functions add methods to the client object that translate
into basic REST functions.  All of the 'built' methods return undef on
failure of the REST/HTTP call, and auto-decode the returned body into
a data structure if it is application/json.

Using Clustericious::Client also allows for easy creation of both
perl APIs and command line clients for a L<Clustericious> server.
See L<Clustericious::Client::Command>.

=cut

use Mojo::Base qw/-base/;

use Mojo::UserAgent;
use Mojo::ByteStream qw/b/;
use Mojo::Parameters;
use JSON::XS;
use Clustericious::Config;
use Clustericious::Client::Object;
use Clustericious::Client::Meta;
use Clustericious::Client::Meta::Route;
use MojoX::Log::Log4perl;
use Log::Log4perl qw/:easy/;
use File::Temp;
use Proc::Daemon;

=head1 ATTRIBUTES

This class inherits from L<Mojo::Base>, and handles attributes like
that class.  The following additional attributes are used.

=over

=item C<client>

A client to process the HTTP stuff with.  Defaults to a
L<Mojo::UserAgent>.

=item C<app>

For testing, you can specify a Mojolicious app name.

=item C<server_url>

You can override the URL prefix for the client, otherwise it
will look it up in the config file.

=item C<res>

After an HTTP error, the built methods return undef.  This function
will return the L<Mojo::Message::Response> from the server.

res->code and res->message are the returned HTTP code and message.

=cut

has server_url => '';
has [qw(tx res userinfo client)];
has _remote => ''; # Access via remote()
has _cache => sub { + {} }; # cache of credentials

sub import
{
    my $class = shift;
    my $caller = caller;

    {
    no strict 'refs';
    push @{"${caller}::ISA"}, $class unless $caller->isa($class);
    *{"${caller}::route"} = \&route;
    *{"${caller}::route_meta"} = \&route_meta;
    *{"${caller}::route_doc"} = sub {
        Clustericious::Client::Meta->add_route( $caller, @_ )
    };
    *{"${caller}::object"} = \&object;
    *{"${caller}::import"} = sub {};
    }
}

=back

=head1 METHODS

=over

=item C<new>

 my $f = Foo::Client->new();
 my $f = Foo::Client->new(server_url => 'http://someurl');
 my $f = Foo::Client->new(app => 'MyApp'); # For testing...

If the configuration file has a "url" entry, this will
be used as the default url (first case above).  Additionally,
if the ssh_tunnel key is given in the config file, a tunnel
may be created automatically (and destroyed when the client
is destroyed).  Here's a sample configuration :

   "url" : "http://localhost:12345",
   "ssh_tunnel" : {
        "remote_host" : "omidev",
        "server_host" : "localhost",
        "server_port" : "9014"
    },

This would automatically execute this

    ssh -N -L12345:localhost:9014 omidev

in the background.

=cut

sub new
{
    my $self = shift->SUPER::new(@_);
    my %args = @_;

    if ($self->{app})
    {
        my $app = $self->{app};
        $app = $app->new() unless ref($app);
        my $client = Mojo::UserAgent->new(app => $app)
            or return undef;

        $self->client($client);
    }
    else
    {
        $self->client(Mojo::UserAgent->new);
        if (not length $self->server_url)
        {
            $self->server_url($self->_config->url);
        }
    }

    $self->client->inactivity_timeout($ENV{CLUSTERICIOUS_KEEP_ALIVE_TIMEOUT} || 300);
    if (!$args{server_url} && $self->_config->ssh_tunnel(default => '')) {
        INFO "Found an ssh tunnel for ".(ref $self)." in config file";
        $self->_start_ssh_tunnel;
    }

    return $self;
}

=item tx

The most recent HTTP::Transaction.

=cut

=item userinfo

Credentials currently stored.

=cut

=item remote

Tell the client to use the remote information in the configuration.
For instance, if the config has

 remotes :
    test :
        url: http://foo
    bar :
        url: http://baz
        username : one
        password : two

Then setting remote("test") uses the first
url, and setting remote("bar") uses the
second one.

=cut

sub remote {
    my $self = shift;
    return $self->_remote unless @_ > 0;
    my $remote = shift;
    unless ($remote) { # reset to default
        $self->{_remote} = '';
        $self->server_url($self->_config->url);
        return;
    }
    my $info = $self->_base_config->remotes->$remote;
    TRACE "Using remote url : ".$info->{url};
    $self->server_url($info->{url});
    $self->userinfo('');
    $self->_remote($remote);
}

=item remotes

Return a list of available remotes.

=cut

sub remotes {
    my $self = shift;
    my %found = $self->_base_config->remotes(default => {});
    return keys %found;
}

=item C<login>

Log in to the server.  This will send basic auth info
along with every subsequent request.

    $f->login; # looks for username and password in $app.conf
    $f->login("elmer", "fudd");
    $f->login(username => "elmer", password => "fudd");

=cut

sub login {
    my $self = shift;
    my %args = @_;
    my ($user,$pw) =
           @_==2 ? @_
         : @_    ?  @args{qw/username password/}
         : map $self->_config->$_, qw/username password/;
    $self->userinfo(join ':', $user,$pw);
}

=item C<errorstring>

After an error, this returns an error string made up of the server
error code and message.  (use res->code and res->message to get the
parts)

(e.g. "Error: (500) Internal Server Error")

=cut

sub errorstring
{
    my $self = shift;
    WARN "Missing response in client object" unless $self->res;
    return unless $self->res;
    return if $self->res->code && $self->res->is_status_class(200);
    $self->res->error
      || sprintf( "(%d) %s", $self->res->code, $self->res->message );
}

=back

=head1 FUNCTIONS

=over

=item C<route>

 route 'subname';                    # GET /subname
 route subname => '/url';            # GET /url
 route subname => GET => '/url';     # GET /url
 route subname => POST => '/url';    # POST /url
 route subname => DELETE => '/url';  # DELETE /url
 route subname => ['SomeObjectClass'];
 route subname \"<documentation> <for> <some> <args>";

Makes a method subname() that does the REST action.  Any scalar
arguments are tacked onto the end of the url separated by a slash.
If any argument begins with "--", it and its successor are treated
as part of URL query string (for a GET request).  If any argument
begins with a single "-", it and it successor are treated as HTTP
headers to send (for a GET request).  If you pass a hash
reference, the method changes to POST and the hash is encoded into
the body as application/json.

A hash reference after a POST method becomes headers.

A scalar reference as the final argument adds documentation
about this route which will be displayed by the command-line
client.

=cut

sub route
{
    my $subname = shift;
    my $objclass = ref $_[0] eq 'ARRAY' ? shift->[0] : undef;
    my $doc      = ref $_[-1] eq 'SCALAR' ? ${ pop() } : "";
    my $url      = pop || "/$subname";
    my $method   = shift || 'GET';

    my $client_class = scalar caller();
    my $meta = Clustericious::Client::Meta::Route->new(
            client_class => scalar caller(),
            route_name => $subname
    );

    $meta->set_doc($doc);

    if ($objclass)
    {
        eval "require $objclass";
        if ($@) {
            LOGDIE "Error loading $objclass : $@" unless $@ =~ /Can't locate/i;
        }

        no strict 'refs';
        *{caller() . "::$subname"} =
        sub
        {
            my $self = shift;
            $objclass->new($self->_doit($meta,$method,$url,@_), $self);
        };
    }
    else
    {
        no strict 'refs';
        *{caller() . "::$subname"} = sub { shift->_doit($meta,$method,$url,@_); };
    }

}

=item route_meta

Set metadata attributes for this route.

    route_meta 'bucket_map' => { auto_failover => 1 }
    route_meta 'bucket_map' => { quiet_post => 1 }
    route_meta 'bucket_map' => { skip_existing => 1 }

=cut

sub route_meta {
    my $name = shift;
    my $attrs = shift;
    my $meta = Clustericious::Client::Meta::Route->new(
        client_class => scalar caller(),
        route_name   => $name
    );

    $meta->set($_ => $attrs->{$_}) for keys %$attrs;
}

=item C<object>

 object 'objname';                   # defaults to URL /objname
 object objname => '/some/url';

Creates two methods, one named with the supplied objname() (used for
create, retrieve, update), and one named objname_delete().

Any scalar arguments to the created functions are tacked onto the end
of the url.  Performs a GET by default, but if you pass a hash
reference, the method changes to POST and the hash is encoded into the
body as application/json.

The 'object' routes will automatically look for a class named with the
object name, but upper case first letter and first after any
underscores, which are removed:

 object 'myobj';    Foo::Client::Myobj;
 object 'my_obj';   Foo::Client::MyObj;

If such a class isn't found, object will default to returning a
L<Clustericious::Client::Object>.

=cut

sub object {
    my $objname = shift;
    my $url     = shift || "/$objname";
    my $doc     = ref $_[-1] eq 'SCALAR' ? ${ pop() } : '';
    my $caller  = caller;

    my $objclass = "${caller}::" .
        join('', map { ucfirst } split('_', $objname)); # foo_bar => FooBar

    eval "require $objclass";
    if ($@) {
        LOGDIE "Error loading $objclass : $@" unless $@ =~ /Can't locate/i;
    }

    $objclass = 'Clustericious::Client::Object' unless $objclass->can('new');

    Clustericious::Client::Meta->add_object(scalar caller(),$objname,$doc);

    no strict 'refs';
    *{"${caller}::$objname"} = sub {
        my $self = shift;
        my $meta = Clustericious::Client::Meta::Route->new(
            client_class => $caller,
            route_name   => $objname
        );
        $meta->set( quiet_post => 1 );
        my $data = $self->_doit( $meta, GET => $url, @_ );
        $objclass->new( $data, $self );
    };
    *{"${caller}::${objname}_delete"} = sub {
        my $meta = Clustericious::Client::Meta::Route->new(
            client_class => $caller,
            route_name   => $objname.'_delete',
        );
        shift->_doit( $meta, DELETE => $url, @_ );
    };
    *{"${caller}::${objname}_search"} = sub {
        my $meta = Clustericious::Client::Meta::Route->new(
            client_class => $caller,
            route_name   => $objname.'_search'
        );
        shift->_doit( $meta, POST => "$url/search", @_ );
    };
}

sub _doit {
    my $self = shift;
    my $meta;
    $meta = shift if ref $_[0] eq 'Clustericious::Client::Meta::Route';
    my ($method, $url, @args) = @_;

    my $auto_failover;
    $auto_failover = 1 if $meta && $meta->get('auto_failover');

    $url = $self->server_url . $url if $self->server_url && $url !~ /^http/;
    return undef if $self->server_url eq 'http://0.0.0.0';

    my $cb;
    my $body = '';
    my $headers = {};

    if ($method eq 'POST' && grep /^--/, @args) {
        s/^--// for @args;
        @args = ( { @args } );
    }

    $url = Mojo::URL->new($url) unless ref $url;
    my $parameters = $url->query;
    while (defined(my $arg = shift @args))
    {
        if (ref $arg eq 'HASH') {
            $method = 'POST';
            $parameters->append(skip_existing => 1) if $meta && $meta->get("skip_existing");
            $body = encode_json $arg;
            $headers = { 'Content-Type' => 'application/json' };
        }
        elsif (ref $arg eq 'CODE')
        {
            $cb = $self->_mycallback($arg);
        }
        elsif ($method eq "GET" && $arg =~ s/^--//) {
            my $value = shift @args;
            $parameters->append($arg => $value);
        }
        elsif ($method eq "GET" && $arg =~ s/^-//) {
            # example: $client->esdt(-range => [1 => 100]);
            my $value = shift @args;
            if (ref $value eq 'ARRAY') {
                $value = "items=$value->[0]-$value->[1]";
            }
            $headers->{$arg} = $value;
        }
        elsif ($method eq "POST" && !ref $arg) {
            $body = $arg;
            $headers = shift @args if $args[0] && ref $args[0] eq 'HASH';
        }
        else
        {
            push @{ $url->path->parts }, $arg;
        }
    }
    $url = $url->to_abs unless $url->is_abs;
    WARN "url $url is not absolute" unless $url =~ /^http/i;

    $url->userinfo($self->userinfo) if $self->userinfo;

    DEBUG ( (ref $self)." : $method " ._sanitize_url($url));
    $headers->{Connection} ||= 'Close';
    $headers->{Accept}     ||= 'application/json';
    return $self->client->build_tx($method, $url, $headers, $body, $cb) if $cb;

    my $tx = $self->client->build_tx($method, $url, $headers, $body);

    $tx = $self->client->start($tx);
    my $res = $tx->res;
    $self->res($res);
    $self->tx($tx);

    if (($tx->res->code||0) == 401 && !$url->userinfo && ($self->_has_auth || $self->_can_auth)) {
        DEBUG "received code 401, trying again with credentials";
        my ($realm) = $tx->res->headers->www_authenticate =~ /realm=(.*)$/i;
        my $host = $url->host;
        $self->login( $self->_has_auth ? () : $self->_get_user_pw($host,$realm) );
        return $self->_doit($meta ? $meta : (), @_);
    }

    if ($res->is_status_class(200)) {
        TRACE "Got response : ".$res->to_string;
        my $content_type = $res->headers->content_type || do {
            WARN "No content-type from "._sanitize_url($url);
            "text/plain";
        };
        return $method =~ /HEAD|DELETE/       ? 1
            : $content_type eq 'application/json' ? decode_json($res->body)
            : $res->body;
    }

    # Failed.
    my ($msg,$code) = $tx->error;
    $msg ||= 'unknown error';
    my $s_url = _sanitize_url($url);

    if ($code) {
        if ($code == 404) {
            TRACE "$method $url : $code $msg"
                 unless $ENV{ACPS_SUPPRESS_404}
                     && $url =~ /$ENV{ACPS_SUPPRESS_404}/;
        } else {
            ERROR "Error trying to $method $s_url : $code $msg";
            TRACE "Full error body : ".$res->body if $res->body;
            my $brief = $res->body || '';
            $brief =~ s/\n/ /g;
            ERROR substr($brief,0,200) if $brief;
        }
        # No failover for legitimate status codes.
        return undef;
    }

    unless ($auto_failover) {
        ERROR "Error trying to $method $s_url : $msg";
        ERROR $res->body if $res->body;
        return undef;
    }
    my $failover_urls = $self->_config->failover_urls(default => []);
    unless (@$failover_urls) {
        ERROR $msg;
        return undef;
    }
    INFO "$msg but will try up to ".@$failover_urls." failover urls";
    TRACE "Failover urls : @$failover_urls";
    for my $url (@$failover_urls) {
        DEBUG "Trying $url";
        $self->server_url($url);
        my $got = $self->_doit(@_);
        return $got if $got;
    }

    return undef;
}

sub _mycallback
{
    my $self = shift;
    my $cb = shift;
    sub
    {
        my ($client, $tx) = @_;

        $self->res($tx->res);
        $self->tx($tx);

        if ($tx->res->is_status_class(200))
        {
            my $body = $tx->res->headers->content_type eq 'application/json'
                ? decode_json($tx->res->body) : $tx->res->body;

            $cb->($body ? $body : 1);
        }
        else
        {
            $cb->();
        }
    }
}

sub _sanitize_url {
    # Remove passwords from urls for displaying
    my $url = shift;
    $url = Mojo::URL->new($url) unless ref $url eq "Mojo::URL";
    return $url unless $url->userinfo;
    my $c = $url->clone;
    $c->userinfo("user:*****");
    return $c;
}

sub _appname {
    my $self = shift;
    (my $appname = ref $self) =~ s/:.*$//;
    return $appname;
}

sub _config {
    my $self = shift;
    my $conf = $self->_base_config;
    if (my $remote = $self->_remote) {
        return $conf->remotes->$remote;
    }
    return $conf;
}

sub _base_config {
    # Independent of remotes
    my $self = shift;
    return $self->{_base_config} if defined($self->{_base_config});
    $self->{_base_config} = Clustericious::Config->new($self->_appname);
    return $self->{_base_config};
}

sub _has_auth {
    my $self = shift;
    return 0 unless $self->_config->username(default => '');
    return 0 unless $self->_config->password(default => '');
    return 1;
}

sub _can_auth {
    my $self = shift;
    return -t STDIN ? 1 : 0;
}

sub _get_user_pw  {
    my $self = shift;
    my $host = shift;
    my $realm = shift;
    return @{ $self->_cache->{$host}{$realm} } if exists($self->_cache->{$host}{$realm});
    # "use"ing causes too many warnings; load on demand.
    require IO::Prompt;
    my $user = IO::Prompt::prompt("Username for $realm at $host : ");
    my $pw = IO::Prompt::prompt("Password : ",{-echo=>'*'});
    $self->_cache->{$host}{$realm} = [ $user, $pw ];
    return ($user,$pw);
}

=item meta_for

Get the metadata for a route.

    $client->meta_for('welcome');

Returns a Clustericious::Client::Meta::Route object.

=cut

sub meta_for {
    my $self = shift;
    my $route_name = shift;
    my $meta = Clustericious::Client::Meta::Route->new(
        route_name   => $route_name,
        client_class => ref $self
    );
}

=back

=head1 COMMON ROUTES

These are routes that are automatically supported by all clients.
See L<Clustericious::RouteBuilder::Common>.  Each of these
must also be in L<Clustericious::Client::Meta> for there
to be documentation.

=over

=item version

Retrieve the version on the server.

=cut

sub version {
    my $self = shift;
    my $meta = $self->meta_for("version");
    $meta->set(auto_failover => 1);
    $self->_doit($meta, GET => '/version');
}

=item status

Retrieve the status from the server.

=cut

sub status {
    my $self = shift;
    my $meta = $self->meta_for("status");
    $meta->set(auto_failover => 1);
    $self->_doit($meta, GET => '/status');
}

=item api

Retrieve the API from the server

=cut

sub api {
    my $self = shift;
    my $meta = $self->meta_for("api");
    $meta->set( auto_failover => 1 );
    $self->_doit( $meta, GET => '/api' );
}

=item logtail

Get the last N lines of the server log file.

=cut

sub logtail {
    my $self = shift;
    my $got = $self->_doit(GET => '/log', @_);
    return { text => $got };
}

sub _ssh_pidfile {
    sprintf("%s/%s_acps_ssh.pid",($ENV{TMPDIR} || "/tmp"),shift->_appname);
}

=item ssh_tunnel_is_up

Check to see if an ssh tunnel is alive for the current client.

=cut

sub ssh_tunnel_is_up {
    my $pidfile = shift->_ssh_pidfile;
    if (-e $pidfile) {
        my ($pid) = IO::File->new("<$pidfile")->getlines;
        if ($pid and kill 0, $pid) {
            DEBUG "found running ssh ($pid)";
            return 1;
        }
    }
    return 0;
}

sub _ssh_cmd {
    my $self = shift;
    my $conf = $self->_config->ssh_tunnel;
    my $url = Mojo::URL->new($self->server_url);
    my $cmd = sprintf( "ssh -n -N -L%d:%s:%d %s",
        $url->port,           $conf->{server_host},
        $conf->{server_port}, $conf->{remote_host}
    );
    return $cmd;
}

sub _start_ssh_tunnel {
    my $self = shift;

    return if $self->ssh_tunnel_is_up;

    my $error_file = File::Temp->new();
    my $out_file = File::Temp->new();

    my $cmd = $self->_ssh_cmd;
    INFO "Executing $cmd";
    my $proc = Proc::Daemon->new(
        exec_command => $cmd,
        pid_file     => $self->_ssh_pidfile,
        child_STDERR => $error_file,
        child_STDOUT => $out_file,
        work_dir     => "/tmp"
    );
    my $pid = $proc->Init or do {
        FATAL "Could not start $cmd, see $error_file or $out_file";
        $error_file->unlink_on_destroy(0);
        $out_file->unlink_on_destroy(0);
    };
    sleep 1;
    DEBUG "new ssh pid is $pid";
}

=item stop_ssh_tunnel

Stop any running ssh tunnel for this client.

=cut

sub stop_ssh_tunnel {
    my $self = shift;
    my $proc = Proc::Daemon->new( pid_file => $self->_ssh_pidfile);
    WARN "pid file is ".$self->_ssh_pidfile;
    my $pid = $proc->Status($self->_ssh_pidfile) or do {
        INFO "Could not stop ssh tunnel for ".(ref $self);
        return;
    };
    my $killed = $proc->Kill_Daemon($self->_ssh_pidfile) or do {
        WARN "Could not kill ssh for ".(ref $self);
        return;
    };
    DEBUG "Killed ssh for ".(ref $self)." ($killed)";
    return 1;
}

=back

=head1 ENVIRONMENT

Set ACPS_SUPPRESS_404 to a regular expression in order to
not print messages when a 404 response is returned from urls
matching that regex.

=head1 NOTES

This is a beta release.  The API is subject to changes without notice.

=cut

1;
