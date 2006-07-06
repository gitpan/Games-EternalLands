package Games::EternalLands::Bot;

use strict;
use IO::Socket;
use POSIX;
use YAML;
use Games::EternalLands::Client;
use Data::Dumper;
use vars qw(@ISA);

@ISA = qw(Games::EternalLands::Client);

use Games::EternalLands::Constants qw(%ServerCommands %ClientCommands %ActorCommandsByID
                                      %ClientCommandsByID %ActorTypesByID);

################################################


################################################
sub contains
{
    my $self = shift;
    my ($hash,$item) = @_;

    foreach my $pos (keys %{$hash}) {
         if ($hash->{$pos}->{'name'} eq $item) {
             return $hash->{$pos};
         }
    }
    return undef;
}

sub isAdmin
{
    my $self = shift;
    my ($user) = @_;

    foreach my $admin (@{$self->{'admins'}}) {
        if ($user eq $admin) {
            return 1;
        }
    }
    return 0;
}

sub tradeUserOk
{
    my $self = shift;
    my ($user) = @_;

    my $tradeWith = $self->{'tradeWith'};
    if (!defined($tradeWith)) {
        $self->send('SEND_PM',$user." Start trading with me before asking for items.");
        return 0 ;
    }
    if  ($tradeWith ne $user) {
        $self->send('SEND_PM',$user." Sorry, I am already trading with someone else.");
        $self->send('SEND_PM',$user," Please try again in while.");
        return 0;
    }
    return 1;
}


###########################################################
#
###########################################################

sub qtyToBuy
{
    my $self = shift;
    my ($name) = @_;

    my $qty    = $self->{'itemsToBuy'}->{$name}->[0];
    my $price  = $self->{'itemsToBuy'}->{$name}->[1];
    my $gc     = $self->{'invByName'}->{'gold coins'};

    $gc = defined($gc) ? $gc->{'quantity'} : 0;

    return (floor($price * $qty) > $gc) ? floor($gc/$price) : $qty;
}

sub qtyInStock
{
    my $self = shift;
    my ($name) = @_;

    if (!defined($self->{'invByName'}->{$name})) {
        return 0;
    }
    if (!defined($self->{'itemsToSell'}->{$name})) {
        return 0;
    }
    my $onHand = $self->{'invByName'}->{$name}->{'quantity'};
    my $toSell = $self->{'itemsToSell'}->{$name}->[0];
    if (defined($self->{'myTrades'}->{$name})) {
         $toSell -= $self->{'myTrades'}->{$name}->{'quantity'};
         $onHand -= $self->{'myTrades'}->{$name}->{'quantity'};
    }
    return ($toSell > $onHand) ? $onHand : $toSell;
}

sub chkTrade
{
    my $self = shift;
    my ($trades,$wants) = @_;


    my $user        = $self->{'tradeWith'};
    my %thereTrades = %{$self->{'thereTrades'}}; # Copy so we can modify it
    my $IWant       = $self->{'IWant'};

    # check if what we want matches what we were given
    my $tradeOk = 1;
    foreach my $want (keys %{$IWant}) {
        my $qty = $IWant->{$want};
        my $item = $self->contains(\%thereTrades,$want);
        if (defined($item)) {
            $qty -= $item->{'quantity'};
            delete $thereTrades{$item->{'pos'}};
        }
        if ($qty > 0) {
            $self->send('SEND_PM', "$user I still need $qty more $want");
            $tradeOk = 0;
        }
        elsif ($qty < 0) {
            $qty *= -1;
            $self->send('SEND_PM', "$user you have given me $qty too many $want");
            $tradeOk = 0;
        }
    }
    foreach my $pos (keys %thereTrades) {
        my $name = $thereTrades{$pos}->{'name'};
        $self->send('SEND_PM', "$user $name is not something you are giving/selling to me");
        $tradeOk = 0;
    }

    return $tradeOk;
}

