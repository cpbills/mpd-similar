#!/usr/bin/perl

# script to generate a playlist from a given track using audioscrobber to find
# similar tracks and in the event that doesn't work, similar artists...
# in theory it will find a few tracks for the given track, and then find tracks
# for the tracks found, somewhat recursively.

# track.getsimilar&artist=artist&track=track&limit=50&api_key=key
# artist.getsimilar&artist=artist&limit=20&api_key=key

use strict;
no strict "refs";
use warnings;

use XML::Simple;
use LWP::Simple;
use Audio::MPD;

$| = 42;

my $SIZE        = 100;
my $KEY         = 'api key goes here';
my $TRACK_URL   = 'http://ws.audioscrobbler.com/2.0/?method=track.getsimilar';
my $ARTIST_URL  = 'http://ws.audioscrobbler.com/2.0/?method=artist.getsimilar';
my $ARTIST_ALT  = 'http://ws.audioscrobbler.com/2.0/artist/ARTIST/similar.txt';
my $T_LIMIT     = 50;
my $A_LIMIT     = 20;
my $DELIMITER   = '';

my $MPD_HOST    = 'localhost';
my $MPD_PORT    = '6600';
my $MPD_PASS    = '';

$SIZE = $ARGV[0] if ($ARGV[0] =~ /[0-9]+/);

my $mpd = Audio::MPD->new(host      =>  $MPD_HOST,
                          port      =>  $MPD_PORT,
                          password  =>  $MPD_PASS);

# playlist hash holds the playlist, we can easily check for collisions when
# adding new tracks. the similar hash will hold the results found from looking
# for similar tracks to reduce the lookup time while building the playlist.
my %PLAYLIST    = ();
my %SIMILAR     = ();

my $current     = $mpd->current;

$PLAYLIST{$$current{file}} = 1;

while ($SIZE >= scalar(keys %PLAYLIST)) {
    my @playlist = keys %PLAYLIST;
    fisher_yates_shuffle(\@playlist);
    my $file = pop(@playlist);
    
    my $song = $mpd->collection->song($file);
    my $artist  = $$song{artist};
    my $track   = $$song{title};

    print "similar to $artist - $track...\n";

    my @songs = ();
    @songs = @{$SIMILAR{$file}} if ($SIMILAR{$file});
    if (@songs == 0) {
        # we have an API key, we can find similar tracks, not just artists!
        @songs = get_sim_tracks($artist,$track,$T_LIMIT,$KEY,$mpd) if ($KEY);

        # find songs using only similar artist if the search for
        # similar tracks yeilded no results.
        @songs = get_sim_artists($artist,$A_LIMIT,$KEY,$mpd) if (@songs == 0);
    }
    $SIMILAR{$file} = \@songs;

    fisher_yates_shuffle(\@songs);
    
    # i'm debating whether or not to /make/ a song get added to the playlist
    # right now, we just set the hash key to 1, so if the song was already
    # on the playlist, oh well. this has the advantage of us not getting stuck
    # in an infinite loop when there aren't enough songs to add, or if they all
    # already exist on the playlist.
    my $new_song = pop(@songs);
    my $info = $mpd->collection->song($new_song);
    my $new_artist = $$info{artist};
    my $new_title  = $$info{title};
    print "\t...$new_artist - $new_title\n";
    $PLAYLIST{$new_song} = 1;
}

$mpd->playlist->clear;
print "playlist:\n";
my @files = keys %PLAYLIST;
fisher_yates_shuffle(\@files);
foreach my $file (@files) {
    my $info = $mpd->collection->song($file);
    $mpd->playlist->add($file);
    my $artist = $$info{artist};
    my $title  = $$info{title};
    print "\t$artist - $title\n";
}
$mpd->playlist->shuffle;
$mpd->play;

sub get_sim_tracks {
    my $artist  =   shift;
    my $track   =   shift;
    my $limit   =   shift;
    my $key     =   shift;
    my $mpd     =   shift;

    my $params = "&artist=$artist&track=$track&limit=$limit&api_key=$key";
    my $xml = new XML::Simple;
    my $results = $xml->XMLin(get("$TRACK_URL$params"));

    my @similar = ();
    if ($$results{status} eq 'ok') {
        foreach my $track (@{$$results{similartracks}{track}}) {
            if (ref($track) eq 'HASH') {
                my $artist  = $$track{artist}{name};
                my $title   = $$track{name};
                push(@similar,"$artist$DELIMITER$title");
            }
        }
    }

    my @finds = ();
    foreach my $song (@similar) {
        my ($artist,$title) = split(/$DELIMITER/,$song);
        my @songs_by_artist = $mpd->collection->songs_by_artist($artist);
        push(@finds,grep { /$title/ } @songs_by_artist);
    }
    return map($_->file,@finds);
}

sub get_sim_artists {
    my $artist  =   shift;
    my $limit   =   shift;
    my $key     =   shift;
    my $mpd     =   shift;
    
    my @similar = ( $artist );

    if ($key and $key ne '') {
        my $params = "&artist=$artist&limit=$limit&api_key=$key";
        my $xml = new XML::Simple;
        my $results = $xml->XMLin(get("$ARTIST_URL$params"));
        
        if ($$results{status} eq 'ok') {
            foreach my $s_artist (@{$$results{similarartists}{artist}}) {
                push(@similar,$$s_artist{name}) if (ref $s_artist eq 'HASH');
            }
        }
    } else {
        my $url = $ARTIST_ALT;
        $url =~ s/ARTIST/$artist/;
        my @lines = split(/\n/,get($url));

        # map basically generates an array by applying the 'split' to each
        # item of @lines, it's a 'slick' way to do a foreach loop, without
        # the loop. this is mostly a note for myself, because i don't use
        # map too often, and i wanted to be clever...
        @similar = map((split(/,/,$_))[2],@lines);
    }

    my @songs = ();
    foreach my $s_artist (@similar) {
        push(@songs,$mpd->collection->songs_by_artist($s_artist));
    }
    return map($_->file,@songs);
}

sub fisher_yates_shuffle {
    my $array = shift;
    my $i;
    for ($i = @$array; --$i; ) {
        my $j = int rand ($i+1);
        next if $i == $j;
        @$array[$i,$j] = @$array[$j,$i];
    }
}

sub find_local_songs {
    my $mpd = shift;
    my @songs_to_find = @_;

    my @finds = ();
    foreach my $song (@songs_to_find) {
        my ($artist,$title) = split(/$DELIMITER/,$song);
        my @songs_by_artist = $mpd->collection->songs_by_artist($artist);
        push(@finds,grep { /$title/ } @songs_by_artist);
    }
    return map($_->file,@finds);
}
