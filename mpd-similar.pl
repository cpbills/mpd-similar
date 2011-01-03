#!/usr/bin/perl

# script to generate a playlist from a given track using audioscrobber to find
# similar tracks and in the event that doesn't work, similar artists...
# in theory it will find a few tracks for the given track, and then find tracks
# for the tracks found, somewhat recursively.

# track.getsimilar&artist=artist&track=track&limit=50&api_key=key
# artist.getsimilar&artist=artist&limit=20&api_key=key

#use strict;
use warnings;

use XML::Simple;
use LWP::Simple;
use Audio::MPD;

my $KEY         = 'api key goes here';
my $TRACK_URL   = 'http://ws.audioscrobbler.com/2.0/?method=track.getsimilar';
my $ARTIST_URL  = 'http://ws.audioscrobbler.com/2.0/?method=artist.getsimilar';
my $T_LIMIT     = 5;
my $A_LIMIT     = 5;

my $MPD_HOST    = 'localhost';
my $MPD_PORT    = '6600';
my $MPD_PASS    = '';

my $mpd = Audio::MPD->new(host      =>  $MPD_HOST,
                          port      =>  $MPD_PORT,
                          password  =>  $MPD_PASS);

my $song = $mpd->current;

my $artist = $$song{artist};
my $track  = $$song{title};

my $url = "$TRACK_URL&artist=$artist&track=$track&limit=$T_LIMIT&api_key=$KEY";
my $xml = new XML::Simple;
my $results = $xml->XMLin(get($url));

my @matches = ();
if ($$results{status} eq 'ok') {
    foreach my $track (@{$$results{similartracks}{track}}) {
        if (ref($track) eq 'HASH') {
            my $artist  = $$track{artist}{name};
            my $title   = $$track{name};
            push(@matches,"$artist$title");
        }
    }
}
fisher_yates_shuffle(\@matches);
foreach my $song (@matches) {
    my ($artist,$title) = split(//,$song);
    print "artist: $artist\ntitle: $title\n";
    my @found = grep { /$title/ } $mpd->collection->songs_by_artist($artist);
    foreach my $find (@found) {
        print "$find\n";
    }
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
