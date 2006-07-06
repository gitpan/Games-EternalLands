
package Games::EternalLands::Map;

use strict;
use Data::Dumper;
use AI::Pathfinding::AStar;
use vars qw(@ISA);

@ISA = qw(AI::Pathfinding::AStar);

sub distance($$$$$)
{
    my $self = shift;

    my ($x1,$y1,$x2,$y2) = @_;

    my $x = ($x1-$x2);
    my $y = ($y1-$y2);

    return sqrt($x*$x+$y*$y);
}

sub calcH($$$)
{
    my $self = shift;

    my ($x1,$y1,$to) = @_;

    my ($x2,$y2)  = split(',',$to);
    my $x = ($x1-$x2);
    my $y = ($y1-$y2);

    return ($x*$x+$y*$y);
}

sub getSurrounding
{
    my $self = shift;
    my ($from,$to) = @_;


    my ($xPos,$yPos) = split(",",$from);

    my @surrounding = ();

    my $i = $yPos*$self->{'wdth'}*6+$xPos;
    my $crntHeight = $self->{'hMap'}->[$i];
    for(my $x=$xPos-1; $x<=$xPos+1; $x++) {
        for(my $y=$yPos-1; $y<=$yPos+1; $y++) {
            ($x != $xPos || $y != $yPos) || next;
            ($x > 0 and $x < $self->{'wdth'}*6) || next;
            ($y > 0 and $y < $self->{'hght'}*6) || next;
            $i = $y*$self->{'wdth'}*6+$x;
            my $diff = $crntHeight - $self->{'hMap'}->[$i];
            if ($diff >= -1 and $diff <= 1) {
                my $h = $self->calcH($x,$y,$to);
                push(@surrounding,[$x.",".$y,1,$h]);
            }
        }
    }

    return \@surrounding;
}

sub new
{
    my $class = shift;
    my $self  = {};
    bless($self, $class);

    my ($fname) = @_;
    my ($mapHdr,$tileMap,$hghtMapBuf);
    my $MAP_HDR_SZ = 124;

    if (!open(FP,$_[0])) {
        print STDERR "Could not open map '$fname': $!\n";
        return undef;
    }
    if (read(FP,$mapHdr,$MAP_HDR_SZ) != $MAP_HDR_SZ) {
        print STDERR "Could not read map header: $!\n";
    }
    if (substr($mapHdr,0,4) ne "elmf") {
        print STDERR "Inavlid magic number for '$fname'\n";
    }
    my $wdth = unpack('l', substr($mapHdr,4,4));
    my $hght = unpack('l', substr($mapHdr,8,4));

    if (read(FP,$tileMap,$wdth*$hght) != $wdth*$hght) { # don't need this data
        print STDERR "Could not read tileMap for '$fname'\n";
        return undef;
    }
    $tileMap = undef; # free the storage we don't need it

    my $hghtMapSize = $wdth*$hght*6*6;
    if (read(FP,$hghtMapBuf,$hghtMapSize) != $hghtMapSize) {
        print STDERR "Could not read Height Map for '$fname'\n";
        return undef;
    }

    my @heightMap;
    for(my $x=0; $x<$wdth*6; $x++) {
        for(my $y=0; $y<$hght*6; $y++) {
            my $i = $y*$wdth*6+$x;
            $heightMap[$i] = unpack('C',substr($hghtMapBuf,$i,1));
        }
    }

    $self->{'wdth'} = $wdth;
    $self->{'hght'} = $hght;
    $self->{'hMap'} = \@heightMap;

    return $self;
}

return 1;
