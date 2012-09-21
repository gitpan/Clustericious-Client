#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

package Baker;

use Clustericious::Client;

route 'roll' => '/it';
route 'bake' => '/it/please';

route_doc 'put'  => "Put the bread in the oven";
route_doc 'roll' => "Roll the bread";
route_doc 'eat'  => "Eat the bread";

route_meta 'bake' => { temperature => "hot" };
route_args 'put' => [
        { name => 'where',                  type => '=s', required => 1, doc => 'where to bake the bread' },
        { name => 'for',                    type => '=s', required => 1, doc => 'for whom to bake the bread' },
        { name => 'when',                   type => '=s', required => 0, doc => 'when to bake the bread' },
        { name => 'dry_run',    alt => 'n', type => '',   required => 0, },
        { name => 'temperature',            type => ':i', required => 0, }
    ];
route_args 'eat' => [
        { name => 'food', type => "=s", preprocess => "yamldoc", doc => "what food to eat" },
    ];
route_args 'fry' => [
    { name => 'dry_run' },
    { name => 'what', type => '=s' },
    { name => 'things', type => '=s', preprocess => 'list' },
];

our $argsWeGot;
sub put {
    my $self = shift;
    my %args = @_;
    $argsWeGot = [ got => \%args ];
    return [ got => \%args ];
}
sub eat {
    my $self = shift;
    my %args = @_;
    $argsWeGot = [ got => \%args ];
    return [ got => \%args ];
}
sub fry {
    my $self = shift;
    my %args = @_;
    $argsWeGot = [ got => \%args ];
    return [ got => \%args ];
}

package main;
use Log::Log4perl qw(:easy);
use YAML::XS qw/Load Dump/;
use Clustericious::Client::Command;

# Hide messages during tests
Log::Log4perl->easy_init({ level => $FATAL,
                           layout => "",
                           stderr => 0 });
$Clustericious::Client::Command::TESTING=1; # suppress output

my $client = Baker->new(server_url => 'http://127.0.0.1');

is($client->meta_for("roll")->doc, "Roll the bread", "Set metadata");
is($client->meta_for("bake")->get("temperature"), "hot", "Set metadata");

ok $client->can('roll'), 'can roll';
ok $client->can('bake'), 'can bake';
ok $client->can('put'),  'can put';

my $ret;

$ret = $client->put(where => "in the oven", for => "baby and me");
is_deeply($ret, [ got => {where => "in the oven", for => "baby and me"}], 'got args back' );

Clustericious::Client::Command->run( $client, ( "put", "--where", 'in the oven', "--for=baby_and_me" ) );
is_deeply $argsWeGot, [got => { where => 'in the oven', for => "baby_and_me" }];

{
    local $SIG{__WARN__} = sub {}; # no stderr messages
    # missing arg
    eval { Clustericious::Client::Command->run($client, put => '--where' => 'there' ); };
    ok $@, "exception for missing arg";
    like $@, qr/required/, 'message has required';

    # extra arg
    eval { Clustericious::Client::Command->run($client, put => '--baby' => 'there' ); };
    ok $@, "exception for invalid option";
    like $@, qr/invalid/i, 'message has invalid';
}

my $struct = { some => [ deep => struct => { here => 12 } ] };
ok $client->eat(food => $struct);
is_deeply $argsWeGot, [ got => {food => $struct}], "struct sent as a param" or diag explain $argsWeGot;
undef $argsWeGot;

#ok $client->eat(food => Dump($struct));
#is_deeply $argsWeGot, [ got => { food => $struct}], "struct sent as yaml";
#undef $argsWeGot;

my $tmp = File::Temp->new;
print $tmp Dump($struct);
close $tmp;

#ok $client->eat(food => "$tmp");
#is_deeply $argsWeGot, [ got => { food => $struct}], "struct sent as filename";
#undef $argsWeGot;

Clustericious::Client::Command->run($client, eat => "--food" => "$tmp");
is_deeply $argsWeGot, [ got => { food => $struct}], "struct sent as filename to command";
undef $argsWeGot;

# Boolean arg
$tmp = File::Temp->new;
print $tmp join "\n", qw/a b c/;
close $tmp;
Clustericious::Client::Command->run($client, fry => '--dry_run', '--what' => 'bread', '--things' => "$tmp" );
is_deeply $argsWeGot, [ got => { what => 'bread', dry_run => 1, things => [qw/a b c/] } ];
undef $argsWeGot;

$client->fry(things => [qw/a b c/]);
is_deeply($argsWeGot, [ got => { things => [qw/a b c/] }], "got arrayref for list");

done_testing();

1;
