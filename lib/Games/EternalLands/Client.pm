package Games::EternalLands::Client;

use strict;
use IO::Socket;
use POSIX;
use YAML;
use Games::EternalLands::Map;
use Data::Dumper;

my $VERSION = "0.01";

use Games::EternalLands::Constants qw(%ELStatsByID %ServerCommands %ClientCommands
                                      %ActorCommandsByID %ClientCommandsByID %ActorTypesByID
                                      $DEBUG_PACKETS $DEBUG_TYPES);

my $MAXBAGS = 200;
my $ITEMS_PER_BAG = 50;

################################################


################################################

sub Log
{
    my $self = shift;

    #     0    1    2     3     4    5     6     7     8
    # ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)
    my @now = localtime(time);

    my $timeStamp = sprintf("%4d-%02d-%02d %02d:%02d",
                            $now[5]+1900,$now[4],$now[3], $now[2],$now[1]); 

    print STDERR "[",$timeStamp,"] ",$_[0],"\n";
}

sub setDebug
{
    my $self = shift;
    my ($val) = @_;

    $self->{'debug'} = $val;
}

sub packetAsHex
{
    my $self = shift;
    my ($pkt) = @_;
    my @bytes;

    my $n = length($pkt);
    for(my $i=0; $i<$n; $i++) {
        my $ch = substr($pkt,$i,1);
        push(@bytes,sprintf("%2X", ord($ch)));
    }
    return join(" ",@bytes);
}

sub send
{
    my $self = shift;
    my ($cmd,$data) = @_;

    if ($cmd eq 'MOVE_TO' or $cmd eq 'ATTACK_SOMEONE') {
        if ($self->{'lastMove'}+1 > time()) {
            return;
        }
        $self->{'lastMove'} = time();
    }

    $cmd = $ServerCommands{$cmd} || die "unknown server command '$cmd'";

    my $len = length($data);
    $len = pack('v',$len+1);
    my $s = $self->{'socket'};

    my $buf = $cmd.$len.$data;

    ($self->{'debug'} & $DEBUG_PACKETS) && $self->Log("Sending: ".$self->packetAsHex($buf));

    print $s $buf;
    $s->flush();
}

sub keepAlive
{
    my $self = shift;
    my ($force) = @_;

    my $currentTime = time();
    my $nextHeartbeatTime = $self->{'lastHeartbeatTime'} + $self->{'heartbeatTimer'};
    if (($currentTime >= $nextHeartbeatTime) || ($force)) {
        $self->send("HEART_BEAT","");
        $self->{'lastHeartbeatTime'} = time();
    }
    my $nextMsgTime = $self->{'lastMsgAt'} + $self->{'msgInterval'} * 60;
    if ($currentTime > $nextMsgTime) {
        $self->{'lastMsgAt'} = $currentTime;
        $self->Advertise();
    }
}

# unpack the items list from the pack sent by
# the server in to a hash
sub getItemsList
{
    my $self = shift;
    my ($data) = @_;
    my %items;

    my $nItems = unpack('C', substr($data,0,1));
    for(my $i=0; $i<$nItems; $i++) {
        my $item = {
            'image'    => unpack('v', substr($data,$i*8+1,2)),
            'quantity' => unpack('V', substr($data,$i*8+1+2,4)),
            'pos'      => unpack('C', substr($data,$i*8+1+6,1)),
            'flags'    => unpack('C', substr($data,$i*8+1+7,1)),
        };
        $items{$item->{'pos'}} = $item;
    }
    return \%items;
}

sub Say
{
    my $self = shift;
    my ($msg) = @_;

    $self->send('RAW_TEXT',$msg);
}

