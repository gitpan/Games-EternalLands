#!/usr/bin/perl -w

use strict;
use Games::EternalLands::Bot;
use Data::Dumper;
use Games::EternalLands::Constants qw(%ClientCommands %ClientCommandsByID %ActorCommandsByID $DEBUG_TYPES);


# You will need to change these variables to the correct ones for
# your character
my $SERVER = "eternal-lands.network-studio.com";
my $PORT   = "2001";
my $ADMINS = "";
my $OWNER  = "";
my $USER   = undef;
my $PASS   = undef;
my $SLEEP  = 2;

defined($USER) || die "USER must be set";
defined($PASS) || die "PASS must be set";

# If you want to run this bot, define SERVER and PORT variable to be
# value for the Test Server and comment out the line below
die "You MUST NOT run this bot on the real server, you will be banned";

my %canHunt = (
    'rabbit' => 10,
    'rat' => 17,
#    'beaver' => 25,
#    'deer' => 100,
#    'brownie' => 100,
);

my %Locations = (
    'Docks'  => [ 26, 33],
    'Fire'   => [109,139],
    'Wraith' => [159,153],
    'Woods'  => [152,112],
    'Food'   => [74,  80],
    'Beach'  => [169, 50],
);

my @sellStuff = ('MOVETO 66,132','USE_MAP_OBJECT 72','MOVETO 26,24',
                  'TOUCHPLAYER 3192',
                  'MOVETO 20,13','USE_MAP_OBJECT 107');
my @mission = ();

sub AmI
{
   my $action = shift;
   foreach my $mission (@_) {
       if ($action =~ m/^$mission/) {
           return 1;
       }
   }
   return 0;
}

sub distanceTo
{

    my $self = shift;

    my $me = $self->{'actorsByID'}->{$self->{'my_id'}};
    my $x1 = $me->{'xpos'};
    my $y1 = $me->{'ypos'};

    my ($x2,$y2);
    if ($#_ eq 0) {
        my $other = $self->{'actorsByID'}->{$_[0]};
        $x2 = $other->{'xpos'};
        $y2 = $other->{'ypos'};
    }
    else {
        $x2 = shift;
        $y2 = shift;
    }
    my $x = $x1-$x2;
    my $y = $y1-$y2;

    return sqrt($x*$x+$y*$y);
}

sub eatSomething
{
    my $self = shift;

    my $bread = $self->{'invByName'}->{'bread'};
    if (!defined($bread)) {
        $self->Log("I have no bread");
#        !AmI('GETBAGS',@mission) && unshift(@mission,'GETBAGS');
        return undef;
    }
    if ($bread->{'quantity'} < 3) {
#        !AmI('GETBAGS',@mission) && unshift(@mission,'GETBAGS');
    }
    if ($self->{'lastEat'}+60 < time()) {
        $self->Log("Eating");
        $self->send('USE_INVENTORY_ITEM',pack('v',$bread->{'pos'}));
        $self->{'lastEat'} = time();
    }
    return $bread;
}

my $bot = Games::EternalLands::Bot->new(
              -server=>$SERVER, -port=>$PORT,
              -mapDir=>'/home/franc/el/',
              -owner=> $OWNER,
              -admins=>$ADMINS, -msgInterval=>15,
              -sellingFile=>'selling.yaml',
              -buyingFile=>'buying.yaml',
              -helpFile=>'help.txt',-adminhelpFile=>'adminhelp.txt',
          );

sub nearestBag($)
{
    my $bot     = shift;
    my $closest = undef;
    my $dist    = 100000;

    foreach my $bagID (keys %{$bot->{'bagsByID'}}) {
        my $bag = $bot->{'bagsByID'}->{$bagID};
        if (!defined($bag->{'lookedAt'})) {
            my $d = $bot->distanceTo($bag->{'bagX'},$bag->{'bagY'});
            if ($d < $dist) {
                $dist = $d;
                $closest = $bag;
            }
        }
    }
    return ($closest,$dist);
}

sub inspectBag
{
    my $bot     = shift;
    my ($bagID) = @_;

    my %pickUp = (
        'bread' => 3,
        'gold coins' => 10000,
        'raw meat' => 10000,
        'brown rabbit fur' => 10000,
    );

    my $items = $bot->{'bagsByID'}->{$bagID}->{'items'};
    if (defined($items)) {
        my @get = ();
        my $complete = 1;
        foreach my $pos (keys %$items) {
            my $name = $items->{$pos}->{'name'};
            if (defined($name)) {
                $name = lc($name);
                if (defined($pickUp{$name})) {
                    $bot->Log("Picking up $name");
                    push(@get,$items->{$pos});
                }
            }
            else {
                $complete = 0;
            }
        }
        if ($complete) {
            foreach my $item (@get) {
                my $pos  = $item->{'pos'};
                my $qty  = $item->{'quantity'};
                $bot->send('PICK_UP_ITEM',pack('CV',$pos,$qty));
            }
        }
        return $complete;
    }
    return 0;
}

sub getBags
{
    my $bot = shift;

    my ($bag,$dist) = nearestBag($bot);
    if (defined($bag)) {
        if ($dist == 0) {
            $bag->{'lookedAt'} = 1;
            $bot->openBag($bag->{'bagID'});
            return ('INSPECTBAG '.$bag->{'bagID'});
        }
        else {
            $bot->moveTo($bag->{'bagX'},$bag->{'bagY'});
            return("MOVETO $bag->{'bagX'},$bag->{'bagY'}");
        }
    }
    return ();
}