sub Advertise
{
    my $self = shift;

    my $toSell  = $self->{'itemsToSell'};
    my @forSale = (keys %{$toSell});
    @forSale    = sort {$toSell->{$a}->[2] <=> $toSell->{$b}->[2]} @forSale;
    my $item    = $forSale[0];
    my $qty     = $self->qtyInStock($item);
    my $price   = $toSell->{$item}->[1];

    if ($qty > 0) {
        $self->Say('@@3 I am selling '."$qty $item for $price"."gc each");
    }

    $toSell->{$item}->[2] = time();
    if (defined($self->{'sellingFile'})) {
        YAML::DumpFile($self->{'sellingFile'}, $self->{'itemsToSell'});
    }
}

sub handleHelp
{
    my $self = shift;
    my ($user) = @_;

    my $help = $self->isAdmin($user) ? $self->{'adminhelp'} : $self->{'help'};
    if (defined($help)) {
        foreach my $line (@{$help}) {
            $self->send('SEND_PM', "$user $line");
        }
    }
}

sub handleDump
{
    my $self = shift;
    my ($user) = @_;

    print STDERR Dumper($self);
}

sub handleInv
{
    my $self = shift;
    my ($user,$item_re) = @_;

    my @items = keys %{$self->{'itemsToSell'}};
    if (defined($item_re)) {
        @items = grep(/$item_re/, @items);
    }
    my $n = 0;
    foreach my $name (@items) {
        my $item = $self->{'invByName'}->{lc($name)};
        if (defined($item)) {
            my $qty = $self->qtyInStock($name);
            if ($qty > 0) {
                my $price     = $self->{'itemsToSell'}->{$name}->[1];
                $self->send('SEND_PM', "$user $qty $name at ".$price."gc each");
                $n++;
            }
        }
    }
    if ($n == 0) {
        $self->send('SEND_PM', "$user I am not selling anything at the moment");
    }
}

sub handleWanted
{
    my $self = shift;
    my ($user,$item_re) = @_;

    my @items = keys %{$self->{'itemsToBuy'}};
    if (defined($item_re)) {
        @items = grep(/$item_re/, @items);
    }
    my $n = 0;
    foreach my $name (@items) {
        my $qty = $self->qtyToBuy($name);
        if ($qty > 0) {
            my $price = $self->{'itemsToBuy'}->{$name}->[1];
            $self->send('SEND_PM', "$user $qty $name at ".$price."gc each");
            $n++;
        }
    }
    if ($n == 0) {
        $self->send('SEND_PM', "$user I am not buying anything at the moment");
    }
}

sub handleListStock
{
    my $self = shift;
    my ($user) = @_;

    foreach my $name (keys %{$self->{'invByName'}}) {
        my $qty = $self->{'invByName'}->{$name}->{'quantity'};
        my $txt = "$user I have $qty $name";
        $self->send('SEND_PM', $txt);
    }
}

sub handleListWant
{
    my $self = shift;
    my ($user) = @_;

    foreach my $name (keys %{$self->{'IWant'}}) {
        my $qty = $self->{'IWant'}->{$name};
        $self->send('SEND_PM', "$user I want $qty $name");
    }
}

sub handleListBuySell
{
    my $self = shift;
    my ($user,$action) = @_;

    my $list = ($action eq "sell") ? $self->{'itemsToSell'} : $self->{'itemsToBuy'};

    my @items = keys %{$list};
    foreach my $name (@items) {
        my $qty    = $list->{$name}->[0];
        my $price  = $list->{$name}->[1];
        $self->send('SEND_PM', "$user $qty $name at ".$price."gc each");
    }
}

sub handleDoNotSell
{
    my $self = shift;
    my ($user,$item) = @_;

    if (defined($self->{'itemsToSell'}->{$item})) {
        undef $self->{'itemsToSell'}->{$item};
        if (defined($self->{'sellingFile'})) {
            YAML::DumpFile($self->{'sellingFile'}, $self->{'itemsToSell'});
        }
    }
}

sub handleDoNotBuy
{
    my $self = shift;
    my ($user,$item) = @_;

    if (defined($self->{'itemsToBuy'}->{$item})) {
        undef $self->{'itemsToBuy'}->{$item};
        if (defined($self->{'buyingFile'})) {
            YAML::DumpFile($self->{'buyingFile'}, $self->{'itemsToBuy'});
        }
    }
}

