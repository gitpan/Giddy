
use strict;
use warnings;

BEGIN { require 5.008; }

use ExtUtils::MakeMaker 6.31;



my %WriteMakefileArgs = (
  'ABSTRACT' => 'Schema-less, versioned media/document database based on Git.',
  'AUTHOR' => 'Ido Perlmuter <ido@ido50.net>',
  'BUILD_REQUIRES' => {
    'File::Temp' => '0',
    'Test::Git' => '0',
    'Test::More' => '0',
    'utf8' => '0'
  },
  'CONFIGURE_REQUIRES' => {
    'ExtUtils::MakeMaker' => '6.31'
  },
  'DISTNAME' => 'Giddy',
  'EXE_FILES' => [],
  'LICENSE' => 'perl',
  'NAME' => 'Giddy',
  'PREREQ_PM' => {
    'Any::Moose' => '0',
    'Carp' => '0',
    'Data::Compare' => '0',
    'DateTime::Format::W3CDTF' => '0',
    'Encode' => '0',
    'File::Path' => '0',
    'Git::Repository' => '1.18',
    'Git::Repository::Log::Iterator' => '0',
    'IO::File' => '0',
    'Tie::IxHash' => '0',
    'Try::Tiny' => '0',
    'YAML::XS' => '0',
    'namespace::autoclean' => '0'
  },
  'VERSION' => '0.013_001',
  'test' => {
    'TESTS' => 't/*.t'
  }
);


unless ( eval { ExtUtils::MakeMaker->VERSION(6.56) } ) {
  my $br = delete $WriteMakefileArgs{BUILD_REQUIRES};
  my $pp = $WriteMakefileArgs{PREREQ_PM};
  for my $mod ( keys %$br ) {
    if ( exists $pp->{$mod} ) {
      $pp->{$mod} = $br->{$mod} if $br->{$mod} > $pp->{$mod};
    }
    else {
      $pp->{$mod} = $br->{$mod};
    }
  }
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
  unless eval { ExtUtils::MakeMaker->VERSION(6.52) };

WriteMakefile(%WriteMakefileArgs);



