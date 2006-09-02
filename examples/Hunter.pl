#!/usr/bin/perl -w

use strict;
use Games::EternalLands::Bot;
use Data::Dumper;
use Carp;
use Games::EternalLands::Constants qw(:Debug :ActorTypes);

# You will need to change these variables to the correct ones for
# your character
my $SERVER = "eternal-lands.network-studio.com";
my $PORT   = "2001";
my $ADMINS = undef;
my $OWNER  = undef;
my $USER   = undef;
my $PASS   = undef;
my $ELDIR  = "/usr/local/games/el/";
my $SLEEP  = 2;

defined($USER) || die "USER must be set";
defined($PASS) || die "PASS must be set";

# If you want to run this bot, define SERVER and PORT variable to be
# value for the Test Server and comment out the line below
#die "You MUST NOT run this bot on the real server, you will be banned";


my $bot = Games::EternalLands::Bot->new(
              -server=>$SERVER, -port=>$PORT,
              -elDir=>$ELDIR,
              -owner=> $OWNER, -admins=>$ADMINS,
              -knowledgeFile=>'knowledge.yaml',
              -helpFile=>'help.txt',-adminhelpFile=>'adminhelp.txt',
#              -debug=>$DEBUG_TEXT,
#              -debug=>$DEBUG_TYPES,
#              -debug=>$DEBUG_PATH,
#              -debug=>$DEBUG_PACKETS,
          );

$bot->{'canTrade'} = 0;

my %isFood =(
    'cooked meat' => 25,
    'fruits' => 20,
    'vegetables' => 15,
    'bread' => 10,
);

my %canHunt = (
    $brown_rabbit => 10,
    $beaver => 15,
    $brownie => 20,
    $wood_sprite => 25,
    $deer => 30,
);

sub canHunt
{
    my $bot = shift;
    my ($my_mp,$actor) = @_;

    (! $bot->isDead($actor)) || return 0;
    #($actor->{'kind'} >= 5)  || return 0;

    my $need_mp = $canHunt{chr($actor->{'type'})} || 1000;

    return ($my_mp >= $need_mp);
}

sub cmpHunt
{
    my $bot = shift;
    my ($a,$b) = @_;

    my $mp1 = $canHunt{chr($a->{'type'})};
    my $mp2 = $canHunt{chr($b->{'type'})};

    ($mp1 == $mp2)  || return ($mp2 <=> $mp1);

    my $d1 = $bot->distanceTo($a->{'xpos'},$a->{'ypos'});
    my $d2 = $bot->distanceTo($b->{'xpos'},$b->{'ypos'});

    return ($d1 <=> $d2);
}

sub GETBREAD
{
    my $bot = shift;
    my ($g) = @_;

    ($bot->qtyOnHand('bread') < $g->{'qty'}) || return 1;

    my ($bag,$dist) = $bot->nearestBag();
    defined($bag) || return 0;
    $g->{'subGoals'} = defined($bag) ? [{goal=>\&GETBAG,x=>$bag->{'bagX'},y=>$bag->{'bagY'}}]
                                     : [{goal=>\&SLEEP,seconds=>10}];
    return undef;
}

sub STO
{
    my $bot = shift;
    my ($g) = @_;

    if (!defined($g->{'subGoals'})) {
        $g->{'subGoals'} = [{goal=>\&TOUCHPLAYER,name=>$g->{'name'}}];
        return undef;
    }
    my $open = $bot->openStorage();
    if (!defined($open)) {
        return undef;
    }
    $open || return 0;

    return $bot->putInStorage($g->{'qty'},$g->{'item'});
}

sub USEMAPOBJECT
{
    my $bot = shift;
    my ($g) = @_;

    $bot->useMapObject($g->{'id'});

    return 1;
}

sub TOUCHPLAYER
{
    my $bot = shift;
    my ($g) = @_;

    if (!defined($g->{'subGoals'})) {
        $g->{'subGoals'} = [{goal=>\&GOTONPC,name=>$g->{'name'}}];
        return undef;
    }
    $bot->touchPlayer($g->{'name'});

    return 1;
}