sub handleUpdateSell
{
    my $self = shift;
    my ($user,$qty,$item,$price) = @_;
    $self->{'itemsToSell'}->{$item} = [$qty,$price,0];
    if (defined($self->{'sellingFile'})) {
        YAML::DumpFile($self->{'sellingFile'}, $self->{'itemsToSell'});
    }
}

sub handleUpdateBuy
{
    my $self = shift;
    my ($user,$qty,$item,$price) = @_;
    $self->{'itemsToBuy'}->{$item} = [$qty,$price,0];
    if (defined($self->{'buyingFile'})) {
        YAML::DumpFile($self->{'buyingFile'}, $self->{'itemsToBuy'});
    }
}

sub handleBuy
{
    my $self = shift;
    my ($user,$qty,$name) = @_;

    $self->tradeUserOk($user) || return;

    $name =~ s/\s{2,}/ /g;
    my $sell = $self->{'itemsToSell'}->{$name};
    if (!defined($sell)) {
        $self->send('SEND_PM', "$user Sorry, I don't have any $name");
        return;
    }
    my $nSell = $self->qtyInStock($name);
    if ($nSell < $qty) {
        $self->send('SEND_PM', "$user Sorry, I only have ".$nSell." $name");
        return;
    }
    my $price = ceil($qty * $sell->[1]);
    $self->send('SEND_PM', "$user $qty $name will cost you ".$price."gc");
    $self->{'IWant'}->{'gold coins'} += $price;
    $self->{'mySells'}->{$name} += $qty;

    my $pos  = $self->{'invByName'}->{$name}->{'pos'};
    my $data = pack('CCV',1,$pos,$qty);
    $self->send('PUT_OBJECT_ON_TRADE',$data);
}

sub handleSell
{
    my $self = shift;
    my ($user,$qty,$name) = @_;

    $self->tradeUserOk($user) || return;

    $name =~ s/\s{2,}/ /g;
    my $buy = $self->{'itemsToBuy'}->{$name};
    if (!defined($buy)) {
        $self->send('SEND_PM', "$user Sorry, I am not buying $name");
        return;
    }
    my $nBuy = $self->qtyToBuy($name);
    if ($nBuy < $qty) {
        $self->send('SEND_PM', "$user Sorry, I am only buying ".$nBuy." $name");
        return;
    }
    my $price = floor($qty * $buy->[1]);
    $self->send('SEND_PM', "$user I will pay $price"."gc for $qty $name");
    $self->{'IWant'}->{$name} += $qty;
    $self->{'myBuys'}->{$name} += $qty;

    my $pos  = $self->{'invByName'}->{'gold coins'}->{'pos'};
    my $data = pack('CCV',1,$pos,$price);
    $self->send('PUT_OBJECT_ON_TRADE',$data);
}

sub handleGiveMe
{
    my $self = shift;
    my ($user,$qty,$name) = @_;

    $self->tradeUserOk($user) || return;
     
    my $give = $self->{'invByName'}->{$name};
    if (!defined($give)) {
        $self->send('SEND_PM', "$user Sorry, I don't have any $name");
    }
    else {
        if ($qty > $give->{'quantity'}) {
            $self->send('SEND_PM', "$user Sorry, I only have ".$give->{'quantity'}." $name");
        }
        else {
            my $data = pack('CCV',1,$give->{'pos'},$qty);
            $self->send('PUT_OBJECT_ON_TRADE',$data);
        }
    }
}
sub handleUseInv
{
    my $self = shift;
    my ($user,$name) = @_;

    my $item = $self->{'invByName'}->{$name};
    if (!defined($item)) {
        $self->send('SEND_PM', "$user Sorry, I don't have a $name to use");
        return;
    }
    else {
        $self->send('USE_INVENTORY_ITEM',pack('v',$item->{'pos'}));
    }
}

sub handleUseMapObject
{
    my $self = shift;
    my ($objID) = @_;

print STDERR "Using map object $objID";

    $self->send('USE_MAP_OBJECT',pack('Vl',$objID,-1));
}

sub handleTouchPlayer
{
    my $self = shift;
    my ($id) = @_;

print STDERR "Touching player $id";

    $self->send('TOUCH_PLAYER',pack('l',$id));
}

