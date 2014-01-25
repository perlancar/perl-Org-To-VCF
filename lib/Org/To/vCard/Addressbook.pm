package Org::To::vCard::Addressbook;

use 5.010001;
use Log::Any '$log';

use vars qw($VERSION);

use File::Slurp;
use Org::Document;
use Org::Dump qw();

use Moo;
use experimental 'smartmatch';
extends 'Org::To::Base';

# VERSION

require Exporter;
our @ISA;
push @ISA,       qw(Exporter);
our @EXPORT_OK = qw(org_to_vcard_addressbook);

our %SPEC;
$SPEC{org_to_vcard_addressbook} = {
    summary => 'Export contacts in Org document to VCF (vCard addressbook)',
    args => {
        source_file => ['str' => {
            summary => 'Source Org file to export',
        }],
        source_str => ['str' => {
            summary => 'Alternatively you can specify Org string directly',
        }],
        target_file => ['str' => {
            summary => 'VCF file to write to',
            description => <<'_',

If not specified, VCF output string will be returned instead.

_
        }],
        include_tags => ['array' => {
            of => 'str*',
            summary => 'Include trees that carry one of these tags',
            description => <<'_',

Works like Org's 'org-export-select-tags' variable. If the whole document
doesn't have any of these tags, then the whole document will be exported.
Otherwise, trees that do not carry one of these tags will be excluded. If a
selected tree is a subtree, the heading hierarchy above it will also be selected
for export, but not the text below those headings.

_
        }],
        exclude_tags => ['array' => {
            of => 'str*',
            summary => 'Exclude trees that carry one of these tags',
            description => <<'_',

If the whole document doesn't have any of these tags, then the whole document
will be exported. Otherwise, trees that do not carry one of these tags will be
excluded. If a selected tree is a subtree, the heading hierarchy above it will
also be selected for export, but not the text below those headings.

exclude_tags is evaluated after include_tags.

_
        }],
    }
};
sub org_to_vcard_addressbook {
    my %args = @_;

    my $doc;
    if ($args{source_file}) {
        $doc = Org::Document->new(from_string =>
                                      scalar read_file($args{source_file}));
    } elsif (defined($args{source_str})) {
        $doc = Org::Document->new(from_string => $args{source_str});
    } else {
        return [400, "Please specify source_file/source_str"];
    }

    my $obj = __PACKAGE__->new(
        include_tags => $args{include_tags},
        exclude_tags => $args{exclude_tags},
    );

    my $vcf = $obj->export($doc);
    #$log->tracef("vcf = %s", $vcf);
    if ($args{target_file}) {
        write_file($args{target_file}, $vcf);
        return [200, "OK"];
    } else {
        return [200, "OK", $vcf];
    }
}

sub _clean_field {
    my ($self, $str) = @_;
    $str =~ s/\s*#.+//g; # strip comments
    $str =~ s/\[\d+-\d+-\d+.*?\]//g; # strip timestamps
    $str =~ s/\A\s+//s; $str =~ s/\s+\z//s; # trim
    $str;
}

sub _parse_field {
    my ($self, $fields, $key, $textval, $vals) = @_;
    $vals = [$vals] unless ref($vals) eq 'ARRAY';
    if ($log->is_trace) {
        $log->tracef("parsing field: key=%s, textval=%s, vals=%s",
                     $key, $textval,
                     [map {Org::Dump::dump_element($_)} @$vals]);
    }
    $key = $self->_clean_field($key);
    $textval = $self->_clean_field($textval);
    if ($key =~ /^((?:full\s?)?name |
                     nama(?:\slengkap)?)$/ix) {
        $fields->{FN} = $textval;
        $log->tracef("found FN field: %s", $textval);
    } elsif ($key =~ /^(birthday |
                          ultah|ulang\stahun|(?:tanggal\s|tgg?l\s)?lahir)$/ix) {
        # find the first timestamp field
        my @ts;
        for (@$vals) {
            $_->walk(sub {
                         push @ts, $_
                             if $_->isa('Org::Element::Timestamp');
                     });
        }
        if (@ts) {
            $fields->{BDAY} = $ts[0]->datetime->ymd;
            $log->tracef("found BDAY field: %s", $fields->{BDAY});
        } else {
            # or from a regex match
            if ($textval =~ /(\d{4}-\d{2}-\d{2})/) {
                $fields->{BDAY} = $1;
                $log->tracef("found BDAY field: %s", $fields->{BDAY});
            }
        }
    }
}