sub LogTrade
{
    my $self = shift;

    my $trader = $self->{'tradeWith'};
    foreach my $pos (keys %{$self->{'thereTrades'}}) {
        my $name = $self->{'thereTrades'}->{$pos}->{'name'};
        my $qty  = $self->{'thereTrades'}->{$pos}->{'quantity'};
        $self->Log("$trader gave me $qty '".$name."'");
    }
    foreach my $pos (keys %{$self->{'myTrades'}}) {
        my $name = $self->{'myTrades'}->{$pos}->{'name'};
        my $qty  = $self->{'myTrades'}->{$pos}->{'quantity'};
        $self->Log("I gave $trader $qty '".$name."'");
    }
    $self->Log("Trade with '$trader' complete");
}

sub actorsName
{
    my $self = shift;
    my ($id) = @_;

    if (defined($self->{'actorsByID'}->{$id})) {
        return $self->{'actorsByID'}->{$id}->{'name'};
    }
    return "";
}

sub actorsPosition
{
    my $self = shift;
    my ($id) = @_;

    my $actor = $self->{'actorsByID'}->{$id};
    return ($actor->{'xpos'},$actor->{'ypos'});
}

sub moveTo
{
    my $self = shift;
    my ($x,$y) = @_;

    $self->send('MOVE_TO',pack('vv',$x,$y));
}

sub attackActor
{
    my $self = shift;
    my ($id) = @_;

    $self->send('ATTACK_SOMEONE',pack('V',$id));
}

sub getMyDetails
{
    my $self = shift;

    my ($id) = $self->{'my_id'};

    return $self->{'actorsByID'}->{$id};
}

sub addBag
{
    my $self = shift;
    my ($id,$x,$y,$z) = @_;

    if ($id >= $MAXBAGS) {
        $self->Log("Bad bag ID $id at ($x,$y)");
        return undef;
    }
    if (defined($self->{'bagsByID'}->{$id})) {
        $self->Log("Bag($id) already exists! this should not happen");
    }
    my $bag = {
        'bagX'      => $x,
        'bagY'      => $y,
        'bagZ'      => $z,
        'bagID'     => $id,
    };
    $self->{'bagsByID'}->{$id} = $bag;
    #$self->Log("Bag($id) at ($x,$y,$z)");

    return $bag;
}

sub openBag
{
    my $self = shift;
    my ($id) = @_;

    my $bag = $self->{'bagsByID'}->{$id};
    if (!defined($bag)) {
        $self->Log("Opening not existant bag $id, this should not happen");
         return;
    }
    push(@{$self->{'inspectBag'}}, $id);
    $self->send('INSPECT_BAG',pack('C',$id));
    $self->Log('Inspecting bag '.$id);
}

sub distanceTo
{
    my $self = shift;
    my ($toX,$toY) = @_;
    my $fromX = $self->{'actorsByID'}->{$self->{'my_id'}}->{'xpos'};
    my $fromY = $self->{'actorsByID'}->{$self->{'my_id'}}->{'ypos'};

    return $self->{'Map'}->distance($fromX,$fromY,$toX,$toY);
}

sub getStat
{
    my $self = shift;
    my ($stat) = @_;
    return @{$self->{'stats'}->{$stat}};
}

###########################################################
# MISCELLANEOUS CALLBACKS                                 #
###########################################################

sub LOG_IN_OK
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    $self->{'loggedIn'} = 1;
}

sub LOG_IN_NOT_OK
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    $self->{'loggedIn'}      = 0;
    $self->{'failedLogins'} += 1;
}

sub PING_REQUEST
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    $self->send('PING_RESPONSE',$data);
}

sub NEW_MINUTE
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    my $gameMinute = unpack('v', $data);
}

sub SYNC_CLOCK
{
    my $self = shift;
    my ($type,$len,$data) = @_;
}

sub RAW_TEXT
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    my $text = substr($data,2);

    if ($text =~ m/\s*(\w+) wants to trade with you/) {
        my $name = $1;
        $self->Log("Trade request from '".$name."'");
        my $actor = $self->{'actorsByName'}->{$name};
        if (!defined($actor)) {
            $self->send('SEND_PM', "$name Sorry, I can't get your actor ID, this should not happen . . .");
            $self->send('SEND_PM', "$name Please notify the owner of this bot");
            return;
        }
        $self->send("TRADE_WITH",pack('V',$actor->{'id'}));
    }
    elsif ($text =~ m/^\[PM from (\w+): (.*)\]/) {
        $self->Log("$1 said '".$2."'");
        if($self->can("handlePM")) {
            $self->handlePM($1,$2);
        }
    }
}

