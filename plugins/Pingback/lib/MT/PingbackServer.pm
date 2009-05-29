# Movable Type (r) (C) 2001-2008 Six Apart, Ltd. All Rights Reserved.
# This code cannot be redistributed without permission from www.sixapart.com.
# For more information, consult your Movable Type license.
#
# $Id: XMLRPCServer.pm 1174 2008-01-08 21:02:50Z bchoate $

package MT::PingbackServer;
use strict;

use MT;
use MT::Util qw( first_n_words decode_html start_background_task archive_file_for );
use MT::XMLRPCServer;
use MT::I18N qw( encode_text first_n_text const );
use base qw( MT::ErrorHandler );

use constant ERROR => '0';
use constant ERROR_SOURCE_INVALID => '0x0010';
use constant ERROR_NO_LINK_TO_TARGET => '0x0011';
use constant ERROR_TARGET_DOES_NOT_EXIST => '0x0020';
use constant ERROR_TARGET_INVALID => '0x0021';
use constant ERROR_DUPE_PING => '0x0030';
use constant ERROR_NON_COMM => '0x0032';
use constant SUCCESS => 'Ping accepted';

our $MT_DIR;

my($HAVE_XML_PARSER);
BEGIN {
    eval { require XML::Parser };
    $HAVE_XML_PARSER = $@ ? 0 : 1;
}

sub _fault {
    my $mt = MT::XMLRPCServer::Util::mt_new();
    my $enc = $mt->config('PublishCharset');
    SOAP::Fault->faultcode(1)->faultstring(
        SOAP::Data->type(
            string => encode_text($_[0], $enc, 'utf-8')));
}

sub _source_contains_url {
    my ($src_html,$t) = @_;
    return 1 if ($src_html =~ /$t/);
    return 0;
}

sub _target_exists {
    my ($blog_id,$t) = @_;
    require MT::Blog;
    my $blog = MT::Blog->load($blog_id);
    my $blogurl = $blog->site_url;
    $t =~ s/https?:\/\/[^\/]*//;
    _log('looking up ' . "$t");
    require MT::FileInfo;
    my $fi = MT::FileInfo->load({ blog_id => $blog->id,
				  url => "$t", });
    _log("target found") if defined($fi);
    # TODO - check to see if entry is published?
    return $fi->entry_id if $fi;
    _log("target NOT found");
    return 0;
}

sub _is_duplicate {
    my ($blog_id, $source, $target) = @_;
    require MT::Trackback;
    my $pb = MT::Trackback->load({ 
	blog_id => $blog_id,
	url => $source,
    });
    return 1 if $pb;
    return 0;
}

sub _extract_excerpt {
    my ($src,$trg,$html) = @_;

    require HTML::RelExtor;
    my $re = HTML::RelExtor->new();
    $re->parse($html);
    
    my @feeds = map { $_->href } grep { $_->tag eq 'link' && 
	$_->attr->{'type'} =~ /application\/(atom|rss)\+xml/ } $re->links;
    
    require XML::XPath;
    foreach my $feed (@feeds) {
	my $ua = LWP::UserAgent->new;
	$ua->timeout(10);
	my $response = $ua->get($feed);
	my $xml = $response->content;
	my $x = XML::XPath->new( xml => $xml );
	my $nodeset;
	# Check for RSS
	$nodeset = $x->find('/rss/channel/item');
	foreach my $node ($nodeset->get_nodelist) {
	    my $link  = $x->find('./link', $node)->string_value;
	    if ($link eq $src) {
		return (
			$x->find('/rss/channel/title')->string_value,
			$x->find('./title', $node)->string_value,
			$x->find('./description', $node)->string_value,
			);
	    }
	}
#	# Check for Atom
#	$nodeset = $x->find('/feed/entry/link[@rel=\'alternate\']/href');
#	foreach my $node ($nodeset->get_nodelist) {
#	}
    }
    return undef;
}

sub _publish {
    my $class = shift;
    my($mt, $entry, $blog, $no_ping) = @_;
    $mt->rebuild_entry( Entry => $entry, Blog => $blog,
                        BuildDependencies => 1 )
        or return $class->error("Publish error: " . $mt->errstr);
    unless ($no_ping) {
        $mt->ping_and_save(Blog => $blog, Entry => $entry)
            or return $class->error("Ping error: " . $mt->errstr);
    }
    1;
}