sub export_headline {
    my ($self, $elem) = @_;

    if ($log->is_trace) {
        require String::Escape;
        $log->tracef("exporting headline %s (%s) ...", ref($elem),
                     String::Escape::elide(
                         String::Escape::printable($elem->as_string), 30));
    }

    my $vcards = $self->{_vcards};
    my @subhl = grep {
        $_->isa('Org::Element::Headline') && !$_->is_todo }
        $self->_included_children($elem);

    my $fields = {}; # fields
    $fields->{FN} = $self->_clean_field($elem->title->as_string);

    for my $c (@{ $elem->children // [] }) {
        if ($c->isa('Org::Element::Drawer') && $c->name eq 'PROPERTIES') {
            # search fields in properties drawer
            my $props = $c->properties;
            $self->_parse_field($fields, $_, $props->{$_}) for keys %$props;
        } elsif ($c->isa('Org::Element::List')) {
            # search fields in list items
            for my $c2 (grep {$_->isa('Org::Element::ListItem')}
                            @{ $c->children // [] }) {
                if ($c2->desc_term) {
                    $self->_parse_field($fields,
                                        $c2->desc_term->as_string, # key
                                        $c2->children->[0]->as_string, # textval
                                        $c2->children); # val
                } else {
                    my $val = $c2->as_string;
                    my $key = $1 if $val =~ s/\A\s*[+-]\s+(\S+?):(.+)/$2/;
                    if ($key) {
                        $self->_parse_field($fields,
                                            $key,
                                            $val,
                                            $c2);
                    }
                }
             }
        }
    }

    $log->tracef("fields: %s", $fields);

    $self->export_headline($_) for @subhl;
}

sub export_elements {
    my ($self, @elems) = @_;

    $self->{_vcards} //= [];

  ELEM:
    for my $elem (@elems) {
        if ($elem->isa('Org::Element::Headline')) {
            $self->export_headline($elem);
        } elsif ($elem->isa('Org::Document')) {
            $self->export_elements(@{ $elem->children });
        } else {
            # ignore other elements
        }
    }
}

1;
# ABSTRACT: Export contacts in Org document to VCF (vCard addressbook)

=for Pod::Coverage ^(vcf|export|export_.+)$

=head1 SYNOPSIS

 use Org::To::vCard::Addressbook qw(org_to_vcard_addressbook);

 my $res = org_to_vcard_addressbook(
     source_file   => 'addressbook.org', # or source_str
     #target_file  => 'addressbook.vcf', # defaults return the VCF in $res->[2]
     #include_tags => [...], # default exports all tags
     #exclude_tags => [...], # behavior mimics emacs's include/exclude rule
 );
 die "Failed" unless $res->[0] == 200;


=head1 DESCRIPTION

Export contacts in Org document to VCF (vCard addressbook).

My use case: I maintain my addressbook in an Org document C<addressbook.org>
which I regularly export to VCF and then import to Android phones.

How contacts are found in an Org document: each contact is written in an Org
headline (of whatever level), e.g.:

 ** dad # [2014-01-25 Sat]  :remind_anniv:
 - fullname :: frasier crane
 - birthday :: [1900-01-02 ]
 - cell :: 0811 000 0001

Todo items (headline with todo labels) are currently excluded.

Contact fields are searched in list items. Currently Indonesian and English
phrases are supported. If name field is not found, the title of the headline is
used. I use timestamps a lot, so currently timestamps are stripped from headline
titles.

Perl-style comments (with C<#> to the end of the line) are allowed.

Org-contacts format is also supported, where fields are stored in a properties
drawer:

 * Friends
 ** Dave Null
 :PROPERTIES:
 :EMAIL: dave@null.com
 :END:
 This is one of my friend.
 *** TODO Call him for the party


=head1 SEE ALSO

For more information about Org document format, visit http://orgmode.org/

L<Org::Parser>

L<Text::vCard>

Org-contacts: http://julien.danjou.info/projects/emacs-packages#org-contacts

=cut