##########################################################################
# ACTOR RELATED CALLBACKS                                                #
##########################################################################

sub DumpName
{
    my ($name) = @_;

    my $n = length($name);
    print STDERR "$name";
    for(my $i=0; $i<$n; $i++) {
        print STDERR ",",ord(substr($name,$i,1));
    }
    print STDERR "\n";
}

sub ADD_NEW_ACTOR
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    my $actor;
    $actor->{'id'}         = unpack('v', substr($data,0,2));
    $actor->{'xpos'}       = unpack('v', substr($data,2,2)) & 0x7FF;
    $actor->{'ypos'}       = unpack('v', substr($data,4,2)) & 0x7FF;
    $actor->{'zpos'}       = unpack('v', substr($data,6,2));
    $actor->{'zrot'}       = unpack('v', substr($data,8,2));
    $actor->{'bufs'}       = 0; # ignore bufs at the moment
    $actor->{'type'}       = substr($data,10,1);
    $actor->{'frame'}      = substr($data,11,1);
    $actor->{'max_health'} = unpack('v', substr($data,12,2));
    $actor->{'cur_health'} = unpack('v', substr($data,14,2));
    $actor->{'kind'}       = substr($data,16,1);
    my ($name,$guild)      = split(' ',unpack('Z*',substr($data,17,13)));
    $actor->{'name'}       = $name;
    $actor->{'guild'}      = $guild;

    $self->{'actorsByID'}->{$actor->{'id'}} = $actor;
    $self->{'actorsByName'}->{$actor->{'name'}} = $actor;   # Assumes unique names . . .

#DumpName(unpack('Z*',substr($data,17,13)));
}

sub ADD_NEW_ENHANCED_ACTOR
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    my $actor;
    $actor->{'id'}   = unpack('v', substr($data,0,2));
    $actor->{'xpos'} = unpack('v', substr($data,2,2)) & 0x7FF;
    $actor->{'ypos'} = unpack('v', substr($data,4,2)) & 0x7FF;
    $actor->{'zpos'} = unpack('v', substr($data,6,2));
    $actor->{'zrot'} = unpack('v', substr($data,8,2));

    $actor->{'bufs'} = 0; # ignore bufs at the moment

    $actor->{'type'}  = substr($data,10,1);
    $actor->{'frame'} = substr($data,11,1);
    $actor->{'skin'}  = substr($data,12,1);
    $actor->{'hair'}  = substr($data,13,1);
    $actor->{'shirt'}  = substr($data,14,1);
    $actor->{'pants'}  = substr($data,15,1);
    $actor->{'boots'}  = substr($data,16,1);
    $actor->{'head'}  = substr($data,17,1);
    $actor->{'shield'}  = substr($data,18,1);
    $actor->{'weapon'}  = substr($data,19,1);
    $actor->{'cape'}  = substr($data,20,1);
    $actor->{'helmet'}  = substr($data,21,1);

    $actor->{'max_health'} = unpack('v', substr($data,23,2));
    $actor->{'cur_health'} = unpack('v', substr($data,25,2));
    $actor->{'kind'}       = substr($data,27,2);
    my ($name,$guild)      = split(' ',unpack('Z*',substr($data,28,13)));
    $actor->{'name'}       = $name;
    $actor->{'guild'}      = $guild;

    $self->{'actorsByID'}->{$actor->{'id'}} = $actor;
    $self->{'actorsByName'}->{$actor->{'name'}} = $actor;   # Assumes unique names . . .

#DumpName(unpack('Z*',substr($data,28,13)));
}

sub KILL_ALL_ACTORS
{
    my $self = shift;
    my ($type,$len,$data) = @_;
    $self->{'actorsByID'} = {};
    $self->{'actorsByName'} = {};
    $self->{'path'} = undef;
}

