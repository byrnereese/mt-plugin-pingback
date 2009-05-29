package MT::Plugin::Pingback;

use MT;
use strict;
use base qw( MT::Plugin );
our $VERSION = '1.01';

my $plugin = MT::Plugin::Pingback->new({
	key 	    => 'Pingback',
	id  	    => 'Pingback',
	name	    => 'Pingback',
	description => "Implements the Pingback notification protocol for Movable Type.",
	version     => $VERSION,
	author_name => "Byrne Reese",
	author_link => "http://www.majordojo.com/",
});

sub instance { $plugin; }

MT->add_plugin($plugin);

sub init_registry {
    my $plugin = shift;
    $plugin->registry({
        object_types => {
#            'trackback' => {
#                is_pingback => 'integer',
#		source_uri => 'string(255)',
#		target_uri => 'string(255)',
#            },
        },
        config_settings => {
            'PingbackScript' => { default => 'plugins/PingBack/mt-pingback.cgi', },
        },
	tags => {
	    function => {
		'PingbackScript' => \&_hdlr_pingback_script,
		'PingbackLink' => \&_hdlr_pingback_link,
	    },
	},
    });
}

sub _hdlr_pingback_script {
    my ($ctx) = @_;
    return $ctx->{config}->PingbackScript;
}

sub _hdlr_pingback_link {
    my ($ctx, $args, $cond) = @_;
    my $e = $ctx->stash('entry')
        or return $ctx->_no_entry_error($ctx->stash('tag'));
    my $tb = $e->trackback
        or return '';
    my $cfg = $ctx->{config};
    require MT::Template::ContextHandlers;
    my $path = &MT::Template::Context::_hdlr_cgi_path($ctx);
    return $path . $cfg->PingbackScript . '/' . $tb->id;
    
}
