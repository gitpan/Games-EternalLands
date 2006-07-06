
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME      => 'Games::EternalLands',
    ABSTRACT  => 'Client for the MMORPG Eternal Lands',
    VERSION   => 'lib/Games/EternalLands/Client.pm',
    AUTHOR    => 'Franc Carter <franc.carter@gmail.com>',
    PREREQ_PM => {
                     'AI::Pathfinding::AStar' => 0,
                 }
);
