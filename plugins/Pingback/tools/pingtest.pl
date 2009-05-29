#!/usr/bin/perl -w

use strict;
use XMLRPC::Lite;
use Data::Dumper;

my $jira = XMLRPC::Lite->proxy('http://www.majordojo.com/cgi-bin/mt/mt-pingback.cgi?blog_id=60');
my $call = $jira->call("pingback.ping", 
		       'http://byrnereese.wordpress.com/2008/01/31/pingback-test/', 
		       'http://www.majordojo.com/pingback_test_blog/2008/01/test-entry.html');
my $fault = $call->fault();
if (defined $fault) {
    die $call->faultstring();
} else {
    print "issue created:\n";
    print Dumper($call->result());
}
