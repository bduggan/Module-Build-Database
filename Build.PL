use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name         => 'Module::Build::Database::PostgreSQL',
    license             => 'perl',
    dist_author         => q{Brian Duggan <brian.duggan@nasa.gov>},
    dist_version_from   => 'lib/Module/Build/Database.pm',
    build_requires => {
        'Test::More' => 0,
    },
    add_to_cleanup      => [ 'Module-Build-Database-*' ],
    create_makefile_pl => 'traditional',
);

$builder->create_build_script();
