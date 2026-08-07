package PVE::Storage::Custom::Synology::API;

# DSM Web API transport.
#
# Everything here is shaped by what a DS918+ on DSM 7.1.1 actually did, not by
# what either public reference client does — they disagree with each other, and
# on that NAS each of them is wrong about something:
#
#   * OpenStack Cinder carries the session as an `_sid` form parameter. Every
#     call then fails with 119, SID not found. The cookie is what works, and
#     DSM never sets it — the client has to build it from the login's answer.
#   * Neither client sends the anti-CSRF token. On a NAS with that setting on —
#     it was on, on the test NAS — every call answers 105, insufficient
#     permission, which reads exactly like a privilege problem and is not one.
#
# So both session carriers and both token carriers are sent. Sending a carrier
# a NAS ignores costs nothing; missing the one it needs costs a day of
# debugging the wrong thing.
#
# The rule that is not about correctness but about not damaging the NAS:
# DSM's Auto Block was configured for three failed logins in five minutes and a
# ONE DAY block of the offending address. Proxmox VE polls every storage every
# ten seconds on every node, so a wrong password would lock a node out of the
# NAS in about thirty seconds — and the symptom afterwards is a refused
# connection, which looks like a dead NAS rather than a bad credential.
# Credential failures therefore latch and never retry. See `_is_credential_error`.

use strict;
use warnings;

use PVE::Storage::Custom::Synology::Naming;

use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use JSON qw(decode_json encode_json);
use LWP::UserAgent;
use HTTP::Request::Common qw(POST);
use Time::HiRes qw(time);

use constant {
    # Where the credential latch lives. It has to be a FILE: the latch was an
    # instance field, and the plugin builds a new API object for every call, so
    # it died with the object. pvestatd polls every ten seconds — three polls
    # would have been three failed logins and a one-day block, which is exactly
    # what the latch exists to prevent. It protected nothing until it persisted.
    LATCH_DIR         => '/run/jt-pve-storage-synology',

    DEFAULT_PORT      => 5001,
    DEFAULT_TIMEOUT   => 30,
    STATUS_TIMEOUT    => 5,
    # A login is only ever retried across PORTALS, never against the same one.
    MAX_LOGIN_RETRY   => 1,
};

# DSM's common codes. These are the only thing worth keying a decision on: the
# messages beside them are for a human, and this project never matches on text.
our %COMMON_ERR = (
    100 => 'unknown error',
    101 => 'invalid parameter',
    102 => 'API does not exist',
    103 => 'method does not exist',
    104 => 'version not supported',
    105 => 'insufficient permission, or the anti-CSRF token was not echoed',
    106 => 'session timeout',
    107 => 'session interrupted by a duplicate login',
    119 => 'SID not found',
    # 117: measured on BOTH DSM 7.1.1 and 7.3.2, asking
    # `SYNO.Core.Storage.Volume get` for a well-formed volume path that does not
    # exist (`/volume2` on a NAS that has only `/volume1`). Not in either
    # reference client and not in Synology's published list.
    #
    # A path that is not volume-shaped at all — `/nonsense` — answers SUCCESS
    # with no volume instead, which is the other branch Health already had. So
    # the same operator mistake arrives two different ways, and before this the
    # 117 way was reported as "the NAS did not answer" while the NAS had
    # answered perfectly clearly.
    117 => 'no such volume',
    400 => 'invalid credentials',
    402 => 'account disabled, or two-factor authentication required',
    403 => 'one-time password required',
    404 => 'one-time password rejected',
);

# SAN Manager's own codes. Those marked (observed) were established against
# hardware and appear in neither reference client.
our %ISCSI_ERR = (
    18990002 => 'out of free space',
    18990004 => 'no such object (observed)',
    18990068 => 'name too long — AND THE OBJECT MAY EXIST ANYWAY (observed)',
    18990500 => 'bad LUN type',
    18990503 => 'illegal name (observed)',
    18990505 => 'bad LUN UUID',
    18990508 => 'a required parameter is missing (observed)',
    18990531 => 'no such LUN',
    18990710 => 'malformed identifier — an id must be sent as a JSON string,'
              . ' not a bare number (observed)',
    18990532 => 'no such snapshot',
    18990538 => 'duplicate LUN name',
    18990541 => 'LUN count limit reached',
    18990542 => 'target count limit reached',
    18990543 => 'snapshot count limit reached',
    18990744 => 'duplicate target name',
);

