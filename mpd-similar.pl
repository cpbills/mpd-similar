#!/usr/bin/perl

use strict;
use warnings;

use XML::Simple;
use Audio::MPD;

my $API_KEY     = 'api key goes here';
my $TRACK_URL   = 'http://ws.audioscrobbler.com/2.0/?method=track.getsimilar';
my $ARTIST_URL  = 'http://ws.audioscrobbler.com/2.0/?method=artist.getsimilar';



&artist=cher&track=believe&api_key=b25b959554ed76058ac220b7b2e0a026&limit=100
