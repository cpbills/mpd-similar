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
use URI::Escape;

my $SIZE        = 10;   # number of tracks to try to add, by default
   $SIZE        = $ARGV[0] if ($ARGV[0] && $ARGV[0] =~ /[0-9]+/);
my $CROP        = 0;    # leave the current song and remove everything else
my $CLEAR       = 0;    # completely clear the playlist
my $AUTOPLAY    = 1;    # attempt to resume / start play after adding a song
my $SHUFFLE     = 0;    # shuffle playlist after each song is added.

my $KEY         = 'api key goes here';
my $TRACK_URL   = 'http://ws.audioscrobbler.com/2.0/?method=track.getsimilar';
my $ARTIST_URL  = 'http://ws.audioscrobbler.com/2.0/?method=artist.getsimilar';
my $ARTIST_ALT  = 'http://ws.audioscrobbler.com/2.0/artist/ARTIST/similar.txt';
my $T_LIMIT     = 100;  # number of similar tracks to limit our search to
my $A_LIMIT     = 30;   # number of similar artists to limit our search to
my $DELIMITER   = ''; # ctrl-_ is a useful delimiter

my $MPD_HOST    = 'localhost';
my $MPD_PORT    = '6600';
my $MPD_PASS    = '';

my $artist      = '';
my $title       = '';

# TODO: Getopts or Getopts::Long to allow/accept artist/title on command line
# and mpd config options...

my $MPD         = Audio::MPD->new(host      =>  $MPD_HOST,
                                  port      =>  $MPD_PORT,
                                  password  =>  $MPD_PASS);

my $current     = $MPD->song;
my $file        = '';
if ($current) {
    $artist     = $$current{artist};
    $title      = $$current{title};
    $file       = $$current{file};
}

# we don't NEED a title to go with the artist, but we /do/ need $artist
unless ($artist) {
    print "no artist information provided or available from mpd playlist";
    exit 1;
}

# the similar hash will hold the results found from looking for similar
# tracks to reduce the lookup time while building the playlist.
my %SIMILAR     = ();

$MPD->playlist->crop    if ($CROP);
$MPD->playlist->clear   if ($CLEAR);

my @playlist = $MPD->playlist->as_items;
$SIZE += scalar(@playlist);
# create the playlist hash to handle detection if a
# song is already in the playlist.
my %PLAYLIST = map { $_->file, 1 } @playlist;

while (scalar(keys %PLAYLIST) < $SIZE) {
    my $song = get_similar($artist,$title,$file);
    if ($song) {
        $MPD->playlist->add($song);
        $MPD->play unless ($MPD->status->state eq 'play' or !$AUTOPLAY);
    }

    my @playlist = $MPD->playlist->as_items;
    if (scalar(@playlist) == 0) {
        print "unable to find any songs to match from\n";
        exit;
    }
    fisher_yates_shuffle(\@playlist);
    my $song_to_match = pop(@playlist);
    $artist = $$song_to_match{artist};
    $title  = $$song_to_match{title};
    $file   = $$song_to_match{file};
}
    
sub get_similar {
    my $artist  = shift;
    my $title   = shift;
    my $file    = shift;

    my @songs   = ();
    @songs = @{$SIMILAR{$file}} if ($file and $SIMILAR{$file});
    if (scalar(@songs) == 0) {
        # if we have an api key and the track name, we can look for
        # similar tracks, and not just similar artists...
        @songs = get_similar_tracks($artist,$title,$T_LIMIT,$KEY)
            if ($KEY and $title);

        # if @songs is still void, we'll search by artist only
        # takes $KEY as a param, but is not required to work
        @songs = get_similar_artists($artist,$A_LIMIT,$KEY)
            if (scalar(@songs) == 0);
    }
    # store our results for this song so we don't have to search
    # in the future, generally a good thing for speeding things up
    @{$SIMILAR{$file}} = @songs if ($file);

    # shuffle the array of found songs like a deck of cards
    fisher_yates_shuffle(\@songs);

    my $found_new_song = 0;
    my $new_song = '';
    if (@songs) {
        while ((scalar(@songs) > 0) and !$found_new_song) {
            $new_song = pop(@songs);
            $found_new_song = 1 unless $PLAYLIST{$new_song};
            $PLAYLIST{$new_song} = 1;
        }
    }
    return $new_song;
}

sub get_similar_tracks {
    my $artist  =   shift;
    my $track   =   shift;
    my $limit   =   shift;
    my $key     =   shift;

    my $sartist = uri_escape($artist);
    my $strack  = uri_escape($track);
    my $params = "&artist=$sartist&track=$strack&limit=$limit&api_key=$key";

    my $content = get("$TRACK_URL$params");
    unless ($content) {
        print "failed to get: $TRACK_URL$params\n";
        return undef;
    }
    my $xml = new XML::Simple;
    my $results = $xml->XMLin($content);

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
    # check to see if this is some unknown-by-scrobbler variant of a 'base'
    # track... i.e. the track title is something like 'Blah (Accoustic)'
    if ((scalar(@similar) == 0) and ($track =~ /\s*\(.*\)$/)) {
        $track =~ s/\s*\(.*\)$//;
        return get_similar_tracks($artist,$track,$limit,$key);
    }

    my @finds = ();
    foreach my $song (@similar) {
        my ($artist,$title) = split(/$DELIMITER/,$song);

        my %songs_by_artist = map { $_->title, $_->file }
            $MPD->collection->songs_by_artist($artist);
        my $safe_title = $title;
        $safe_title =~ s/([\$\@\%\&\(\)\[\]\{\}\\])/\\$1/g;
        foreach my $key (grep { /^$safe_title$/ } keys %songs_by_artist) {
            push(@finds,$songs_by_artist{$key});
        }
    }
    return @finds;
}

sub get_similar_artists {
    my $artist  =   shift;
    my $limit   =   shift;
    my $key     =   shift;

    my $sartist = uri_escape($artist);
    
    my @similar = ( $artist );

    if ($key and $key ne '') {
        my $params = "&artist=$sartist&limit=$limit&api_key=$key";
        my $content = get("$ARTIST_URL$params");
        unless ($content) {
            print "failed to get: $ARTIST_URL$params\n";
            return undef;
        }
        my $xml = new XML::Simple;
        my $results = $xml->XMLin($content);
        if ($$results{status} eq 'ok') {
            foreach my $s_artist (@{$$results{similarartists}{artist}}) {
                push(@similar,$$s_artist{name}) if (ref $s_artist eq 'HASH');
            }
        }
    } else {
        my $url = $ARTIST_ALT;
        $url =~ s/ARTIST/$sartist/;
        my $content = get($url);
        unless ($content) {
            print "failed to get: $url\n";
            return undef;
        }
        # map basically generates an array by applying the 'split' to each
        # line of $content, it's a 'slick' way to do a foreach loop, without
        # the loop. this is mostly a note for myself, because i don't use
        # map too often, and i wanted to be clever...
        @similar = map((split(/,/,$_))[2],split(/\n/,$content));
    }

    my @songs = ();
    foreach my $s_artist (@similar) {
        push(@songs,$MPD->collection->songs_by_artist($s_artist));
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