sub hunt
{
    my $bot = shift;

    my $close = 10000;
    my $hunt  = undef;
    my $actors = $bot->{'actorsByID'};
    my $me = $actors->{$bot->{'my_id'}};
    my @mp = $bot->getStat('mp');
    foreach my $id (keys %{$actors}) {
        if (defined($actors->{$id}->{'dead'})) {
            next;
        }
        my $name = lc($actors->{$id}->{'name'});
        my $canHunt = $canHunt{$name};
        my $d = $bot->distanceTo($actors->{$id}->{'xpos'},$actors->{$id}->{'ypos'});
        if (defined($canHunt) and ($canHunt <= $mp[0])) {
            if ($d < $close) {
                $close = $d;
                $hunt = $id;
            }
        }
    }
    if (defined($hunt)) {
        return ($actors->{$hunt},$close);
    }
    return (undef,undef);
}

sub printHunted
{
    my ($actor) = @_;

    print STDERR "$actor->{'name'} at ($actor->{'xpos'},$actor->{'ypos'})\n";
}


sub randomLocation
{
    my $bot = shift;
    my @Locs = (keys %Locations);
    my $i = int(rand($#Locs+1));
    my $loc = $Locs[$i];
    my $newLoc = $Locations{$loc};
    $bot->Log("Moving to $loc($newLoc->[0],$newLoc->[1])");
    return ($newLoc->[0],$newLoc->[1]);
}

$bot->{'lastEat'} = 0;
while(1) {
    $bot->connect();
    if ($bot->{'connected'}) {
        $bot->login($USER,$PASS) || die "failed to log in !";
        $bot->Say("#jc 3");
        $bot->{'lastEat'} = time();
#$bot->setDebug($DEBUG_TYPES);
        my ($lastX,$lastY) = (-1,-1);
        my $lastMove = time();
        my ($ret,$type,$len,$packet);
        while($bot->{'loggedIn'}) {
            my ($typeStr,$ret)      = (undef,undef);
            ($type,$len,$packet) = $bot->NextPacket();
            if (defined($type)) {
                $ret = $bot->Dispatch($type,$len,$packet);
                $typeStr = $ClientCommandsByID{$type};
            }
            if ($typeStr eq "NPC_OPTIONS_LIST") {
#print STDERR "RET=",Dumper($ret);
            }

            my $now = time();
            my $me  = $bot->{'actorsByID'}->{$bot->{'my_id'}};
            if (!defined($me)) {
                next;
            }
            my @food = $bot->getStat('food');

            if ($lastX != $me->{'xpos'} or $lastY != $me->{'ypos'}) {
                ($lastX,$lastY) = ($me->{'xpos'},$me->{'ypos'});
                $lastMove = $now;
            }
            if (($food[0] < 35) &&  ($bot->{'lastEat'}+60 < time())) {
                my $bread = eatSomething($bot);
            }
            if ($#mission == -1) {
                unshift(@mission, 'HUNT');
            }
#$bot->Log('['.join('][',@mission).']');
            if ($mission[0] =~ /^WAITTILL (\d+)/) {
                ($now > $1) && shift(@mission);
            }
            elsif ($mission[0] eq 'HUNT') {
                my ($hunt,$dist) = hunt($bot);
                if (defined($hunt)) {
                    if ($dist == 0) {  # We killed something ;-)
                        $hunt->{'dead'} = 1;
                        unshift(@mission, 'GETBAGS');
                    }
                    elsif ($dist < 6) {
                        $bot->send('ATTACK_SOMEONE',pack('L',$hunt->{'id'})); }
                    else {
                        $bot->moveTo($hunt->{'xpos'},$hunt->{'ypos'});
                    }
                }
                elsif ($now - $lastMove > 15) {
                    my ($newX,$newY) = randomLocation($bot);
                    $bot->moveTo($newX,$newY);
                    $lastMove = time();
                }
            }
            elsif ($mission[0] eq 'GETBAGS') {
                my @next = getBags($bot);
                unshift(@mission, @next);
            }
            elsif ($mission[0] =~ 'USE_MAP_OBJECT (\d+)') {
                $bot->handleUseMapObject($1);
                my $wait = $now+10;
                shift(@mission);
                unshift(@mission, "WAITTILL $wait");
            }
            elsif ($mission[0] =~ m/^MOVETO (\d+)\,(\d+)/) {
                my ($toX,$toY) = ($1,$2);
                if ($me->{'xpos'} == $toX and $me->{'ypos'} == $toY) {
                    shift(@mission);
                }
                elsif (time() - $lastMove > 5) {
                    $bot->moveTo($toX,$toY);
                }
            }
            elsif ($mission[0] =~ m/^TOUCHPLAYER (\d+)/) {
                $bot->handleTouchPlayer($1);
                shift(@mission);
            }
            elsif ($mission[0] =~ m/^INSPECTBAG (.*)/) {
                my $done = inspectBag($bot,$1);
                if ($done) {
                    shift(@mission); # remobe the INSPECTBAG
                    shift(@mission); # remove the GETBAGS
                }
            }
        }
        $bot->disconnect();
    }
    sleep $SLEEP;
    if ($SLEEP < 30*60) {
        $SLEEP *= 2;
    }
}
