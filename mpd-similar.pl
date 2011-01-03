#!/usr/bin/perl

# script to generate a playlist from a given track using audioscrobber to find
# similar tracks and in the event that doesn't work, similar artists...
# in theory it will find a few tracks for the given track, and then find tracks
# for the tracks found, somewhat recursively.

# track.getsimilar&artist=artist&track=track&limit=50&api_key=key
# artist.getsimilar&artist=artist&limit=20&api_key=key

use strict;
use warnings;

use XML::Simple;
use LWP::Simple;
use Audio::MPD;

my $KEY         = 'api key goes here';
my $TRACK_URL   = 'http://ws.audioscrobbler.com/2.0/?method=track.getsimilar';
my $ARTIST_URL  = 'http://ws.audioscrobbler.com/2.0/?method=artist.getsimilar';
my $ARTIST_ALT  = 'http://ws.audioscrobbler.com/2.0/artist/ARTIST/similar.txt';
my $T_LIMIT     = 100;
my $A_LIMIT     = 30;
my $DELIMITER   = '';

my $MPD_HOST    = 'localhost';
my $MPD_PORT    = '6600';
my $MPD_PASS    = '';

my $mpd = Audio::MPD->new(host      =>  $MPD_HOST,
                          port      =>  $MPD_PORT,
                          password  =>  $MPD_PASS);

my $song    = $mpd->current;
my $artist  = $$song{artist};
my $track   = $$song{title};

print "finding songs similar to $artist - $track...\n";

# array of similar songs we have on hand
my @songs = ();
# we have an API key, we can find similar tracks, not just artists!
@songs = get_similar_tracks($artist,$track,$T_LIMIT,$KEY,$mpd) if ($KEY ne '');

# find songs using only similar artist if the search for
# similar tracks yeilded no results.
@songs = get_similar_artists($artist,$A_LIMIT,$KEY,$mpd) if (@songs == 0);

fisher_yates_shuffle(\@songs);
foreach my $song (@songs) {
    print "$song\n";
}

sub get_similar_tracks {
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

sub get_similar_artists {
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
