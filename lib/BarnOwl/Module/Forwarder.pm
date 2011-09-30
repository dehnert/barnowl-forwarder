use warnings;
use strict;

package BarnOwl::Module::Forwarder;
our $VERSION = 0.1;

use BarnOwl;
use BarnOwl::Hooks;

use JSON;

our $conffile = BarnOwl::get_config_dir() . "/forwarder.json";

our @classes;

sub fail {
    my $msg = shift;
    BarnOwl::admin_message('Forwarder Error', $msg);
    die("Forwarder Error: $msg\n");
}

sub read_config {
    my $conffile = shift;
    my $cfg = {};
    if (open(my $fh, "<", "$conffile")) {
        my $raw_cfg = do {local $/; <$fh>};
        close($fh);

        eval { $cfg = from_json($raw_cfg); };
        if ($@) { BarnOwl::admin_message('ReadConfig', "Unable to parse $conffile: $@"); }
    } else {
        BarnOwl::message("Config file $conffile could not be opened.");
    }
    return $cfg;
}

sub load_config {
    my $prefix = shift;
    my $cfg = read_config($conffile);
    my $appconf = $cfg->{$prefix};
    my $elem;
    @classes = ();
    foreach $elem (@$appconf)
    {
        push (@classes, BarnOwl::Module::Forwarder::ClassPair->new(%$elem));
    }
}

sub initialize {
    BarnOwl::new_variable_bool("forwarder:enable", {
        default => 1,
        summary => "turn forwarding on or off",
        description => "If this is set, forwarding will occur. If unset, " .
            "forwarding will be disabled."
    });

    load_config("forwarder");
    BarnOwl::admin_message('Forwarder', "Initialized Forwarder.");
}

sub handle_message {
    my $m = shift;
    my $classpair;
    foreach $classpair (@classes)
    {
        $classpair->handle_message($m);
    }
}

initialize;

eval {
    $BarnOwl::Hooks::receiveMessage->add('BarnOwl::Module::Forwarder::handle_message');
};
if ($@) {
    $BarnOwl::Hooks::receiveMessage->add(\&handle_message);
}

1;

package BarnOwl::Module::Forwarder::ClassPair;

sub new {
    my $class = shift;
    my %args = (@_);
    return bless {%args}, $class;
}

sub handle_message {
    my $this = shift;
    my $m = shift;
    my $recipient;

    if($m->{type} eq "zephyr") {
        if($m->{class} eq $this->{class} and not $m->opcode eq "forwarded" ) {
            foreach $recipient (@{$this->{recipients}})
            {
                BarnOwl::command("jwrite", "-m", $m->body, $recipient);
            }
        }
    } elsif($m->{type} eq "jabber") {
        if($m->{recipient} eq $this->{jabber}) {
            BarnOwl::zephyr_zwrite('-c '.$this->{class}.' -O forwarded'.' -s '.$m->sender, $m->body);
        }
    }
}

1;