sub SELL
{
    my $bot = shift;
    my ($g) = @_;

    if (defined($g->{'subGoals'})) {
        return ($#{$g->{'subGoals'}} == -1);
    }
    $g->{'subGoals'} = [{goal=>\&TOUCHPLAYER,name=>$g->{'name'}},
                        {goal=>\&SELLTONPC,item=>$g->{'item'},qty=>$g->{'qty'}},
                       ];
    
    return undef;
}

sub SELLTONPC
{
    my $bot = shift;
    my ($g) = @_;

    my $qty = $bot->sellToNPC($g->{'qty'},$g->{'item'});
    defined($qty) || return undef;
    ($qty > 0)    || return 0;

    $g->{'qty'} -= $qty;
    ($g->{'qty'} <= 0) || return undef;
    return 1;
}

sub USEEXIT
{
    my $bot = shift;
    my ($g) = @_;

    my $crntMap  = $bot->crntMap();
    if (my $subGoals = $g->{'subGoals'}) {
        ($#{$g->{'subGoals'}} == -1) || return 0;
        my $from = $g->{'from'};
        my $to   = $g->{'to'} || 'undef';
        ($crntMap ne $from)  || return 0;
        return (($to eq 'undef') || ($crntMap eq $to));
    }
    else {
        my $exit = $bot->getExitDetails($crntMap,$g->{'id'});
        my ($x,$y) = ($exit->{'fromX'},$exit->{'fromY'});
        if (!defined($x) or !defined($y)) {
            $bot->Log("I can't find the location of exit $g->{'id'}");
            return 0;
        }
        $g->{'from'} = $exit->{'from'};
        $g->{'to'} = $exit->{'to'};
        $g->{'subGoals'} = [{goal=>\&MOVETO,x=>$x,y=>$y,delta=>5},
                            {goal=>\&USEMAPOBJECT,id=>$g->{'id'}},
                            {goal=>\&SLEEP,seconds=>10},
                           ];
    }
    return undef;
}

sub HARVEST($$)
{
    my $bot = shift;
    my ($g) = @_;

    if (exists $bot->{'harvesting'}->{'name'}) {
        my $name = $bot->{'harvesting'}->{'name'};
        if ($name ne $g->{'name'}) {
            $bot->Log("I appear to be harvesting the wrong thing!");
            return 0;
        }
        $g->{'attempts'} = 0;
        $g->{'started'}  = 1;
        if ($bot->qtyOnHand($name) >= $g->{qty}) {
            $bot->attackActor($bot->{'my_id'}); # stop harvesting ;-)
            return 1;
        }
    }
    else {
        !defined($g->{'started'}) || return 0;

        my ($map,$id) = ($g->{'map'},$g->{'id'});
        if ($bot->crntMap ne $map) {
            my $h = $bot->{'knowledge'}->{'harvByMap'}->{$map}->{'byID'}->{$id};
            $g->{'subGoals'} = [{'goal'=>\&GOTO,map=>$map,x=>$h->{'x'},y=>$h->{'y'}}];
        }
        else {
            my $d = $bot->distanceToObject($g->{'id'});
            if ($d > 2) {
                my ($x,$y) = $bot->getObjectLocation($g->{'id'});
                (defined($x) && defined($y)) || return 0;
                $g->{'subGoals'} = [{goal=>\&MOVETO,x=>$x,y=>$y,delta=>2}];
            }
            else {
                $g->{'attempts'} = defined($g->{'attempts'}) ? $g->{'attempts'}+1 : 0;
                if ($g->{'attempts'} > 2) {
                    $bot->Log("Too many failed attempts to harvest");
                    return 0;
                }
                $bot->sitDown();
                $bot->harvest($g->{'id'});
                $g->{'subGoals'} = [{'goal'=>\&SLEEP,'seconds'=>2}];
            }
        }
    }
    return undef;
}

sub MOVETO($$)
{
    my $bot = shift;
    my ($g) = @_;

    my $t = $g->{'delta'} || 0;
    my $d = $bot->distanceTo($g->{'x'},$g->{'y'});
    if ($d <= $t) {
        return 1;
    }
    my @dest = @{$bot->{'destination'}};
    if ($dest[0] != $g->{'x'} || $dest[1] != $g->{'y'} || $dest[2] != $t) {
        $bot->moveCloseTo([$g->{'x'},$g->{'y'}],$t);
        return undef;
    }
    return undef;
}

sub WAITTILL($$)
{
    my $bot = shift;
    my ($g) = @_;

    return (time() >= $g->{'time'}) ? 1 : undef;
}

sub SLEEP($$)
{
    my $bot = shift;
    my ($g) = @_;

    if (defined($g->{'subGoals'})) {
        return ($#{$g->{'subGoals'}} == -1);
    }
    my $till = time() + $g->{'seconds'};
    $g->{'subGoals'} = [{'goal'=>\&WAITTILL, 'time'=>$till}];
    return undef;
}

sub SAY($$)
{
    my $bot = shift;
    my ($g) = @_;

    $bot->Say($g->{'text'});
    return 1;
}

sub NEWEXIT
{
    my $bot = shift;
    my ($g) = @_;

    # First try the current map
    my $eList  = getUnexploredExits($bot,$bot->crntMap());
    if ($#{$eList} >= 0) {
        $g->{'result'} = [$bot->crntMap(),$eList->[0]];
        return 1;
    }
    # The other maps
    foreach my $map (@{$bot->knownMaps()}) {
        if ($map ne $bot->crntMap()) {
            my $eList  = getUnexploredExits($bot,$map);
            if ($#{$eList} >= 0) {
                $g->{'result'} = [$map,$eList->[0]];
                return 1;
            }
        }
    }
    return 0;
}

sub PICKUP
{
    my $bot = shift;
    my ($g) = @_;

    defined($g->{'id'}) || return 0;
    $bot->pickUp($g->{'id'},undef);
    return 1;
}

sub OPENBAG
{
    my $bot = shift;
    my ($g) = @_;

    if (!defined($g->{'bag'})) {
        my $bag = $bot->openBag($g->{'id'});
        defined($bag) || return 0;
        $g->{'bag'} = $bag;
    }
    my $contents = $bot->inspectBag($g->{'id'});
    defined($contents) || return undef;
    return (keys(%$contents) != 0);
}

sub GETBAG
{
    my $bot = shift;
    my ($g) = @_;

    defined($g->{'subGoals'}) && return ($#{$g->{'subGoals'}} == -1);

    my $id = $bot->getBagByLocation($g->{'x'},$g->{'y'});
    defined($id) || return 0;
    $g->{'subGoals'} = [{goal=>\&MOVETO,x=>$g->{'x'},y=>$g->{'y'}},
                        {goal=>\&OPENBAG,id=>$id},
                        {goal=>\&PICKUP,id=>$id},
                        {goal=>\&SLEEP,seconds=>5},
                       ];
    return undef;
}

sub KILL
{
    my $bot = shift;
    my ($g) = @_;

    defined($g->{'subGoals'}) && return ($#{$g->{'subGoals'}} == -1);

    my $kill = $bot->killActor($g->{'id'});
    defined($kill) || return undef;
    $kill          || return 0;

    my ($x,$y) = $bot->actorsPosition($g->{'id'});
    (defined($x) and defined($y)) || return 1;
    $g->{'subGoals'} = [{goal=>\&SLEEP,seconds=>2},
                        {goal=>\&GETBAG,x=>$x,y=>$y},
                       ];

    return undef;
}

sub HUNT
{
    my $bot = shift;
    my ($g) = @_;


    defined($g->{'subGoals'}) && return ($#{$g->{'subGoals'}} == -1);

    if ($bot->crntMap() ne 'startmap') {
        $g->{'subGoals'} = [{goal=>\&GOTO,map=>'startmap',x=>102,y=>143,delta=>3}];
        return undef;
    }

    my @mp = $bot->getStat('mp');
    if ($mp[1]-$mp[0] >= 23) {
        if (my $restore = $bot->haveItem('potion of body restoration')) {
            my $cool = $restore->{'cooldown'};
            ($cool < time()) && $bot->useInventoryItem('potion of body restoration');
        }
    }
    elsif ($mp[1]-$mp[0] >= 8) {
        if (my $healing = $bot->haveItem('potion of minor healing')) {
            my $cool = $healing->{'cooldown'};
            ($cool < time()) && $bot->useInventoryItem('potion of minor healing');
        }
    }

    my $me     = $bot->{'me'};
    my @actors = grep {canHunt($bot,$mp[0],$_)} @{$bot->getActors()};
    @actors    = sort {cmpHunt($bot,$a,$b)} @actors;

    if ($#actors < 0) {
        if (($me->{'lastMoved'} < time()-10) and !defined($bot->{'path'})) {
            my $to = $bot->randomLocation();
            $bot->moveCloseTo($to,3);
            $bot->Log("Moving to $to->[0],$to->[1]\n");
        }
    }

    my $kill = $actors[0];
    defined($kill) || return undef;
    defined($kill->{'type'}) || return undef;
    my $min_mp = $canHunt{chr($kill->{'type'})} || 10000;

    if (($mp[0] >= $min_mp) and (! $bot->isDead($kill))) {
        $g->{'subGoals'} = [{goal=>\&KILL,id=>$kill->{'id'},name=>$kill->{'name'}}];
        return undef;
    }
    return undef;
}

sub GOTO
{
    my $bot = shift;
    my ($g) = @_;

    defined($g->{'subGoals'}) && return ($#{$g->{'subGoals'}} == -1);

    my $to   = [$g->{'map'},$g->{'x'},$g->{'y'}];
    my $from = $bot->myLocation();
    $g->{'subGoals'} = getInterMapPath($bot,$from,$to,2);
    return undef;
}

sub GOTONPC
{
    my $bot = shift;
    my ($g) = @_;

    defined($g->{'subGoals'}) && return ($#{$g->{'subGoals'}} == -1);

    my $to = $bot->getNPCLocation($g->{'name'});
    if (!defined($to)) {
        $bot->Log("Can't find location of $g->{'name'}");
        return 0;
    }
    my $from = $bot->myLocation();
    $g->{'subGoals'} = getInterMapPath($bot,$from,$to,2);
    return undef;
}

# Try to do acheive a 'Goal'
# return:-
#    1     - Goal has been acheived
#    0     - Goal is unacheivable
#    undef - Goal not acheived yet
#
sub doGoal($$$)
{
    my $bot = shift;
    my ($g,$lvl) = @_;

    if (!defined($g)) {
        $bot->Log("Can't do undefined goal !");
        return 0;
    }
    if (exists $g->{'subGoals'}) {
        while (my $subGoal = $g->{'subGoals'}->[0]) {
            my $done = doGoal($bot,$subGoal,$lvl+1);
            if (!defined($done)) {
                return undef;
            }
            shift @{$g->{'subGoals'}};
            ($done) || return 0
        }
    }
    my $done = &{$g->{'goal'}}($bot,$g);
    my $doneStr = " still trying";
    if (defined($done)) {
        $doneStr = $done ? " succeeded" : " failed";
    }

    return $done;
}

my %goalDesc = (
    \&WAITTILL => ["WAITTILL %d",'time'],     \&SAY     => ["SAY '%s'",'text'],
    \&ENTER   => ["ENTER %d",'id'],
    \&HUNT     => ["HUNT",''],               \&KILL    => ["KILL %s(%d)",'name','id'],
    \&GETBAG   => ["GETBAG %d,%d",'x','y'],   \&OPENBAG => ["GETBAG %d",'id'],
    \&GOTONPC  => ["GOTONPC %s",'name'],      \&NEWEXIT => ["NEWEXIT",''],

    \&HARVEST      => ["HARVEST %d %s(%d) on %s",'qty','name','id','map'],
    \&MOVETO       => ["MOVETO %d,%d (delta=%d)",'x','y','delta'],
    \&SLEEP        => ["SLEEP %d",'seconds'],
    \&TOUCHPLAYER  => ["TOUCHPLAYER %s",'name'],
    \&SELLTONPC    => ["SELLTONPC %d %s",'qty','item'],
    \&USEMAPOBJECT => ["USE_MAP_OBJECT %d",'id'],
    \&PICKUP       => ["PICKUP %d",'id'],
    \&USEEXIT      => ["USEEXIT %d from %s to %s",'id','from','to'],
    \&GOTO         => ["GOTO %s %d,%d",'map','x','y'],
    \&STO          => ["STO %d %s at %s",'qty','item','name'],
    \&SELL         => ["SELL %d %s to %s",'qty','item','name'],
    \&GETBREAD     => ["GETBREAD %d",'qty'],
);

sub goalDesc
{
    my ($g,$lvl) = @_;

    my $desc = "";
    my $pad = sprintf('%'.$lvl.'s',"");
    if (my $gDesc = $goalDesc{$g->{'goal'}}) {
        my @desc = @{$gDesc};
        my $format = shift(@desc);
        @desc = map {$g->{$_}} @desc;
        @desc = map {(defined($_) ? $_ : 'undef')} @desc;
        $desc = $pad.sprintf($format, @desc)."\n";
    }
    else {
        $desc = $pad."UNKNOWN\n";
    }
    defined($g->{'subGoals'}) || return $desc;
    my @subGoals = @{$g->{'subGoals'}};
    ($#subGoals >= 0) || return $desc;
    foreach my $subG (@subGoals) {
        $desc .= goalDesc($subG,$lvl+1);
    }
    return $desc;
}

my @Goals = ();

sub getInterMapPath
{
    my $bot = shift;
    my ($from,$to,$delta) = @_;

    my @goals;
    my $path = $bot->findPathToMap($from,$to,$delta);
    foreach my $p (@$path) {
        if ($p =~ m/^MAP\,.+\,(\d+)\,(\d+)/) {
            push(@goals,{goal=>\&MOVETO,x=>$1,y=>$2});
        }
        elsif ($p =~ m/^EXIT\,(.+)\,(\d+)/) {
            my $exit = $bot->getExitDetails($1,$2);
            if (!defined($exit)) {
                die $p;
            }
            push(@goals,{goal=>\&USEEXIT,id=>$2});
        }
        else {
            die $p;
        }
    }
    return wantarray ? @goals : \@goals;
}

sub decide
{
    my $bot = shift;
    my @goals;

    my ($map,$x,$y) = $bot->myLocation();

    my @carry  = $bot->getStat('carry');
    my @mp     = $bot->getStat('mp');
    my $meat   = $bot->qtyOnHand('raw meat');
    my $fur    = $bot->qtyOnHand('brown rabbit fur');
    my $gc     = $bot->qtyOnHand('gold coins');
    my $bread  = $bot->qtyOnHand('bread');
    my $n      = $carry[1]-$carry[0];

    if ($bread < 3) {
        push(@goals, {goal=>\&GETBREAD,qty=>10});
    }
    elsif ($gc > 500) {
        push(@goals,{goal=>\&STO,item=>'gold coins',qty=>$gc,name=>'Molgor'});
    }
    elsif ($n <= 15  || $bot->{'nCarry'} >=25) {
        foreach my $item (values %{$bot->{'invByPos'}}) {
            my $name = $item->{'name'};
            $isFood{$name} && next;
            ($name =~ m/raw meat/i) && next;
            ($name =~ m/brown rabbit fur/i) && next;
            my $qty = $item->{'quantity'};
            push(@goals,{goal=>\&STO,item=>$name,qty=>$qty,name=>'Molgor'});
        }
        if (($meat > 0) || ($fur > 0)) {
            push(@goals,{goal=>\&SELL,name=>'Reca',item=>'raw meat',qty=>$meat});
            push(@goals,{goal=>\&SELL,name=>'Reca',item=>'brown rabbit fur',qty=>$fur});
        }
    }
    else {
        @goals = ({goal=>\&HUNT});
    }
    return @goals;
}

sub main
{
    while(1) {
        $bot->connect();
        if ($bot->{'connected'}) {
            $bot->login($USER,$PASS) || die "failed to log in !";
            my ($type,$len,$packet);

            $bot->eatThese('bread','vegetables','fruits');
            while($bot->{'loggedIn'}) {
                ($type,$len,$packet) = $bot->NextPacket();
                my $ret              = $bot->Dispatch($type,$len,$packet);
                my ($map,$x,$y)      = $bot->myLocation();

                (defined($x) and defined($y)) || next;
                $bot->invIsComplete()         || next;

                if ($#Goals == -1) {
                    @Goals = decide($bot);
                }

                if (my $g = $Goals[0]) {
                    my $done = doGoal($bot,$g,0);
                    print STDERR goalDesc($g,0);
                    if (defined($done)) {
                        shift(@Goals);
                    }
                }
            }
            $bot->disconnect();
        }
        sleep $SLEEP;
        $SLEEP = ($SLEEP < 30*60) ? $SLEEP * 2 : $SLEEP;
    }
}

main();
