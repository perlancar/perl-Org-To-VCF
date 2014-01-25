#!perl

use 5.010;
use strict;
use warnings;

use Org::To::vCard::Addressbook qw(org_to_vcard_addressbook);
use Test::Differences;
use Test::More 0.98;

sub test_to_vcard_addressbook {
    my %args = @_;

    subtest $args{name} => sub {
        my $res;
        eval {
            $res = org_to_vcard_addressbook(%{$args{args}});
        };
        my $eval_err = $@;

        if ($args{dies}) {
            ok($eval_err, "dies");
            return;
        } else {
            ok(!$eval_err, "doesn't die") or diag("died with msg $eval_err");
        }

        if ($args{status}) {
            is($res->[0], $args{status}, "status");
        }

        if ($args{result}) {
            my $vcf = $res->[2];
            #$vcf =~ s/<!-- .* -->\n//sg;
            eq_or_diff($vcf, $args{result}, "result");
        }

        if ($args{posttest}) {
            $args{posttest}->(result=>$res);
        }
    };
}

1;