sub REMOVE_ACTOR
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    my $id = unpack('v', $data);
    my $actor = $self->{'actorsByID'}->{$id};
    if (defined($actor)) {
        my $name = $actor->{'name'};
        if (defined($self->{'actorsByName'}->{$name})) {
            if ($self->{'actorsByName'}->{$name}->{'id'} == $id) {
                delete $self->{'actorsByName'}->{$name};
            }
        }
        delete $self->{'actorsByID'}->{$id};
    }
}

sub ADD_ACTOR_COMMAND
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    my %moveXY = (
        "n" => [ 0, 1], "ne" => [  1, 1],
        "e" => [ 1, 0], "se" => [  1,-1],
        "s" => [ 0,-1], "sw" => [ -1,-1],
        "w" => [-1, 0], "nw" => [ -1, 1],
    );

    my $actorID = unpack('v', substr($data,0,2));
    my $cmd     = substr($data,2,1);
    my $actor   = $self->{'actorsByID'}->{$actorID};
    my $cmdStr  = $ActorCommandsByID{$cmd};
    my $name    = "Unknown actor";
    if (defined($actor)) {
        $name = $actor->{'name'};
        if ($cmdStr =~ m/^move_(\w+)/) {
            $actor->{'xpos'} += $moveXY{$1}->[0];
            $actor->{'ypos'} += $moveXY{$1}->[1];
        }
    }
    ($self->{'debug'} & $DEBUG_TYPES) &&
        $self->Log("Actor=$name Command=$cmdStr");
}

sub SEND_NPC_INFO
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    my $name = $data;
    print STDERR "NPC Name=$name\n";;
}

sub NPC_TEXT
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    my ($byte1,$byte2) = unpack('CC',$data);
    my $text = substr($data,2);
    print STDERR "NPC_TEXT=$text\n"

}

sub NPC_OPTIONS_LIST
{
    my $self = shift;
    my ($type,$len,$data) = @_;
    my $offset=0;
    my %options;

    for(my $i=0;$i<20;$i++) {
        if ($offset + 3 > $len) {
            last;
        }
        my $n = unpack('v',substr($data,$offset,2));
        if ($offset + 3 + $n + 2 + 2 > $len) {
            last;
        }
        my $response = lc(substr($data,$offset+2,$n));
        my $id       = unpack('v',substr($data,$offset+2+$n));
        my $toActor  = unpack('v',substr($data,$offset+2+2+$n));
        $options{$response} = {
            'id' => $id,
            'actor' => $toActor,
        };
        $offset += $n+2+2+2;
    }
    return \%options;
}

##########################################################################
# CALLBACKS ABOUT THIS CLIENT                                            #
##########################################################################

sub CHANGE_MAP
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    if (defined($self->{'mapDir'})) {
        $self->{'mapFile'} = $self->{'mapDir'}."/".$data;
        $self->{'Map'}     = Games::EternalLands::Map->new($self->{'mapFile'});
    }
    $self->{'path'} = undef;
}

sub HERE_YOUR_STATS
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    $self->{'stats'} = {
        'phy' => [unpack('ss',substr($data, 0*2,4))],
        'coo' => [unpack('ss',substr($data, 2*2,4))],
        'rea' => [unpack('ss',substr($data, 4*2,4))],
        'wil' => [unpack('ss',substr($data, 6*2,4))],
        'ins' => [unpack('ss',substr($data, 8*2,4))],
        'phy' => [unpack('ss',substr($data,10*2,4))],
    };
    # ignore nexus at the moment, [12]==>[23]
    # ignore skills at the moment, [24]==>[39]
    @{$self->{'stats'}->{'carry'}}  = unpack('ss',substr($data,40*2,4));
    @{$self->{'stats'}->{'mp'}}     = unpack('ss',substr($data,42*2,4));
    @{$self->{'stats'}->{'ep'}}     = unpack('ss',substr($data,44*2,4));
    @{$self->{'stats'}->{'food'}}   = unpack('s',substr($data,46*2,2));
    $self->{'stats'}->{'food'}->[1] = 45;
}

