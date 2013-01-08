use warnings;
use strict;

package BarnOwl::Module::Forwarder;
our $VERSION = 0.1;

use BarnOwl;
use BarnOwl::Hooks;
use BarnOwl::Module::Jabber;
use BarnOwl::Zephyr;

use JSON;

our $conffile = BarnOwl::get_config_dir() . "/forwarder.json";

our @classes;

sub fail {
    my $msg = shift;
    BarnOwl::admin_message('Forwarder Error', $msg);
    die("Forwarder Error: $msg\n");
}

sub warn {
    my $msg = shift;
    BarnOwl::admin_message('Forwarder Warning', $msg);
}

sub debug {
    my $msg = shift;
    BarnOwl::admin_message('Forwarder Debug', $msg);
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
    BarnOwl::new_command(
        "forwarder:load_config" => \&load_config,
        {
            "summary" => "reload the Forwarder configuration",
            "usage" => "forwarder:load_config"
        }
    );
    BarnOwl::new_command(
        "forwarder:load_zephyr_subs" => \&load_zephyr_subs,
        {
            "summary" => "subscribe to classes the forwarder listens on",
            "usage" => "forwarder:load_zephyr_subs"
        }
    );

    load_config("forwarder");
    BarnOwl::admin_message('Forwarder', "Initialized Forwarder.");
}

sub load_zephyr_subs {
    my $classpair;
    foreach $classpair (@classes)
    {
        $classpair->load_zephyr_subs();
    }
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

$BarnOwl::Hooks::startup->add("BarnOwl::Module::Forwarder::initialize");
$BarnOwl::Zephyr::zephyrStartup->add('BarnOwl::Module::Forwarder::load_zephyr_subs');

eval {
    $BarnOwl::Hooks::receiveMessage->add('BarnOwl::Module::Forwarder::handle_message');
};
if ($@) {
    BarnOwl::admin_message('Forwarder', "Adding coderef handler.");
    $BarnOwl::Hooks::receiveMessage->add(\&handle_message);
}

1;

package BarnOwl::Module::Forwarder::ClassPair;

sub new {
    my $class = shift;
    my %args = (@_);
    my $this = bless {%args}, $class;
    $this->connect();
    return $this;
}

sub connect {
    my $this = shift;
    if($this->{'jabber'} and $this->{'jabber'}{'autoconnect'}) {
        my $username = $this->{'jabber'}->{'account'};
        my $password = $this->{'jabber'}->{'password'};
        eval {
            my $resolved = BarnOwl::Module::Jabber::resolveConnectedJID($username);
            BarnOwl::Module::Forwarder::debug("Already connected to $username: $resolved");
        };
        if ($@ =~ /Invalid account: /) {
            eval {
                BarnOwl::jabberlogin($username, $password);
                # Jabber will output a message for us
                #BarnOwl::Module::Forwarder::debug("Connected(?) to $username");
            };
            if ($@) {
                BarnOwl::Module::Forwarder::warn("Failed connecting to $username:\n$@");
            }
        } elsif ($@) {
            BarnOwl::Module::Forwarder::warn("Unexpected error while connecting to $username:\n$@");
        }
        my @subscribers = @{$this->{'jabber'}->{'subscribers'}};
        foreach my $subscriber (@subscribers) {
            BarnOwl::jroster('sub', $subscriber, '-a', $username);
        }
    }
}

sub load_zephyr_subs {
    my $this = shift;
    if($this->{zephyr} and $this->{'zephyr'}->{'class'}) {
        BarnOwl::subscribe($this->{'zephyr'}->{'class'});
    }
    if($this->{private_recv_zephyr} and $this->{'private_recv_zephyr'}->{'class'}) {
        BarnOwl::subscribe($this->{'private_recv_zephyr'}->{'class'}, '*', '%me%');
    }
}

sub handle_message {
    my $this = shift;
    my $m = shift;
    my $recipient;
    my $msgprefix;
    my $resend = 0;

    # Receive messages and configure
    my $type = $m->{type};
    my $zsig = "";
    if($m->{type} eq "zephyr" and $this->{private_recv_zephyr}) {
        if($m->{class} eq $this->{private_recv_zephyr}->{class} and
           $m->is_private
        ) {
            $msgprefix = "(Private from " . $m->sender . " -i " . $m->subcontext . ")\n";
            $resend = 1;
            $type = "private-recv-zephyr";
            $zsig = $m->{zsig};
        }
    }
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
    if($this->{zephyr} and $type ne "zephyr") {
        BarnOwl::command('set', 'zsender', $m->sender."/BRIDGE");
        my @args = ('-c', $this->{zephyr}->{class}, '-O', 'forwarded', '-m', $m->body);
        if($m->{instance}) {
            unshift @args, ("-i", $m->{instance});
        }
        if($zsig) {
            unshift @args, ("-s", $zsig);
        }
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
                BarnOwl::command("jwrite", "-a", $this->{jabber}->{account}, "-m", $msgprefix.$m->body, $recipient);
            }
        }
    }
}

1;