sub handleRespondToNPC
{
    my $self = shift;
    my ($actor,$response) = @_;

    $self->send('RESPOND_TO_NPC',pack('vv',$actor,$response));
}

sub handleStats
{
    my $self = shift;

    my ($user) = @_;

    foreach my $stat ('mp','ep','food','carry') {
        my $cur  = $self->{'stats'}->{$stat}->[0];
        my $base = $self->{'stats'}->{$stat}->[1];
        my $msg = sprintf("%s %s: %d/%d",$user,$stat,$cur,$base);
        $self->send('SEND_PM',$msg);
    }
}

sub handlePM
{
    my $self = shift;
    my ($user,$msg) = @_;

    if ($msg =~ m/^\s*loc\s*$/i) {
        my $me = $self->{'actorsByID'}->{$self->{'my_id'}};
        my ($x,$y) = ($me->{'xpos'},$me->{'ypos'});
        $self->send('SEND_PM', "$user ($x,$y)");
    }
    if ($msg =~ m/^\s*owner\s*$/i) {
        $self->send('SEND_PM', "$user ".$self->{'owner'});
    }
    elsif ($msg =~ m/^\s*buy\s+(\d+)\s+(\w.*\w)\s*$/i) {
        $self->handleBuy($user,$1,lc($2));
    }
    elsif ($msg =~ m/^\s*sell\s+(\d+)\s+(\w.*\w)\s*$/i) {
        $self->handleSell($user,$1,lc($2));
    }
    elsif ($msg =~ m/^\s*donate\s+(\d+)\s+(\w.*\w)\s*$/i) {
        if ($self->tradeUserOk($user)) {
            $self->{'IWant'}->{$2} += $1;
        }
    }
    elsif ($msg =~ m/^\s*wanted\s*$/i) {
        $self->handleWanted($user,undef);
    }
    elsif ($msg =~ m/^\s*inv\s+(\w|\w.*\w)\s*$/i) {
        $self->handleInv($user,$1);
    }
    elsif ($msg =~ m/^\s*inv\s*$/i) {
        $self->handleInv($user,undef);
    }
    elsif ($msg =~ m/^\s*help\s*$/i) {
        $self->handleHelp($user);
    }
    elsif ($self->isAdmin($user)) {
        if ($msg =~ m/^\s*list\s+stock\s*$/i) { #
            $self->handleListStock($user);
        }
        elsif ($msg =~ m/^\s*list\s+sells{0,1}\s*$/i) { #
            $self->handleListBuySell($user,"sell");
        }
        elsif ($msg =~ m/^\s*list\s+buys{0,1}\s*$/i) { #
            $self->handleListBuySell($user,"buy");
        }
        elsif ($msg =~ m/^\s*list\s+wants{0,1}\s*$/i) { #
            $self->handleListWant($user);
        }
        elsif ($msg =~ m/give\s+me\s+(\d+)\s+(\w.*\S)\s*$/i) {
            $self->handleGiveMe($user,$1,lc($2));
        }
        elsif ($msg =~ m/^\s*do\s+not\s+sell\s+(\w.*\w)\s*$/i) {
            $self->handleDoNotSell($user,$1);
        }
        elsif ($msg =~ m/^\s*do\s+not\s+buy\s+(\w.*\w)\s*$/i) {
            $self->handleDoNotBuy($user,$1);
        }
        elsif ($msg =~ m/\s*update\s+sell\s+(\d+)\s+(\w.*\S)\s+(for|at)\s+(\d+)gc*/i) {
            $self->handleUpdateSell($user,$1,$2,$4);
        }
        elsif ($msg =~ m/\s*update\s+buy\s+(\d+)\s+(\w.*\S)\s+(for|at)\s+(\d+)gc*/i) {
            $self->handleUpdateBuy($user,$1,$2,$4);
        }
        elsif ($msg =~ m/^\s*sit\s+down\s*$/) {
            $self->send('SIT_DOWN',pack('C',1));
        }
        elsif ($msg =~ m/^\s*stand\s+up\s*/) {
            $self->send('SIT_DOWN',pack('C',0));
        }
        elsif ($msg =~ m/^\s*move\s+to\s+(\d+)\,(\d+)\s*/) {
            $self->moveTo($1,$2);
        }
        elsif ($msg =~ m/\s*say\s(\S.*\S)\s*/) {
            $self->Say($1);
        }
        elsif ($msg =~ m/\s*stats\s*$/) {
            $self->handleStats($user);
        }
        elsif ($msg =~ m/\s*use\s+map\s+object\s+(\d+)\s*$/) {
            $self->handleUseMapObject($1);
        }
        elsif ($msg =~ m/\s*use\s+(.*\S)\s*$/) {
            $self->handleUseInv($user,$1);
        }
        elsif ($msg =~ m/\s*touch\s+player\s+(\d+)\s*$/) {
            $self->handleTouchPlayer($1);
        }
        elsif ($msg =~ m/\s*respond\s+to\s+(\d+)\s+with\s+(\d+)\s*$/) {
            $self->handleRespondToNPC($1,$2);
        }
        elsif ($msg =~ m/\s*dump\s+(.*\S)\s*$/) {
            $self->handleDump($user,$1);
        }
        else {
            $self->send('SEND_PM',$user." Sorry, I don't understand.");
            $self->send('SEND_PM',$user." PM me with HELP for a list of commands");
        }
    }
    else {
        $self->send('SEND_PM',$user." Sorry, I don't understand.");
        $self->send('SEND_PM',$user." PM me with HELP for a list of commands");
    }
}

