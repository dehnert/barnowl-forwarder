Background
----------

Many groups seem to have some significant number of zephyr users, plus a
handful of users of GTalk or some other IM system. The zephyr users tend to be
sufficiently fond of zephyr that switching entirely to Jabber is a little
unfortunate. On the flip side, zephyr is complicated enough to use that getting
everyone onto zephyr is probably a losing proposition.

barnowl-forwarder aims to solve this problem by allowing Jabber users to get on
a zephyr class by forwarding messages from that user to the class, and to the
class to appropriate Jabber users. It's designed as a BarnOwl module. This
gives it easy support for things like zcrypt, and should make it easy to add
support for AIM or other protocols if a need arises.

Setup
-----

barnowl-forwarder's main configuration file is ``~/.owl/forwarder.json``. The
configuration file is a JSON list of dictionaries describing a single
forwarding instance.  Each instance looks something like::

    {
        "zephyr" : {
            "class" : "classname",
            "zcrypt" : true
        },
        "jabber" : {
            "account" : "jabber-username@example.com",
            "subscribers" : [ "recipient1@example.com" , "recipient2@example.com" ]
        }
    }

The class is the zephyr class that the forwarder should listen for. zcrypt, if
present and true, tells the forwarder to use "zcrypt" instead of "zwrite" in
order to send crypted zephyrs. The Jabber account is the Jabber account that it
will send and receive using. The subscribers are the JIDs that should receive
the messages.

barnowl-forwarder currently depends on doing a bunch of the setup using
BarnOwl's usual interfaces. In particular, the user is also responsible for
setting up:

* ``~/.owl/crypt-table`` if required
* ``~/.zephyr.subs`` as required
* Subbing the Jabber account to the users it needs to be able to send to
