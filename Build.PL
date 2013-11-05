
use strict;
use warnings;

use Module::Build 0.3601;


my %module_build_args = (
  "build_requires" => {
    "Log::Log4perl::CommandLine" => 0,
    "Module::Build" => "0.3601",
    "Test::More" => 0
  },
  "configure_requires" => {
    "Module::Build" => "0.3601"
  },
  "dist_abstract" => "Construct command line and perl clients for RESTful services.",
  "dist_author" => [
    "Graham Ollis <plicease\@cpan.org>"
  ],
  "dist_name" => "Clustericious-Client",
  "dist_version" => "0.85",
  "license" => "perl",
  "module_name" => "Clustericious::Client",
  "recommends" => {
    "EV" => 0
  },
  "recursive_test_files" => 1,
  "requires" => {
    "Clustericious::Config" => "0.01",
    "Clustericious::Log" => 0,
    "Data::Rmap" => 0,
    "Date::Parse" => 0,
    "DateTime" => 0,
    "DateTime::Format::DateParse" => 0,
    "DateTime::Format::ISO8601" => 0,
    "JSON::XS" => 0,
    "Log::Log4perl" => 0,
    "Log::Log4perl::CommandLine" => 0,
    "MojoX::Log::Log4perl" => 0,
    "Mojolicious" => "1.65",
    "Term::Prompt" => 0,
    "YAML::XS" => 0
  },
  "script_files" => []
);


my $build = Module::Build->new(%module_build_args);

$build->create_build_script;