# A session that has expired is an ordinary event, not an error: DSM's session
# timeout was fifteen minutes on the test NAS, so a storage nobody has touched
# for a quarter of an hour meets it on the very next poll.
my %SESSION_EXPIRED = map { $_ => 1 } (105, 106, 119);

# A rejected credential must never be retried on a schedule — see the Auto
# Block note at the top of this file.
my %CREDENTIAL_ERR = map { $_ => 1 } (400, 402, 403, 404);

sub new {
    my ($class, %opt) = @_;

    my $portals = $opt{portals};
    $portals = [ split(/\s*,\s*/, $portals // '') ] if !ref $portals;
    die "no management address given\n" if !@$portals;

    my $self = bless {
        portals   => $portals,
        # Which portal to try first. Rotated by a failure, and deliberately
        # sticky: the next request should start where the last one succeeded.
        portal_ix => 0,
        port      => $opt{port} // DEFAULT_PORT,
        username  => $opt{username},
        password  => $opt{password},
        otp       => $opt{otp},
        device_id => $opt{device_id},
        ssl_verify => $opt{ssl_verify} ? 1 : 0,
        tls_ca    => $opt{tls_ca},
        # The health path uses a short timeout and a single attempt: the next
        # poll is the retry, and a storage that hangs must not hold up
        # `pvesm status` for every other storage on the node.
        status    => $opt{status} ? 1 : 0,
        timeout   => $opt{timeout} // ($opt{status} ? STATUS_TIMEOUT : DEFAULT_TIMEOUT),
        storeid   => $opt{storeid} // '<unnamed>',
        debug     => $opt{debug} ? 1 : 0,

        sid        => undef,
        syno_token => undef,
        api_info   => undef,
        # Latched when DSM rejects the credentials. Nothing retries until the
        # storage configuration changes and a new object is constructed.
        credential_refused => undef,
        # Set for the lifetime of one outer request once every portal has been
        # found unreachable, so nested layers do not each cycle the whole list.
        # A related project measured a 2-second status timeout becoming 21
        # seconds on a dead array precisely because they did.
        all_portals_down => 0,
        # The pid that built this object. DESTROY below must not act on a
        # forked child's copy.
        owner_pid => $$,
    }, $class;

    return $self;
}

sub storeid { return $_[0]->{storeid} }

# ---------------------------------------------------------------------------
# The credential latch, which must outlive one process
# ---------------------------------------------------------------------------
#
# Under /run rather than /var/lib deliberately: a reboot is a legitimate reason
# to try again, and an operator who has fixed the account should not have to know
# about a file. A configuration change clears it explicitly (on_update_hook).

sub _latch_file {
    my ($self) = @_;
    my $safe = PVE::Storage::Custom::Synology::Naming::filename_component(
        $self->{storeid}) or return undef;
    return LATCH_DIR . "/$safe.credential-refused";
}

sub _read_latch {
    my ($self) = @_;
    my $f = $self->_latch_file or return undef;
    open(my $fh, '<', $f) or return undef;
    my $why = <$fh> // '';
    close($fh);
    chomp $why;
    return length($why) ? $why : 'a previous credential failure';
}

sub _write_latch {
    my ($self, $why) = @_;
    my $f = $self->_latch_file or return;
    mkdir LATCH_DIR, 0700 if !-d LATCH_DIR;
    if (open(my $fh, '>', $f)) {
        print $fh "$why\n";
        close($fh);
    }
    return;
}

# Called when the configuration changes: the operator has had a chance to fix it.
sub clear_credential_latch {
    my ($class_or_self, $storeid) = @_;
    $storeid = $class_or_self->{storeid} if ref $class_or_self;
    return if !defined $storeid;
    my $safe = PVE::Storage::Custom::Synology::Naming::filename_component($storeid)
        or return;
    unlink LATCH_DIR . "/$safe.credential-refused";
    return;
}

# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

sub error_text {
    my ($code) = @_;
    return 'no error' if !defined $code;
    my $t = $COMMON_ERR{$code} // $ISCSI_ERR{$code} // 'undocumented';
    return "$code ($t)";
}

sub is_session_expired { return defined $_[0] && $SESSION_EXPIRED{ $_[0] } }
sub is_credential_error { return defined $_[0] && $CREDENTIAL_ERR{ $_[0] } }

# Keyed on the code, never on the words the NAS chose — rule 25.
sub is_no_such_volume { return defined $_[0] && $_[0] == 117 }

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

sub _ua {
    my ($self) = @_;
    return $self->{ua} if $self->{ua};

    my %ssl;
    if ($self->{ssl_verify}) {
        $ssl{ssl_opts} = { verify_hostname => 1, SSL_verify_mode => 1 };
        $ssl{ssl_opts}{SSL_ca_file} = $self->{tls_ca} if $self->{tls_ca};
    } else {
        # DSM ships a self-signed certificate. A default of "verify" would mean
        # almost no fresh DSM could be added at all, and a default nobody can
        # use protects nobody. syno-ssl-verify turns it on.
        $ssl{ssl_opts} = { verify_hostname => 0, SSL_verify_mode => 0 };
    }

    my $ua = LWP::UserAgent->new(
        timeout => $self->{timeout},
        agent   => 'jt-pve-storage-synology',
        %ssl,
    );
    # A redirect to a login page is an answer, not a place to resend a
    # credential: every request here carries one.
    $ua->max_redirect(0);

    $self->{ua} = $ua;
    return $ua;
}

sub _portal { return $_[0]->{portals}[ $_[0]->{portal_ix} ] }

sub _rotate_portal {
    my ($self) = @_;
    return 0 if @{ $self->{portals} } < 2;
    $self->{portal_ix} = ($self->{portal_ix} + 1) % scalar @{ $self->{portals} };
    # A session belongs to the address that issued it, and DSM binds it to the
    # client IP as well. Rotating means starting again.
    $self->{sid} = undef;
    $self->{syno_token} = undef;
    return 1;
}

# One HTTP round trip, to whichever portal is current.
#
# The URL is built HERE and not by the caller. A related project built it
# before a login that rotates portals, so every retry went on travelling to the
# address that had just been found dead.
sub _http {
    my ($self, $path, $form) = @_;

    my $portal = $self->_portal;
    # A portal may carry its own port. Splitting on the LAST colon leaves IPv6
    # literals in brackets alone.
    my ($host, $port) = ($portal, $self->{port});
    if ($portal =~ /\A(.+):(\d+)\z/ && $1 !~ /:\z/) {
        ($host, $port) = ($1, $2);
    }

    my $url = "https://$host:$port/webapi/$path";
    my $req = POST $url, [ %$form ];

    # Both session carriers, for the reason at the top of this file.
    if (defined $self->{sid}) {
        $req->header(Cookie => "id=$self->{sid}");
        $req->header('X-SYNO-TOKEN' => $self->{syno_token})
            if defined $self->{syno_token};
    }

    my $res = eval { $self->_ua->request($req) };
    if (!$res) {
        my $err = $@ || 'request failed';
        chomp $err;
        return { transport => $err };
    }

    # DSM answers 200 for a refused call, and the CSI driver treats 302 as a
    # carrier of a real answer too.
    if (!$res->is_success && $res->code != 302) {
        return { transport => $res->status_line, http => $res->code };
    }

    # decoded_content returns characters; decode_json wants bytes. DSM answers
    # text/* often enough that the charset guess turns every byte above 0x7F
    # into a wide character, and decode_json then dies with "Wide character".
    my $body = $res->decoded_content(charset => 'none');
    my $json = eval { decode_json($body) };
    if (!$json || ref $json ne 'HASH') {
        my $snip = $body // '';
        $snip =~ s/\s+/ /g;
        $snip = length($snip) > 120 ? substr($snip, 0, 120) . '...' : $snip;
        # Quote the first bytes: on a first run the difference between an HTML
        # error page, an empty body and a login form is the whole diagnosis.
        return { transport => "response is not JSON: $snip", http => $res->code };
    }

    return {
        http    => $res->code,
        success => $json->{success} ? 1 : 0,
        error   => (ref $json->{error} eq 'HASH' ? $json->{error}{code} : undef),
        data    => $json->{data},
    };
}

# ---------------------------------------------------------------------------
# API discovery
# ---------------------------------------------------------------------------

# Versions and CGI paths come from the NAS, never from a constant. Cinder's
# driver does this and Synology's CSI driver does not, and the CSI driver is
# the one whose issue tracker carries DSM-upgrade breakage. The test NAS also
# advertises SYNO.API.Auth on entry.cgi, not the auth.cgi both clients hardcode.
sub discover {
    my ($self) = @_;
    return $self->{api_info} if $self->{api_info};

    my $r = $self->_http('query.cgi', {
        api     => 'SYNO.API.Info',
        version => 1,
        method  => 'query',
        query   => 'all',
    });

    if (!$r->{success}) {
        my $why = $r->{transport} // error_text($r->{error});
        die "storage '$self->{storeid}': the NAS would not describe its API"
          . " ($why). Nothing else can be trusted without it: every version"
          . " this plugin would send would be a guess.\n";
    }

    die "storage '$self->{storeid}': SYNO.API.Info returned no API list\n"
        if ref $r->{data} ne 'HASH';

    $self->{api_info} = $r->{data};
    return $self->{api_info};
}

sub api_entry {
    my ($self, $api) = @_;
    my $info = $self->discover;
    return $info->{$api};
}

sub has_api { return defined $_[0]->api_entry($_[1]) }

# The highest version the NAS admits to, capped by what this plugin was written
# against. Claiming a version the NAS does not have earns 104.
sub api_version {
    my ($self, $api, $max_supported) = @_;
    my $e = $self->api_entry($api)
        or die "storage '$self->{storeid}': this DSM does not provide $api\n";
    my $v = $e->{maxVersion} // 1;
    $v = $max_supported if defined $max_supported && $v > $max_supported;
    my $min = $e->{minVersion} // 1;
    die "storage '$self->{storeid}': $api needs at least version $min,"
      . " which this plugin does not implement\n" if $v < $min;
    return $v;
}

sub api_path {
    my ($self, $api) = @_;
    my $e = $self->api_entry($api);
    return ($e && $e->{path}) ? $e->{path} : 'entry.cgi';
}

sub api_wants_json {
    my ($self, $api) = @_;
    my $e = $self->api_entry($api);
    return ($e && ($e->{requestFormat} // '') eq 'JSON') ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Session
# ---------------------------------------------------------------------------

sub login {
    my ($self) = @_;
    return 1 if defined $self->{sid};

    # Read from disk, not from this object: the object is new on every call.
    $self->{credential_refused} //= $self->_read_latch;

    if (my $why = $self->{credential_refused}) {
        # Latched. Retrying is what trips Auto Block and locks this node out of
        # the NAS for a day.
        die "storage '$self->{storeid}': not retrying after $why."
          . " Fix the credentials in the storage configuration; this plugin"
          . " will not attempt another login until it changes, because DSM"
          . " blocks an address after a few failures.\n";
    }

    my $attempts = @{ $self->{portals} };
    my $last;

    for my $try (1 .. $attempts) {
        my %p = (
            api      => 'SYNO.API.Auth',
            method   => 'login',
            version  => $self->api_version('SYNO.API.Auth', 6),
            account  => $self->{username},
            passwd   => $self->{password},
            session  => 'dsm',
            format   => 'sid',
            enable_syno_token => 'yes',
        );

        # Two-factor: the first login sends the code and asks for a device
        # token; every later one sends the token instead. Synology's own CSI
        # driver cannot do this at all.
        if (defined $self->{device_id} && length $self->{device_id}) {
            $p{device_id} = $self->{device_id};
        } elsif (defined $self->{otp} && length $self->{otp}) {
            $p{otp_code} = $self->{otp};
            $p{enable_device_token} = 'yes';
        }

        my $r = $self->_http($self->api_path('SYNO.API.Auth'), \%p);

        if ($r->{success}) {
            $self->{sid}        = $r->{data}{sid};
            $self->{syno_token} = $r->{data}{synotoken};
            $self->{new_device_id} = $r->{data}{did} if $r->{data}{did};
            $self->{all_portals_down} = 0;
            die "storage '$self->{storeid}': DSM accepted the login but"
              . " returned no session id\n" if !defined $self->{sid};
            return 1;
        }

        my $code = $r->{error};
        $last = $r->{transport} // error_text($code);

        if (is_credential_error($code)) {
            # Never rotate and never retry on a bad credential: the next portal
            # is usually the same NAS, and each attempt counts towards a block.
            $self->{credential_refused} = error_text($code);
            # Persisted, so the NEXT poll does not spend another of the three
            # attempts DSM allows before it blocks this address for a day.
            $self->_write_latch(error_text($code));
            my $hint = '';
            $hint = " Re-run with the account's one-time code (syno-otp)."
                if defined $code && ($code == 403 || $code == 402);
            die "storage '$self->{storeid}': DSM refused the credentials"
              . " — " . error_text($code) . ".$hint\n";
        }

        last if !$self->_rotate_portal;
    }

    $self->{all_portals_down} = 1;
    die "storage '$self->{storeid}': could not log in to any of"
      . " (" . join(', ', @{ $self->{portals} }) . "): $last\n";
}

sub logout {
    my ($self) = @_;
    return if !defined $self->{sid};
    local $@;
    eval {
        $self->_http($self->api_path('SYNO.API.Auth'), {
            api     => 'SYNO.API.Auth',
            method  => 'logout',
            version => 1,
            session => 'dsm',
            _sid    => $self->{sid},
        });
    };
    $self->{sid} = undef;
    $self->{syno_token} = undef;
    return;
}

# Log out when the object goes away, however it goes away.
#
# Twenty of this plugin's methods build an API object, and nine of them have a
# `die` between the construction and the `logout` — a rollback that refuses, a
# resize the NAS rejects, a `path()` on a volume that is gone. Every one of those
# leaked a DSM session, and R-13 established that a second login does NOT evict
# the first, so they accumulate on the NAS for as long as DSM keeps them. A
# repeatedly failing operation is a session leak on a per-attempt basis.
#
# Fixing this at the nine call sites was the wrong answer: it is nine chances to
# forget, and the tenth method has not been written yet. Perl unwinds through
# DESTROY on the die path, so the object cleans up after itself.
#
# Four things this must get right, all of them load-bearing:
#
#   1. **`$@` must survive.** Not on the die path — Perl 5.14 and later save and
#      restore `$@` around destructors called while a `die` propagates, and a test
#      written to prove otherwise passed with the `local` removed. It is ORDINARY
#      SCOPE EXIT that is exposed: this plugin is full of
#      `eval { ... }; if ($@) { ... }`, and an object released between the two
#      would replace the caller's error with whatever the logout did. Rule 14 in
#      a place that looks like it could not possibly be reachable.
#   2. **Not during global destruction.** At interpreter shutdown the HTTP
#      client and its dependencies may already be gone, and the failure would be
#      an unhelpful error from inside a module the operator has never heard of.
#      Nothing needs the logout then: the process is ending.
#   3. **Not in a forked child.** PVE forks workers. A child inheriting this
#      object and logging out on exit would invalidate the PARENT's session,
#      which would look exactly like the NAS dropping sessions at random.
#   4. **Never die.** A die in DESTROY becomes a warning at best, and during
#      unwinding it can replace the real error.
sub DESTROY {
    my ($self) = @_;

    return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
    return if !defined $self->{sid};
    return if ($self->{owner_pid} // 0) != $$;

    # Both of these matter: `local $@` so a failure in here cannot overwrite the
    # error being propagated, and the eval so it cannot escape at all.
    local $@;
    eval { $self->logout };
    return;
}

# A device token issued by an OTP login, for the caller to persist so the code
# is only ever typed once. It is a standing second-factor bypass and is handled
# with the same care as the password.
sub take_device_token {
    my ($self) = @_;
    my $t = delete $self->{new_device_id};
    return $t;
}

# ---------------------------------------------------------------------------
# What this model can do, and how much of it
# ---------------------------------------------------------------------------

# `SYNO.Core.System` `info` with type=define answers with 316 keys on the test
# NAS, and among them are the model's OWN ceilings. Neither reference client
# reads them, and they matter because the number that gets quoted — 512 LUNs and
# 256 targets — is the PRODUCT LINE's ceiling, not any particular model's.
#
# Synology's SAN Manager software specification states 512/256 and footnotes it:
# "the maximum number of LUNs, targets, and snapshots varies according to models".
# The DS918+'s own Product Specification says 256 LUNs and 128 targets, which is
# exactly what this call reports. **The API and the datasheet agree**; an earlier
# version of this comment called it a discrepancy, and that was wrong.
#
# Published per-model figures run 512/256, 256/128, 128/64 and — on J, Value and
# some small Plus models — **4 LUNs and 2 targets**, which one VM can exhaust. The
# figures are not monotonic with generation either: a DS1825+ publishes 128/64
# where the older DS1821+ publishes 256/128. So there is nothing to infer from the
# model name, and asking the NAS is the only correct approach. See docs/LIMITS.md.
#
# Cached for the life of the object: it is a property of the model, and the
# health path must not fetch it every ten seconds.
sub system_define {
    my ($self) = @_;
    return $self->{define} if $self->{define};

    my $r = $self->call('SYNO.Core.System', 'info', type => 'define');
    return {} if !$r->{success} || ref $r->{data} ne 'HASH';

    $self->{define} = $r->{data};
    return $self->{define};
}

# The ceilings, as this model reports them. undef for one it does not report —
# and undef must not be read as "no limit": it means "this NAS did not say", so
# a caller can only stop guarding, never conclude there is room.
sub limits {
    my ($self) = @_;
    my $d = $self->system_define;

    my %l;
    for my $pair ([ luns => 'max_iscsiluns' ],
                  [ targets => 'max_iscsitrgs' ],
                  [ snapshots_per_lun => 'max_snapshot_per_lun' ]) {
        my $v = $d->{ $pair->[1] };
        $l{ $pair->[0] } = (defined $v && $v =~ /\A\d+\z/ && $v > 0) ? int($v) : undef;
    }
    return \%l;
}

# The capability gates. A model can run DSM 7.2 and still not support what this
# plugin needs, and a version check would not say why.
sub supports {
    my ($self, $what) = @_;
    my $d = $self->system_define;
    return ($d->{$what} // '') eq 'yes' ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Calls
# ---------------------------------------------------------------------------

# An API whose requestFormat is JSON wants every parameter JSON-encoded: a
# string quoted, a number bare. Synology's CSI driver quotes some parameters
# and not others, which is its own inconsistency and not a licence to copy it.
# Wrap a value that must reach DSM as a JSON *string* even though it looks like
# a number. Identifiers are the case: `target_id` sent as a bare 4 is refused
# with 18990710, and sent as "4" it works. Both reference clients quote their
# identifiers; the reason only becomes visible when you stop.
sub json_string {
    my ($v) = @_;
    my $s = encode_json([ defined $v ? "$v" : '' ]);
    $s =~ s/\A\[//; $s =~ s/\]\z//;
    return $s;
}

sub _encode_value {
    my ($v) = @_;
    return $v if !defined $v;
    return $v if ref $v;                      # already-encoded JSON text
    return $v if $v =~ /\A"/;                 # already a JSON string
    return $v if $v =~ /\A-?(?:0|[1-9][0-9]*)\z/;   # a plain integer
    return $v if $v =~ /\A[\[\{]/;            # already JSON
    return 'true'  if $v eq 'true';
    return 'false' if $v eq 'false';
    my $s = encode_json([ "$v" ]);
    $s =~ s/\A\[//; $s =~ s/\]\z//;
    return $s;
}

# Returns the whole envelope. Nothing here dies on a DSM-level error: the code
# is what the caller needs in order to tell "no such object" from "could not
# ask", and those are different answers.
sub call {
    my ($self, $api, $method, %params) = @_;

    my $max = delete $params{_max_version};
    my $version = $self->api_version($api, $max);

    $self->login;

    my $r = $self->_call_once($api, $method, $version, \%params);

    # A session that timed out is the ordinary path, not an exception: DSM
    # expires one after fifteen idle minutes. Re-login once and resend.
    if (!$r->{success} && is_session_expired($r->{error})) {
        $self->{sid} = undef;
        $self->{syno_token} = undef;
        $self->login;
        $r = $self->_call_once($api, $method, $version, \%params);
    }

    return $r;
}

sub _call_once {
    my ($self, $api, $method, $version, $params) = @_;

    my %form = (api => $api, method => $method, version => $version);

    my $json = $self->api_wants_json($api);
    for my $k (keys %$params) {
        next if !defined $params->{$k};
        $form{$k} = $json ? _encode_value($params->{$k}) : $params->{$k};
    }

    $form{_sid} = $self->{sid} if defined $self->{sid};
    $form{SynoToken} = $self->{syno_token} if defined $self->{syno_token};

    return $self->_http($self->api_path($api), \%form);
}

# The form most callers want: succeed, or die with something an operator can
# act on. Use `call` where the error CODE is the answer.
sub call_ok {
    my ($self, $api, $method, %params) = @_;
    my $what = delete $params{_what} // "$api $method";

    my $r = $self->call($api, $method, %params);
    return $r->{data} if $r->{success};

    my $why = $r->{transport} // error_text($r->{error});
    die "storage '$self->{storeid}': $what failed — $why\n";
}

1;