sub SEND_PARTIAL_STAT
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    my $n = $len/5;
    for(my $i=0; $i<$n; $i++) {
        my $stat  = substr($data,$i*5+0,1);
        my $value = unpack('l', substr($data,$i*5+1,4));

        if ($ELStatsByID{$stat} eq 'FOOD_LEV') {
            $self->{'stats'}->{'food'}->[0] = $value; }
        elsif ($ELStatsByID{$stat} eq 'MAT_POINT_CUR') {
            $self->{'stats'}->{'mp'}->[0] = $value; }
        elsif ($ELStatsByID{$stat} eq 'MAT_POINT_BASE') {
            $self->{'stats'}->{'mp'}->[1] = $value; }
        elsif ($ELStatsByID{$stat} eq 'ETH_POINT_CUR') {
            $self->{'stats'}->{'ep'}->[0] = $value; }
        elsif ($ELStatsByID{$stat} eq 'ETH_POINT_BASE') {
            $self->{'stats'}->{'ep'}->[1] = $value; }
        elsif ($ELStatsByID{$stat} eq 'CARRY_WGHT_CUR') {
            $self->{'stats'}->{'carry'}->[0] = $value; }
        elsif ($ELStatsByID{$stat} eq 'CARRY_WGHT_BASE') {
            $self->{'stats'}->{'carry'}->[1] = $value; }
    }
}

sub YOU_ARE
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    $self->{'my_id'} = unpack('v', $data);
}

################################################################
# TRADE RELATED CALLBACKS                                      #
################################################################

sub GET_YOUR_TRADEOBJECTS
{
    my $self = shift;
    my ($type,$len,$data) = @_;
}

sub GET_TRADE_PARTNER_NAME
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    my $partner = substr($data,1);
    $self->{'tradeWith'} = $partner;

    $self->send('SEND_PM',$self->{'tradeWith'}." please pm with what you wish to buy or sell");
}

# Blindly trust our trade partner, when they accept so
# do we (but see Bot.pm)
sub GET_TRADE_ACCEPT
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    my $who = unpack('C', $data);
    if ($who) {
        $self->{'tradeAccepted'} += 1;
        my @accepted = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0);
        foreach my $item (@{$self->{'??'}}) {
            my $pos = $item->{'pos'};
            $accepted[$pos] = $item->{'type'};
        }
        $data = pack('CCCCCCCCCCCCCCCC',@accepted);
        $self->send('ACCEPT_TRADE', $data);
    }
}

sub GET_TRADE_REJECT
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    my $who = unpack('C', $data);
    if ($who) {
        $self->{'tradeAccepted'} = 0;
    }
}

# Called when an object is removed from the trade window.
# We only deal with objects our trade partner removed
# as we should know the state of our own trade objects
# We send a LOOK_AT_TRADE_ITEM to the server so that
# we can get the description for the object
sub REMOVE_TRADE_OBJECT
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    my $pos  = unpack('C', substr($data,4,1));
    my $who  = unpack('C', substr($data,5,1));
    my $qty  = unpack('V', substr($data,0,4)),

    my $trades;
    if ($who) { # Trade partner removed object
        $trades = $self->{'thereTrades'}; }
    else {
        $trades = $self->{'myTrades'};
    }
    my $item = $trades->{$pos};
    if (!defined($item)) {
        $self->Log("removing unknown item from trade - this should not happen");
        return;
    }
    if ($item->{'quantity'} == $qty) {
        delete $trades->{$pos};
    }
    elsif ($item->{'quantity'} < $qty) {
        $self->Log("removing more from trade than is in the trade - this should not happen");
    }
    else {
        $item->{'quantity'} -= $qty;
    }
}

