#!perl

use 5.010;
use strict;
use warnings;

use FindBin '$Bin';
use lib $Bin, "$Bin/t";

use File::Slurp;
use Test::More 0.96;
require "testlib.pl";

test_to_vcf(
    name => 'example.org',
    args => {
        source_file=>"$Bin/data/example.org",
    },
    status => 200,
    result => scalar read_file("$Bin/data/example.vcf"),
);

done_testing();
