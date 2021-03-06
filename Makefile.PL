use strict;
use warnings;
use inc::Module::Install;

name 'MongoDB';
perl_version '5.8.4';
author 'Florian Ragwitz <rafl@debian.org>';
author 'Kristina Chodorow <kristina@mongodb.com>';
author 'Mike Friedman <mike.friedman@mongodb.com>';
author 'David.Golden <david.golden@mongodb.com>';
license 'Apache';
all_from 'lib/MongoDB.pm';

requires 'Authen::SCRAM::Client' => '0.003';
requires 'Carp';
requires 'DateTime' => '0.78';
requires 'Digest::MD5';
requires 'Encode';
requires 'IO::File';
requires 'IO::Socket';
requires 'MIME::Base64';
requires 'Moose' => '2';
requires 'Moose::Util::TypeConstraints' => '2';
requires 'Safe::Isa';
requires 'Scalar::Util';
requires 'Syntax::Keyword::Junction';
requires 'Throwable';
requires 'Tie::IxHash';
requires 'Time::HiRes';
requires 'Try::Tiny';
requires 'Type::Tiny' => '1';
requires 'boolean';
requires 'namespace::clean';
requires 'version';

test_requires 'Data::Dumper';
test_requires 'DateTime::Tiny';
test_requires 'Devel::Peek';
test_requires 'File::Temp' => '0.17';
test_requires 'FileHandle';
test_requires 'JSON::MaybeXS' => '1.002005';
test_requires 'Path::Tiny' => '0.054';
test_requires 'Test::Deep' => 0.111;
test_requires 'Test::Fatal';
test_requires 'Test::More' => 0.96;
test_requires 'Test::Warn';
test_requires 'bigint';

mongo;

repository 'git://github.com/mongodb/mongo-perl-driver.git';

tests_recursive;

WriteAll;

package MY;

use Config;

# Because we keep our XS in an 'xs' subdirectory, this ensures the object files
# are built there, too, which is needed for linking to work.
# Originally added by Florian Ragwitz, based on Glib::MakeHelper. See
# https://metacpan.org/source/XAOC/Glib-1.304/lib/Glib/MakeHelper.pm#L553
sub const_cccmd {
    my $inherited = shift->SUPER::const_cccmd(@_);
    return '' unless $inherited;

    if ($Config{cc} =~ /^cl\b/) {
        $inherited .= ' /Fo$@';
    }
    else {
        $inherited .= ' -o $@';
    }
    return $inherited;
}