sub GET_TRADE_OBJECT
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    my $qty    = unpack('V', substr($data,2,4)),
    my $pos    = unpack('C', substr($data,7,1));
    my $who    = unpack('C', substr($data,8,1));
    my $trades = ($who) ? $self->{'thereTrades'} : $self->{'myTrades'};

    if (defined($trades->{$pos})) {
        $trades->{$pos}->{'quantity'} += $qty; }
    else {
        $trades->{$pos} = {
            'pos'      => $pos,
            'image'    => unpack('v', substr($data,1,2)),
            'quantity' => $qty,
            'type'     => unpack('C', substr($data,6,1)),
        };
        $self->send('LOOK_AT_TRADE_ITEM', pack('CC',$pos,$who));
        push(@{$self->{'lookAtQueue'}}, ["GET_TRADE_OBJECT",$trades->{$pos}]);
    }
}

sub GET_TRADE_EXIT
{
    my $self = shift;

    if ($self->{'tradeAccepted'} == 2) {
        $self->send('SEND_PM', $self->{'tradeWith'}." Thanks");
    }
    $self->LogTrade();


    $self->{'tradeWith'}     = undef;
    $self->{'thereTrades'}   = {};
    $self->{'myTrades'}      = {};
    $self->{'tradeOk'}       = 0;
    $self->{'tradeAccepted'} = 0;
}

################################################################
# INVENTORY RELATED CALLBACKS                                  #
################################################################

# decode the message from the server that tells us what is in
# our inventory.
# create a a hash of these objects by inventory position
# Send LOOK_AT_INVENTORY_ITEM for each item so that we can
# build a 'byName' hash of these items as well
sub HERE_YOUR_INVENTORY
{
    my $self = shift;

    my ($type,$len,$data) = @_;

    $self->{'invByPos'} = $self->getItemsList($data);

    my @posList = sort (keys %{$self->{'invByPos'}});
    foreach my $pos (@posList) {
        $self->send('LOOK_AT_INVENTORY_ITEM', pack('C',$pos));
        push(@{$self->{'lookAtQueue'}}, ["HERE_YOUR_INVENTORY",$self->{'invByPos'}->{$pos}]);
    }
}

sub REMOVE_ITEM_FROM_INVENTORY
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    my $pos  = unpack('C',$data);
    my $name = $self->{'invByPos'}->{$pos}->{'name'};
    if (defined($self->{'invByName'}->{$name})) {
        delete $self->{'invByName'}->{$name};
    }
    delete $self->{'invByPos'}->{$pos};
}

sub GET_NEW_INVENTORY_ITEM
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    my $pos  = unpack('C', substr($data,6,1));
    my $item = {
        'image'    => unpack('v', substr($data,0,2)),
        'quantity' => unpack('V', substr($data,2,4)),
        'pos'      => $pos,
        'flags'    => unpack('C', substr($data,7,1)),
    };
    $self->{'invByPos'}->{$pos} = $item;

    $data = pack('C',$pos);
    $self->send('LOOK_AT_INVENTORY_ITEM',$data);
    push(@{$self->{'lookAtQueue'}}, ["GET_NEW_INVENTORY_ITEM",$item]);

    return $item;
}

sub INVENTORY_ITEM_TEXT
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    my ($name,$desc,$weight);

    ($desc,$weight) = split("\n",$data);
    ($name,$desc)   = split(" - ",$desc);
    ($weight)       = ($weight =~ m/weight:\s+(\d+)\s*emu/i);
    $name           = lc(substr($name,1));

    my $q = shift(@{$self->{'lookAtQueue'}});
    if (defined($q)) {
        my $type          = $q->[0];
        my $item          = $q->[1];
        $item->{'name'}   = $name;
        $item->{'desc'}   = $desc;
        $item->{'weight'} = $weight;
        if ($type eq "HERE_YOUR_INVENTORY" or $type eq "GET_NEW_INVENTORY_ITEM") {
            $self->{'invByName'}->{lc($name)} = $item;
        }
    }
}

