#!/usr/bin/perl
# mpd-similar.pl - creates intelligent playlists for mpd / music player daemon
# Copyright (C) 2008 Christopher P. Bills (cpbills@fauxtographer.net)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# script to generate a playlist from a given track using audioscrobber to find
# similar tracks and in the event that doesn't work, similar artists...
# in theory it will find a few tracks for the given track, and then find tracks
# for the tracks found, somewhat recursively.

# track.getsimilar&artist=artist&track=track&api_key=key
# artist.getsimilar&artist=artist&api_key=key

use strict;
no strict "refs";
use warnings;

use XML::Simple;
use LWP::Simple;
use Audio::MPD;
use URI::Escape;
use DBI;

my $SIZE        = 10;   # number of tracks to try to add, by default
   $SIZE        = $ARGV[0] if ($ARGV[0] && $ARGV[0] =~ /[0-9]+/);
my $CROP        = 0;    # leave the current song and remove everything else
my $VERBOSE     = 0;
my $CLEAR       = 0;    # completely clear the playlist
my $AUTOPLAY    = 1;    # attempt to resume / start play after adding a song
my $SHUFFLE     = 0;    # shuffle playlist after each song is added.
my $SEED        = 5;    # number of songs to add based on the initial song
my $PERSONG     = 3;    # number of songs to add based on seeded songs.
my $M_MID       = 40;   # middle threshold for matching songs (percent)
my $M_LOW       = 20;   # low threshold for matching songs (percent)

my $KEY         = 'api key goes here';
my $TRACK_URL   = 'http://ws.audioscrobbler.com/2.0/?method=track.getsimilar';
my $ARTIST_URL  = 'http://ws.audioscrobbler.com/2.0/?method=artist.getsimilar';
my $ARTIST_ALT  = 'http://ws.audioscrobbler.com/2.0/artist/ARTIST/similar.txt';
my $DELIMITER   = ''; # ctrl-_ is a useful delimiter
my $MAX_AGE     = 4*24*60*60; # 4 days should be a good start to check this out

my $MPD_HOST    = 'localhost';
my $MPD_PORT    = '6600';
my $MPD_PASS    = '';

my $SQL_HOST    = 'localhost';
my $SQL_PORT    = '3306';
my $SQL_DB      = 'similarity';
my $SQL_USER    = 'similarity';
my $SQL_PASS    = 'similarity';

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

# call a function that will check that all files referenced
# in the database exist on disk and are up to day. TODO
#purge_db() if $PURGE;




# SEEDING -
# either seed based off the track provided, give title, artist and file
# or; given a title and artist;
#   if that track is available, add it
#   else use it's info only to seed.
# or; given only an artist, use a random song by that artist to seed

# TODO:
# new algorithm;
# first song; find similar tracks, build database entries for that song
# pick song from similar tracks, build database entries for that song
# - pick based on match percent and age (last_played / last_added)
# to make playlists smarter, build base from origin song, 5 tracks, if possible
# then from that pool, pick a song, and pick the best match/oldest 2-3 times
# then from the first pool, move on to song 2 of 5 or whatever... sort of
# using a tier... which will hopefully reduce branching out so much
# error handling for not having enough base songs, and keeping the base fresh
# but similar will be a big part of the algorithm... also handling similar
# artists instead of tracks will be a chore... since the similarity per-track
# drops drastically based only on artist similarity.
# table structure;
# songs: song_id, file, last_add, last_update
# matches: match_id, song_id, file, match (percent)
# select file,match from matches where song_id = $id;
# select last_add,last_update from songs where file = $file;

print "Building playlist for $artist - $title\n";

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
        $song = $MPD->collection->song($song);
        print "$artist - $title -> $$song{artist} - $$song{title}\n"
            if ($VERBOSE);
        #print "Added " . $$song{artist} . ' - ' . $$song{title} . "\n";
        $MPD->playlist->shuffle if ($SHUFFLE);
        $MPD->play unless ($MPD->status->state eq 'play' or !$AUTOPLAY);
    }

    my @playlist = $MPD->playlist->as_items;
    if (scalar(@playlist) == 0) {
        print "playlist empty; nothing was found with provided information\n";
        exit;
    }
    fisher_yates_shuffle(\@playlist) if (scalar(@playlist) > 0);
    my $song_to_match = pop(@playlist);
    $artist = $$song_to_match{artist};
    $title  = $$song_to_match{title};
    $file   = $$song_to_match{file};
}

sub check_db {
    my $file    = shift;

    my %matches = ();
    my %used    = ();
    my $dbh = db_connect();
    my $now = time;
    $file = $dbh->quote($file);

    my $select = qq{ select song_id,last_update from songs where file=$file };
    my ($song_id,$last) = $dbh->selectrow_array($select);

    # return our empty hash if the query was unsuccessful
    return %matches unless ($song_id);
    # return our empty hash if the entry needs to be refreshed
    return %matches if ($last and $last > $MAX_AGE);

    $select = qq{ select file,percent from matches where song_id=$song_id };
    my $results = $dbh->selectall_hashref($select,'file');
    
    my $sql = qq{ select last_used from songs where file = ? };
    my $sth = $dbh->prepare($select);
    foreach my $file (keys %$results) {
        $used{$file} = 0;
        $sth->execute($file);
        my ($last) = $sth->fetchrow_array;
        $used{$file} = $last if ($last);
    }
}

