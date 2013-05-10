#!/usr/bin/env perl

use strict;
use warnings;

use Module::Build;

my $build = Module::Build->new(
    module_name => 'Clustericious::Client',
    dist_version_from => 'lib/Clustericious/Client.pm',
    dist_author => 'Curt Tilmes <Curt.Tilmes@nasa.gov>',
    requires => {
        'Mojolicious'                  => '1.65',
          'Clustericious::Config'      => '0.01',
          'Clustericious::Log'         => 0,
          'Log::Log4perl::CommandLine' => 0,
          'MojoX::Log::Log4perl'       => 0,
          'JSON::XS'                   => 0,
          'File::Temp'                 => 0,
          'DateTime::Format::ISO8601'  => 0,
          'DateTime::Format::DateParse'=> 0,
          'Data::Rmap'                 => 0,
          'Term::Prompt'               => 0,
    },
    add_to_cleanup      => [ 'Clustericious-Client*' ],
    meta_add => { no_index => { directory => [ 'util' ], } },
)->create_build_script;