sub HERE_YOUR_GROUND_ITEMS
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    my $bagID = shift(@{$self->{'inspectBag'}});

    my $numItems = unpack('C',$data);
    if ($numItems > $ITEMS_PER_BAG) {
        $self->Log("Too many items in bag: $numItems");
        return undef;
    }
    for(my $i=0;$i<$numItems;$i++) {
        my $offset = $i*7+1;
        my $image  = unpack('v', substr($data,$offset,2));
        my $qty    = unpack('L',substr($data,$offset+2,4));
        my $pos    = unpack('C',substr($data,$offset+6,1));
        my $item   = {
            'pos'      => $pos,
            'quantity' => $qty,
            'image'    => $image,
        };
        $self->{'bagsByID'}->{$bagID}->{'items'}->{$pos} = $item;
        $self->send('LOOK_AT_GROUND_ITEM',pack('C',$pos));
        push(@{$self->{'lookAtQueue'}}, ["LOOK_AT_GROUND_ITEM",$item]);
    }
}

###########################################################
# BAGS REALTED CALLBACKS                                  #
###########################################################

sub GET_NEW_BAG
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    my $x   = unpack('v', substr($data,0,2)),
    my $y   = unpack('v', substr($data,+2,2)),
    my $z   = 0,  #BUG
    my $id  = unpack('C', substr($data,4,1));
    my $bag = $self->addBag($id,$x,$y,$z);

    return $bag;
}

sub GET_BAGS_LIST
{
    my $self = shift;
    my ($type,$len,$data) = @_;
    my @bags = ();

    my $numBags = unpack('C',substr($data,0,1));
    if ($numBags > $MAXBAGS) {
        $self->Log("Bad number of bags in list: $numBags");
        return \@bags;
    }
    for(my $i=0; $i<$numBags; $i++) {
        my $offset = $i*5+1;
        my $x   = unpack('v', substr($data,$offset,2));
        my $y   = unpack('v', substr($data,$offset+2,2));
        my $z   = 0;
        my $id  = unpack('C', substr($data,$offset+4,1));
        my $bag = $self->addBag($id,$x,$y,$z);
        if (defined($bag)) {
            push(@bags, $bag);
        }
    }
    return \@bags;
}

sub DESTROY_BAG
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    my $bagID = unpack('C', substr($data,0,1));
    if (defined($self->{'bagsByID'}->{$bagID})) {
        delete $self->{'bagsByID'}->{$bagID}; }
    else {
        $self->Log("Destroying uknown bag $bagID");
    }
}

###########################################################

sub processArgs
{
    my $self = shift;
    my @args  = @_;
    my @notUsed;

    while(my $arg = shift @args) {
        if ($arg eq '-server') {
            $self->{'server'} = shift @args; }
        elsif ($arg eq '-port') {
            $self->{'port'} = shift @args; }
        elsif ($arg eq '-mapDir') {
            $self->{'mapDir'} = shift @args; }
        else {
            push(@notUsed, $arg);
        }
    }
    return @notUsed;
}

sub new
{
    my $class = shift;
    my $self  = {};
    bless($self, $class);

    $self->{'debug'}             = 0;
    $self->{'server'}            = undef;
    $self->{'port'}              = undef;
    $self->{'username'}          = undef;
    $self->{'socket'}            = undef;
    $self->{'lastHeartbeatTime'} = 0;
    $self->{'heartbeatTimer'}    = 25;
    $self->{'connected'}         = 0;
    $self->{'loggedIn'}          = 0;
    $self->{'failedLogins'}      = 0;
    $self->{'Map'}               = undef;
    $self->{'actorsByID'}        = undef;
    $self->{'actorsByName'}      = undef;
    $self->{'mapDir'}            = undef;
    $self->{'bagsByID'}          = {};
    $self->{'inspectBag'}        = ();

    $self->{'lastMove'}          = 0;

    $self->{'itemsToSell'}       = {};
    $self->{'itemsToBuy'}        = {};
    $self->{'lastMsgAt'}         = time(); # no msg on startup
    $self->{'msgInterval'}       = 20;     # minutes

    $self->{'myTrades'}          = {};
    $self->{'thereTrades'}       = {};
    $self->{'tradeAccepted'}     = 0;

    $self->{'invByPos'}          = {};
    $self->{'invByName'}         = {};
    $self->{'lookAtQueue'}       = ();   # FIFO of objects we have asked to look at

    @_ = $self->processArgs(@_);

    return $self;
}

