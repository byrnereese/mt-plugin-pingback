#
# PingBack Plugin for Movable Type
# Author: Byrne Reese <byrne at majordojo dot com>

# Copyright 2008, Six Apart, Ltd.
#

OVERVIEW

PingBack is a process, similar to TrackBack, that facilitates the
automatic linking between two blogs that link from one to the other.

INSTALLATION

Unzip the contents of the PingBack archive and copy its contents
into your MT_HOME directory.

  > tar zxvf PingBack.tar.gz
  > cp -a PingBack/* /path/to/mt/

When you are finished you have a directory structure like this (with
files in each directory obviously):

  mt.cgi
  plugins/PingBack/
  plugins/PingBack/lib/
  plugins/PingBack/lib/MT/
  

INSTRUCTIONS

Edit your Entry Archive template and add the following code somewhere
in between the <head> and </head> elements.

   <MTIfPingsAccepted>
   <link rel="pingback" href="<$MTPingbackLink$>" />
   </MTIfPingsAccepted>

Then republish your Entry Archives. If your blog has pings and trackbacks
enabled, the necessary HTML will be added to your blog instructing them
on how to ping you.

LICENSE

This plugin is licensed under the same terms as Perl itself