sub get_similar {
    my $artist  = shift;
    my $title   = shift;
    my $file    = shift;

    my @songs   = ();
    my $updated = 0;

    #my %songs2 = check_db($file) if ($file);

    if ($file) {
        # we're trying to do this the 'right' way, which is a
        # pain in the ass, and a lot of extra code.
        my $dbh = db_connect();
        my $now = time;
        my $fileq = $dbh->quote($file);
        my $select = qq{ select last_update,similar from song_info
                            where file = $fileq };
        my ($last,$similar) = $dbh->selectrow_array($select);
        # use the results if they aren't expired
        push(@songs,split(/$DELIMITER/,$similar))
            if ($last and $similar and (($now - $last) < $MAX_AGE));
        $dbh->disconnect;
    }

    #@songs = @{$SIMILAR{$file}} if ($file and $SIMILAR{$file});
    unless (@songs and scalar(@songs) > 0) {
        # if we have an api key and the track name, we can look for
        # similar tracks, and not just similar artists...
        @songs = get_similar_tracks($artist,$title,$KEY)
            if ($KEY and $title);

        # we only want to store the results to our database if we got
        # a song / artist hit... otherwise it could dillute the pool
        $updated = 1 if (scalar(@songs) > 0);

        if (scalar(@songs) == 0) {
            print "no similar tracks found for $artist - $title\n";
        } 

        # if @songs is still void, we'll search by artist only
        # takes $KEY as a param, but is not required to work
        #@songs = get_similar_artists($artist,$KEY)
        #    unless (@songs and scalar(@songs) > 0);
    }

    # store our results for this song so we don't have to search
    # in the future, generally a good thing for speeding things up
    if ($file and $updated) {
        my $dbh = db_connect();
        my $now = time;
        my $fileq = $dbh->quote($file);
        my $similarq = $dbh->quote(join $DELIMITER, @songs);
        my $select = qq{ select song_id from song_info where file = $fileq };
        my ($song_id) = $dbh->selectrow_array($select);
        if ($song_id) {
            my $update = qq{ update song_info set last_update = $now,
                             similar = $similarq where song_id = $song_id };
            $dbh->do($update);
        } else {
            my $insert = qq{ insert into song_info (file,similar,last_update)
                            values ($fileq, $similarq, $now) };
            $dbh->do($insert);
        }
        $dbh->disconnect;
    }

    #@{$SIMILAR{$file}} = @songs if ($file);

    fisher_yates_shuffle(\@songs) if (scalar(@songs) > 0);

    while (scalar(@songs) > 0) {
        my $new_song = pop(@songs);
        if ($new_song and !$PLAYLIST{$new_song}) {
            $PLAYLIST{$new_song} = 1;
            return $new_song;
        }
    }
    return 0;
}

sub get_similar_tracks {
    my $artist  =   shift;
    my $track   =   shift;
    my $key     =   shift;

    my @similar = ();
    my $sartist = uri_escape($artist);
    my $strack  = uri_escape($track);
    my $params  = "&artist=$sartist&track=$strack&api_key=$key";
    my $content = get("$TRACK_URL$params");

    unless ($content) {
        # return an empty array when the web breaks, and we're unable
        # to look up the artist/track. we could potentially put in a 
        # retry limit... so TODO retry limit ?
        print STDERR "failed to get: $TRACK_URL$params\n";
        return @similar;
    }
    my $xml = new XML::Simple;
    my $results = $xml->XMLin($content);

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
        return get_similar_tracks($artist,$track,$key);
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
    my $key     =   shift;
    my $sartist = uri_escape($artist);

    my @similar = ( $artist );

    if ($key and $key ne '') {
        my $params = "&artist=$sartist&api_key=$key";
        my $content = get("$ARTIST_URL$params");
        if ($content) {
            my $xml = new XML::Simple;
            my $results = $xml->XMLin($content);
            if ($$results{status} eq 'ok') {
                my $s_artists = $$results{similarartists}{artist};
                foreach my $s_artist (@$s_artists) {
                  push(@similar,$$s_artist{name}) if (ref $s_artist eq 'HASH');
                }
            }
        } else {
            print STDERR "failed to get: $ARTIST_URL$params\n";
        }
    } else {
        my $url = $ARTIST_ALT;
        $url =~ s/ARTIST/$sartist/;
        my $content = get($url);
        if ($content) {
            # map basically generates an array by applying the 'split' to each
            # line of $content, it's a 'slick' way to do a foreach loop, without
            # the loop. this is mostly a note for myself, because i don't use
            # map too often, and i wanted to be clever...
            @similar = map((split(/,/,$_))[2],split(/\n/,$content));
        } else {
            print STDERR "failed to get: $url\n";
        }
    }
    my @songs = ();
    foreach my $s_artist (@similar) {
        push(@songs,$MPD->collection->songs_by_artist($s_artist));
    }
    return map($_->file,@songs);
}

sub db_connect {
    my $dsn = "dbi:mysql:$SQL_DB:$SQL_HOST:$SQL_PORT";
    my $dbh = DBI->connect($dsn,$SQL_USER,$SQL_PASS,{ RaiseError => 1});
    return $dbh;
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
