#!/usr/bin/perl -w

# make perl hash's from client_serv.h

use strict;
use Data::Dumper;

sub fixname($)
{
    my ($name) = @_;

    $name =~ s/\([^\)]*\)//;
    $name =~ s/\s+/ /g;
    $name =~ s/ /_/g;

    return $name;
}

my $hash;
my $name = "none";

while(<>) {
    if ($_ =~ m/^ \* \\name (.*)\s*/) {
        $name = fixname($1);
    }
    if (substr($_,0,9) eq '/*! @{ */') {
        # ignore
    }
    if (substr($_,0,9) eq '/*! @} */') {
        $name = "none";
    }
    if ($_ =~ m/^\#define (\w*)\s+(\w*)/) {
        $hash->{$name}->{$1} = $2;
    }
}

foreach my $name (keys %$hash) {
    my @idents = (keys %{$hash->{$name}});
    @idents = sort { $hash->{$name}->{$a} <=> $hash->{$name}->{$b}  } @idents;

    print "my \%$name = (\n";
    foreach my $var (@idents) {
        print "    '$var' => chr(",$hash->{$name}->{$var},"),\n";
    }
    print ");\n\n";

    print "my \%$name","ByID = (\n";
    foreach my $var (@idents) {
        print "   chr(",$hash->{$name}->{$var},") => '$var',\n";
    }
    print ");\n\n";
}