sub connect
{
    my $self = shift;

    while(@_) {
        my $arg = shift;
        if ($arg eq '-server') {
            $self->{'server'} = shift;
        }
        elsif ($arg eq '-port') {
            $self->{'port'} = shift;
        }
    }

    defined($self->{'server'}) || die "server must be defined";
    defined($self->{'port'})   || die "port must be defined";

    $self->{'socket'} = IO::Socket::INET->new(Proto => 'tcp',
                                              Blocking => 1,
                                              PeerAddr => $self->{'server'},
                                              PeerPort => $self->{'port'});

    if (!defined($self->{'socket'})) {
        $self->Log("Failed to create socket: $!");
        return 0;
    }

    $self->{'connected'} = 1;
    my ($type,$len,$packet) = $self->NextPacket();  # We eat the first packet
    $self->Dispatch($type,$len,$packet);
    $self->keepAlive(1);

    return 1;
}

sub disconnect
{
    my $self = shift;

    close($self->{'socket'});
    $self->{'connected'} = 0;
    $self->{'socket'} = undef;
}


sub login
{
    my $self = shift;

    my ($user,$pass);
    if (@_) {
        ($user,$pass) = @_;
    }
    if (!defined($user) || !defined($pass)) {
        $self->Log("User and password must be passed");
        return 0;
    }

    $self->{'loginFailed'} = 0;
    $self->send('LOG_IN', sprintf("%s %s%c",$user,$pass,0));

    while (!$self->{'loggedIn'} && !$self->{'failedLogins'}) {
        my ($type,$len,$packet) = $self->NextPacket();
        $self->Dispatch($type,$len,$packet);
    }
    if ($self->{'loggedIn'}) {
        my $IKnowMe = 0;
        while(!$IKnowMe) {
            my ($type,$len,$packet) = $self->NextPacket();
            $self->Dispatch($type,$len,$packet);
            my $myID = $self->{'my_id'};
            $IKnowMe = (defined($myID) && defined($self->{'actorsByID'}->{$myID}));
        }
    }
    return $self->{'loggedIn'};
}

sub NextPacket
{
    my $self = shift;

    my ($hdr,$type,$len,$data) = (undef,undef,undef,undef);

    my $rin = ""; my $rout;
    vec($rin, fileno($self->{'socket'}), 1) = 1;
    my $nfound = select($rout=$rin, undef, undef, 2);
    if ($nfound) {
        read($self->{'socket'},$hdr,3);
        $type = substr($hdr,0,1);
        $len = unpack('v',substr($hdr,1,2))-1;
        read($self->{'socket'},$data,$len);
        ($self->{'debug'} & $DEBUG_PACKETS) &&
            $self->Log("Read Data: ".$self->packetAsHex($hdr.$data));
        ($self->{'debug'} & $DEBUG_TYPES) &&
            $self->Log("Read packet '".$ClientCommandsByID{$type}."'");
    }
    else {
        $self->keepAlive(0);
    }

    return ($type,$len,$data);
}

sub Dispatch
{
    my $self = shift;
    my ($type,$len,$data) = @_;
    my $ret = undef;

    defined($type) || return undef;

    my $typeStr = $ClientCommandsByID{$type};
    my $fn = $self->can($typeStr);
    if (defined($fn)) {
        ($self->{'debug'} & $DEBUG_TYPES) &&
            $self->Log("Dispatching packet '".$typeStr."'");
        $ret = &{$fn}($self,$type,$len,$data);
    }
    else {
        ($self->{'debug'} & $DEBUG_TYPES) &&
            $self->Log("Unhandled packet '".$typeStr."'");
    }
    if ($fn = $self->can("postDispatch")) {
        &{$fn}($self,$type,$len,$data);
    }
    $self->keepAlive(0);

    return $ret;
}

return 1;
