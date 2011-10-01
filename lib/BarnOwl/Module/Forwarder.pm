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
    my $appconf = read_config($conffile);
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
    if (BarnOwl::getvar("forwarder:enable") eq "off") {
        return;
    }
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
    my $msgprefix;
    my $resend = 0;

    # Receive messages and configure
    if($m->{type} eq "zephyr" and $this->{zephyr}) {
        if($m->{class} eq $this->{zephyr}->{class} and
            not $m->opcode eq "forwarded" and
            not $m->sender =~ m/\/BRIDGE$/
        ) {
            $msgprefix = "(From " . $m->sender . " -i " . $m->subcontext . ")\n";
            $resend = 1;
        }
    }
    if($m->{type} eq "jabber" and $this->{jabber}) {
        if($this->{jabber}->{account} eq $m->{recipient}) {
            $msgprefix = "(From " . $m->sender . ")\n";
            $resend = 1;
        }
    }

    return if not $resend;

    # Resend the messages
    if($this->{zephyr} and $m->{type} ne "zephyr") {
        BarnOwl::command('set', 'zsender', $m->sender."/BRIDGE");
        my @args = ('-c', $this->{zephyr}->{class}, '-O', 'forwarded', '-m', $m->body);
        if($this->{zephyr}->{zcrypt}) {
            BarnOwl::zcrypt(@args);
        } else {
            BarnOwl::zwrite(@args);
        }
        BarnOwl::command('set', 'zsender', 'zephyr/Jabber bridge');
    }
    if($this->{jabber}) {
        BarnOwl::message("resend to jabber path; resend=$resend");
        foreach $recipient (@{$this->{jabber}->{subscribers}})
        {
            if($m->{type} eq "jabber" and $m->sender eq $recipient) {
                # We got this message from $recipient
            } else {
                BarnOwl::command("jwrite", "-m", $msgprefix.$m->body, $recipient);
            }
        }
    }
}

1;