sub distance($$$$)
{
    my ($x1,$y1,$x2,$y2) = @_;

    my $x = ($x1-$x2);
    my $y = ($y1-$y2);

    return sqrt($x*$x+$y*$y);
}

sub moveTo
{
    my $self = shift;
    my ($toX,$toY) = @_;

    my $me  = $self->{'actorsByID'}->{$self->{'my_id'}};
    my $map = $self->{'Map'};
    my $d   = $map->distance($me->{'xpos'},$me->{'ypos'},$toX,$toY);
    if ($d <= 10) {
        $self->SUPER::moveTo($toX,$toY);
    }
    else {
        my $from = $me->{'xpos'}.",".$me->{'ypos'};
        my $to   = $toX.",".$toY;
        my $path = $map->findPath($from,$to);

        my ($x,$y);
        my ($fromX,$fromY) = split(',',$path->[0]);
        my @path = ([$fromX,$fromY]);
        foreach my $p (@{$path}) {
            ($x,$y) = split(',',$p);
            if ($map->distance($fromX,$fromY,$x,$y) > 8) {
                push(@path,[$x,$y]);
                ($fromX,$fromY) = ($x,$y);
            }
        }
        push(@path,[$x,$y]);
        $self->{'path'} = \@path;
    }
}

sub logPath
{
    my $self = shift;
    my ($path) = @_;

    my @path = ();
    foreach my $p (@$path) {
        push(@path,"($p->[0],$p->[1])");
    }
    my $pathStr = join(' ==> ',@path);
    $self->Log($pathStr);
}

sub postDispatch
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    my $path = $self->{'path'};
    if (defined($path)) {
        my $me   = $self->{'actorsByID'}->{$self->{'my_id'}};
        my $next = $path->[0];
#$self->logPath($path);

        if ($next->[0] == $me->{'xpos'} and $next->[1] == $me->{'ypos'}) {
            if ($#{$path} > 0)  {
                shift (@{$self->{'path'}});
                my $x = $path->[0]->[0];
                my $y = $path->[0]->[1];
                $self->moveTo($path->[0]->[0],$path->[0]->[1]);
            }
            else {
                $self->{'path'} = undef;
            }
        }
    }
}
    
################################################################
# TRADE RELATED CALLBACKS                                      #
################################################################

sub GET_YOUR_TRADEOBJECTS
{
    my $self = shift;
    my ($type,$len,$data) = @_;
}

sub GET_TRADE_ACCEPT
{
    my $self = shift;
    my ($type,$len,$data) = @_;

    my $who = unpack('C', $data);
    if ($who) {
        $self->{'tradeOk'} = $self->chkTrade($self->{'thereTrades'},$self->{'IWant'});
        if ($self->{'tradeOk'}) {
            $self->SUPER::GET_TRADE_ACCEPT($type,$len,$data); 
        }
    }
}

