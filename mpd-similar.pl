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
if ($current) {
    $artist     = $$current{artist};
    $title      = $$current{title};
}

# we don't NEED a title to go with the artist, but we /do/ need $artist
unless ($artist) {
    print "no artist information provided or available from mpd playlist";
    exit 1;
}

# playlist hash holds the playlist, we can easily check for collisions when
# adding new tracks. the similar hash will hold the results found from looking
# for similar tracks to reduce the lookup time while building the playlist.
my %PLAYLIST    = ();
my %SIMILAR     = ();

unless ($CLEAR or $CROP) {
    my @old_songs = $MPD->playlist->as_items;
    $SIZE+=scalar(@old_songs);
    foreach my $song (@old_songs) {
        $PLAYLIST{$$song{file}} = 1;
    }
}

$PLAYLIST{$$current{file}} = 1;
while (scalar(keys %PLAYLIST) < $SIZE) {
    my @playlist = keys %PLAYLIST;
    fisher_yates_shuffle(\@playlist);
    my $file = pop(@playlist);
    
    my $song = $MPD->collection->song($file);
    my $artist  = $$song{artist};
    my $track   = $$song{title};

    print "similar to $artist - $track...\n";

    my @songs = ();
    @songs = @{$SIMILAR{$file}} if ($SIMILAR{$file});
    if (@songs == 0) {
        # we have an API key, we can find similar tracks, not just artists!
        @songs = get_sim_tracks($artist,$track,$T_LIMIT,$KEY) if ($KEY);

        # find songs using only similar artist if the search for
        # similar tracks yeilded no results.
        @songs = get_sim_artists($artist,$A_LIMIT,$KEY) if (@songs == 0);
    }
    @{$SIMILAR{$file}} = @songs;

    fisher_yates_shuffle(\@songs);
    
    my $new_one = 0;
    if (@songs) {
        while (@songs and $new_one == 0) {
            my $new_song = pop(@songs);
            $new_one = 1 unless $PLAYLIST{$new_song};
            $PLAYLIST{$new_song} = 1;

            my $info = $MPD->collection->song($new_song);
            my $new_artist = $$info{artist};
            my $new_title  = $$info{title};
        }
    }
}

delete $PLAYLIST{$$current{file}} unless ($CLEAR);

if ($CROP) {
    $MPD->playlist->crop;
} elsif ($CLEAR) {
    $MPD->playlist->clear;
} else {
    my @old_songs = $MPD->playlist->as_items;
    foreach my $song (@old_songs) {
        delete $PLAYLIST{$$song{file}};
    }
}

print "playlist:\n";
my @files = keys %PLAYLIST;
fisher_yates_shuffle(\@files);
foreach my $file (@files) {
    my $info = $MPD->collection->song($file);
    $MPD->playlist->add($file);
    my $artist = $$info{artist};
    my $title  = $$info{title};
    print "\t$artist - $title\n";
}

$MPD->play if ($CLEAR);

sub get_sim_tracks {
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
        return get_sim_tracks($artist,$track,$limit,$key);
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

sub get_sim_artists {
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