sub ping {
    my $class = shift;
    my($sourceURI, $targetURI) = @_;

    my $mt = MT::XMLRPCServer::Util::mt_new();
    my $ip = $ENV{'REMOTE_ADDR'};

    my ( $tb_id ) = ($ENV{'PATH_INFO'} =~ /^\/(.*)$/);
    return ERROR unless $tb_id; # No TrackBack ID provided

    require MT::Trackback;
    my $tb = MT::Trackback->load($tb_id) 
	or return ERROR_TARGET_DOES_NOT_EXIST; # Invalid TrackBack ID

    # TODO - check against throttle
    # TODO - add and invoke callbacks

    ## Check if this user has been banned from sending TrackBack pings.
    require MT::IPBanList;
    my $iter = MT::IPBanList->load_iter( { blog_id => $tb->blog_id } );
    while ( my $ban = $iter->() ) {
        my $banned_ip = $ban->ip;
        if ( $ip =~ /$banned_ip/ ) {
            return SUCCESS;
        }
    }

    my $entry_id;
    return ERROR_TARGET_DOES_NOT_EXIST unless ($entry_id = $tb->entry_id);
    return ERROR_TARGET_INVALID unless ($entry_id == $tb->entry_id);

    require MT::Entry;
    my $entry = MT::Entry->load({ id => $tb->entry_id, 
				  status => MT::Entry::RELEASE() } );

    my $passed_filter = MT->run_callbacks( 'TBPingThrottleFilter', $mt, $tb );
    return ERROR if ( !$passed_filter );

    require LWP::UserAgent;
    my $ua = LWP::UserAgent->new;
    $ua->timeout(10);
  
    my $response = $ua->get($sourceURI);
    return ERROR_SOURCE_INVALID if (!$response->header('Content-Type') =~ /^text\//);
    return ERROR_SOURCE_INVALID if (!$response->is_success);

    my $source_html = $response->content;
    return ERROR_NO_LINK_TO_TARGET if (!_source_contains_url($source_html, $targetURI));
    return ERROR_DUPE_PING if (_is_duplicate($entry->blog_id, $sourceURI, $targetURI));

    # TODO: send ping email notification

    require MT::TBPing;
    require MT::Blog;
    my $blog = MT::Blog->load( $tb->blog_id );
    my $cfg  = $mt->config;

    return ERROR_TARGET_INVALID	if ($tb->is_disabled);
    return ERROR_NON_COMM if (!$cfg->AllowPings || !$blog->allow_pings);

    # Check for duplicates...
    my $ping;
    my @pings = MT::TBPing->load( { tb_id => $tb->id } );
    foreach (@pings) {
        if ( $_->source_url eq $sourceURI ) {
            return SUCCESS if $_->is_junk;
            if ( $ip eq $_->ip ) {
                $ping = $_;
                last;
            } else {
                # return success to quiet this pinger
                return SUCCESS;
            }
        }
    }

    if ( !$ping ) {
        $ping ||= MT::TBPing->new;
        $ping->blog_id( $tb->blog_id );
        $ping->tb_id($tb_id);
        $ping->source_url($sourceURI);
        $ping->ip( $ip || '' );
        $ping->junk_status(0);
        $ping->visible(1);
    }
    $ping->junk_status(-1); # TODO - why is this here?
    my ($blog_name, $entry_title, $excerpt) = _extract_excerpt($sourceURI,$targetURI,$source_html);
    $ping->title($entry_title);
    $ping->blog_name($blog_name);
    $ping->excerpt($excerpt);

    # strip of any null characters (done after junk checks so they can
    # monitor for that kind of activity)
    for my $field (qw(title excerpt source_url blog_name)) {
        my $val = $ping->column($field);
        if ( $val =~ m/\x00/ ) {
            $val =~ tr/\x00//d;
            $ping->column( $field, $val );
        }
    }

 #   if ( !MT->run_callbacks( 'TBPingFilter', $app, $ping ) ) {
 #       return $app->_response( Error => "", Code => 403 );
 #   }

    if ( !$ping->is_junk ) {
	require MT::JunkFilter;
        MT::JunkFilter->filter($ping);
    }

    if ( !$ping->is_junk && $ping->visible && $blog->moderate_pings ) {
        $ping->visible(0);
    }

    $ping->save	or _log("  ERROR: " . $ping->errstr);

#    _publish($mt, $entry, $blog) or return ERROR;

    return SUCCESS;
}

## The above methods will be called as blogger.newPost, blogger.editPost,
## etc., because we are implementing Blogger's API. Thus, the empty
## subclass.
package pingback;
BEGIN { @pingback::ISA = qw( MT::PingbackServer ); }

1;
__END__

=head1 NAME

MT::PingbackServer

=head1 SYNOPSIS

An XMLRPC API interface for communicating with Pingback clients.

=cut


sub ping {
    my $app = shift;
    my $q   = $app->param;

    return $app->_response(
        Error => $app->translate("Trackback pings must use HTTP POST") )
      if $app->request_method() ne 'POST';

    my ( $tb_id, $pass ) = $app->_get_params;
    return $app->_response(
        Error => $app->translate("Need a TrackBack ID (tb_id).") )
      unless $tb_id;

    require MT::Trackback;
    my $tb = MT::Trackback->load($tb_id)
      or return $app->_response(
        Error => $app->translate( "Invalid TrackBack ID '[_1]'", $tb_id ) );

    my $user_ip = $app->remote_ip;

    ## Check if this user has been banned from sending TrackBack pings.
    require MT::IPBanList;
    my $iter = MT::IPBanList->load_iter( { blog_id => $tb->blog_id } );
    while ( my $ban = $iter->() ) {
        my $banned_ip = $ban->ip;
        if ( $user_ip =~ /$banned_ip/ ) {
            return $app->_response(
                Error => $app->translate(
                    "You are not allowed to send TrackBack pings.")
            );
        }
    }

    my ( $blog_id, $entry, $cat );
    if ( $tb->entry_id ) {
        require MT::Entry;
        $entry = MT::Entry->load(
            { id => $tb->entry_id, status => MT::Entry::RELEASE() } );
        if ( !$entry ) {
            return $app->_response( Error =>
                  $app->translate( "Invalid TrackBack ID '[_1]'", $tb_id ) );
        }
    }
    elsif ( $tb->category_id ) {
        require MT::Category;
        $cat = MT::Category->load( $tb->category_id );
    }
    $blog_id = $tb->blog_id;

    MT->add_callback( 'TBPingThrottleFilter', 1, undef,
        \&MT::App::Trackback::_builtin_throttle );

    my $passed_filter = MT->run_callbacks( 'TBPingThrottleFilter', $app, $tb );
    if ( !$passed_filter ) {
        return $app->_response(
            Error => $app->translate(
"You are pinging trackbacks too quickly. Please try again later."
            ),
            Code => "403 Throttled"
        );
    }

    my ( $title, $excerpt, $url, $blog_name, $enc ) = map scalar $q->param($_),
      qw( title excerpt url blog_name charset);

    unless ($enc) {
        my $content_type = $q->content_type();
        if ( $content_type =~ m/;[ ]+charset=(.+)/i ) {
            $enc = lc $1;
            $enc =~ s/^\s+|\s+$//gs;
        }
    }

    no_utf8( $tb_id, $title, $excerpt, $url, $blog_name );

    # guess encoding as possible
    $enc = MT::I18N::guess_encoding( $excerpt . $title . $blog_name )
      unless $enc;
    ( $title, $excerpt, $blog_name ) =
      map { encode_text( $_, $enc ) } ( $title, $excerpt, $blog_name );

    return $app->_response(
        Error => $app->translate("Need a Source URL (url).") )
      unless $url;

    if ( my $fixed = MT::Util::is_valid_url( $url || "" ) ) {
        $url = $fixed;
    }
    else {
        return $app->_response(
            Error => $app->translate( "Invalid URL '[_1]'", $url ) );
    }

    require MT::TBPing;
    require MT::Blog;
    my $blog = MT::Blog->load( $tb->blog_id );
    my $cfg  = $app->config;

    return $app->_response(
        Error => $app->translate("This TrackBack item is disabled.") )
      if $tb->is_disabled || !$cfg->AllowPings || !$blog->allow_pings;

    if ( $tb->passphrase && ( !$pass || $pass ne $tb->passphrase ) ) {
        return $app->_response(
            Error => $app->translate(
                "This TrackBack item is protected by a passphrase.")
        );
    }

    my $ping;

    # Check for duplicates...
    my @pings = MT::TBPing->load( { tb_id => $tb->id } );
    foreach (@pings) {
        if ( $_->source_url eq $url ) {
            return $app->_response() if $_->is_junk;
            if ( $app->remote_ip eq $_->ip ) {
                $ping = $_;
                last;
            }
            else {

                # return success to quiet this pinger
                return $app->_response();
            }
        }
    }

    if ( !$ping ) {
        $ping ||= MT::TBPing->new;
        $ping->blog_id( $tb->blog_id );
        $ping->tb_id($tb_id);
        $ping->source_url($url);
        $ping->ip( $app->remote_ip || '' );
        $ping->junk_status(0);
        $ping->visible(1);
    }
    my $excerpt_max_len = const('LENGTH_ENTRY_PING_EXCERPT');
    if ($excerpt) {
        if ( length_text($excerpt) > $excerpt_max_len ) {
            $excerpt = substr_text( $excerpt, 0, $excerpt_max_len - 3 ) . '...';
        }
        $title =
          first_n_text( $excerpt, const('LENGTH_ENTRY_PING_TITLE_FROM_TEXT') )
          unless defined $title;
        $ping->excerpt($excerpt);
    }
    $ping->title( defined $title && $title ne '' ? $title : $url );
    $ping->blog_name($blog_name);

    # strip of any null characters (done after junk checks so they can
    # monitor for that kind of activity)
    for my $field (qw(title excerpt source_url blog_name)) {
        my $val = $ping->column($field);
        if ( $val =~ m/\x00/ ) {
            $val =~ tr/\x00//d;
            $ping->column( $field, $val );
        }
    }

    if ( !MT->run_callbacks( 'TBPingFilter', $app, $ping ) ) {
        return $app->_response( Error => "", Code => 403 );
    }

    if ( !$ping->is_junk ) {
        MT::JunkFilter->filter($ping);
    }

    if ( !$ping->is_junk && $ping->visible && $blog->moderate_pings ) {
        $ping->visible(0);
    }

    $ping->save
      or return $app->_response( Error => "An internal error occured" );
    if ( $ping->id && !$ping->is_junk ) {
        my $msg = 'New TrackBack received.';
        if ($entry) {
            $msg = $app->translate( 'TrackBack on "[_1]" from "[_2]".',
                $entry->title, $ping->blog_name );
        }
        elsif ($cat) {
            $msg = $app->translate( "TrackBack on category '[_1]' (ID:[_2]).",
                $cat->label, $cat->id );
        }
        require MT::Log;
        $app->log(
            {
                message  => $msg,
                class    => 'ping',
                category => 'new',
                blog_id  => $blog_id,
                metadata => $ping->id,
            }
        );
    }

    if ( !$ping->is_junk ) {
        $blog->touch;
        $blog->save;

        if ( !$ping->visible ) {
            $app->_send_ping_notification( $blog, $entry, $cat, $ping );
        }
        else {
            start_background_task(
                sub {
                    ## If this is a trackback item for a particular entry, we need to
                    ## rebuild the indexes in case the <$MTEntryTrackbackCount$> tag
                    ## is being used. We also want to place the RSS files inside of the
                    ## Local Site Path.
                    $app->rebuild_indexes( Blog => $blog )
                      or return $app->_response(
                        Error => $app->translate(
                            "Publish failed: [_1]",
                            $app->errstr
                        )
                      );

                    if ( $tb->entry_id ) {
                        $app->rebuild_entry(
                            Entry             => $entry->id,
                            Blog              => $blog,
                            BuildDependencies => 1
                        );
                    }
                    if ( $tb->category_id ) {
                        $app->publisher->_rebuild_entry_archive_type(
                            Entry       => undef,
                            Blog        => $blog,
                            Category    => $cat,
                            ArchiveType => 'Category'
                        );
                    }

                    if ( $app->config('GenerateTrackBackRSS') ) {
                        ## Now generate RSS feed for this trackback item.
                        my $rss  = _generate_rss( $tb, 10 );
                        my $base = $blog->archive_path;
                        my $feed = File::Spec->catfile( $base,
                            $tb->rss_file || $tb->id . '.xml' );
                        my $fmgr = $blog->file_mgr;
                        $fmgr->put_data( $rss, $feed )
                          or return $app->_response(
                            Error => $app->translate(
                                "Can't create RSS feed '[_1]': ", $feed,
                                $fmgr->errstr
                            )
                          );
                    }
                    $app->_send_ping_notification( $blog, $entry, $cat, $ping );
                }
            );
        }
    }
    else {
        $app->run_tasks('JunkExpiration');
    }

    return $app->_response;
}