sub GET_TRADE_EXIT
{
    my $self = shift;

    if ($self->{'tradeAccepted'} == 2) {
        foreach my $name (keys %{$self->{'mySells'}}) {
            $self->{'itemsToSell'}->{$name}->[0] -= $self->{'mySells'}->{$name};
        }
        foreach my $name (keys %{$self->{'myBuys'}}) {
            $self->{'itemsToBuy'}->{$name}->[0] -= $self->{'myBuys'}->{$name};
        }
    }
    $self->{'IWant'}         = {};
    $self->{'mySells'}       = {};
    $self->{'myBuys'}        = {};

    if (defined($self->{'sellingFile'})) {
        YAML::DumpFile($self->{'sellingFile'}, $self->{'itemsToSell'});
    }
    $self->SUPER::GET_TRADE_EXIT(@_); 
}

################################################################
# INVENTORY RELATED CALLBACKS                                  #
################################################################

sub processArgs
{
    my $self = shift;
    my @args  = @_;
    my @notUsed = ();

    while(my $arg = shift @args) {
        if ($arg eq '-server') {
            $self->{'server'} = shift @args; }
        elsif ($arg eq '-port') {
            $self->{'port'} = shift @args; }
        elsif ($arg eq '-admins') {
            my $admins = shift @args;
            my @admins = split(',',$admins);
            $self->{'admins'} = \@admins;
        }
        elsif ($arg eq '-buyingFile') {
            $self->{'buyingFile'} = shift @args; }
        elsif ($arg eq '-sellingFile') {
            $self->{'sellingFile'} = shift @args; }
        elsif ($arg eq '-helpFile') {
            $self->{'helpFile'} = shift @args; }
        elsif ($arg eq '-adminHelpFile') {
            $self->{'adminHelpFile'} = shift @args; }
        elsif ($arg eq '-msgInterval') {
            $self->{'msgInterval'} = shift @args; }
        elsif ($arg eq '-owner') {
            $self->{'owner'} = shift @args; }
        elsif ($arg eq '-location') {
            $self->{'location'} = shift @args; }
        else {
            push(@notUsed,$arg);
        }
    }
    return @notUsed;
}

sub readHelp
{
    my $self = shift;
    my ($fname) = @_;
    my @lines = ();

    if (defined($fname)) {
        if (open(FP,$fname)) {
            while(<FP>) {
                chomp $_;
                push(@lines, $_);
            }
        }
        else {
            $self->Log("Coud not open $fname for reading\n");
        }
    }
    return \@lines;
}

sub new
{
    my $class  = shift;
    my ($self) = Games::EternalLands::Client->new(@_);
    bless($self, $class);

    $self->{'admin'}             = [];

    $self->{'helpFile'}          = undef;
    $self->{'adminHelpFile'}     = undef;
    $self->{'help'}              = undef;
    $self->{'adminhelp'}         = undef;
    $self->{'owner'}             = "No owner defined";
    $self->{'location'}          = "No location defined";

    $self->{'buyingFile'}        = undef;
    $self->{'sellingFile'}       = undef;
    $self->{'itemsToSell'}       = {};
    $self->{'itemsToBuy'}        = {};
    $self->{'lastMsgAt'}         = time(); # no msg on startup
    $self->{'msgInterval'}       = 20;     # minutes

    $self->{'IWant'}             = {};
    $self->{'tradingWith'}       = undef;
    $self->{'myTrades'}          = {};
    $self->{'mySells'}           = {};
    $self->{'thereTrades'}       = {};
    $self->{'tradeOk'}           = 0;
    $self->{'tradeAccepted'}     = 0;

    @_ = $self->processArgs(@_);

    $self->{'help'} = $self->readHelp($self->{'helpFile'});
    $self->{'adminhelp'} = $self->readHelp($self->{'adminHelpFile'});

    if (defined($self->{'sellingFile'}) and (-e $self->{'sellingFile'})) {
        $self->{'itemsToSell'} = YAML::LoadFile($self->{'sellingFile'});
    }
    if (defined($self->{'buyingFile'}) and (-e $self->{'buyingFile'})) {
        $self->{'itemsToBuy'}  = YAML::LoadFile($self->{'buyingFile'});
    }

    return $self;
}

return 1;
