#!/usr/bin/perl

# Where the DSM password lives.
#
# For fifteen releases it lived in /etc/pve/storage.cfg. That file is
# `root:www-data 0640`, and worse: a property PVE does not know is a secret is
# returned by `GET /storage/<id>` to any user holding Datastore.Audit — so a
# read-only auditor was handed a DSM credential with SAN Manager rights.
#
# PVE has a first-class mechanism for this and the plugin was not using it.
# `PVE::Storage::Plugin::sensitive_properties` falls back to a hardcoded list
# when a plugin declares none — `encryption-key keyring master-pubkey password` —
# and `syno-password` is not in it. The omission therefore failed silently, and in
# the least safe direction, which is the only reason it lasted.
#
# These tests need no Proxmox VE: they read plugindata and drive the credential
# file helpers against a temporary directory.

use strict;
use warnings;
use Test::More;
use lib 'lib';

my $HAVE_PVE = eval { require PVE::Storage::Plugin; 1 };

# --- the declaration, which is the whole fix -------------------------------
#
# Checked from the source rather than by loading the plugin, so this runs on a
# machine with no Proxmox VE — which is how CI runs it.
my $src = do {
    open(my $fh, '<', 'lib/PVE/Storage/Custom/SynologySANPlugin.pm')
        or BAIL_OUT('cannot read the plugin');
    local $/; <$fh>;
};

my ($pd) = $src =~ /\nsub plugindata \{(.*?)\n\}/s;
ok($pd, 'plugindata is there');

like($pd, qr/'sensitive-properties'\s*=>/,
     'plugindata declares sensitive-properties — without it PVE writes the'
   . ' password into storage.cfg');

for my $prop (qw(syno-password syno-chap-password syno-otp syno-device-id)) {
    like($pd, qr/'\Q$prop\E'\s*=>\s*1/,
         "$prop is declared sensitive");
}

# The device token is a standing second-factor bypass. It was being written to
# storage.cfg alongside the password, and it is just as good as one.
like($pd, qr/second-factor bypass/,
     'and the reason the device token counts as a credential is recorded');

# --- nothing may reach $scfg any more --------------------------------------
#
# The hooks used to do `$scfg->{'syno-device-id'} = $token`, which put it
# straight back into the config PVE was about to write.
unlike($src, qr/\$scfg->\{'syno-(?:password|device-id|otp|chap-password)'\}\s*=/,
       'no hook assigns a credential into $scfg, which PVE would then persist');

like($src, qr/delete \$scfg->\{\$_\} for qw\(syno-password/,
     'and on_update_hook_full strips what an older version left behind');

# --- the file helpers ------------------------------------------------------
SKIP: {
    skip 'needs PVE::Tools for file_set_contents', 11 if !eval { require PVE::Tools; 1 };
    require PVE::Storage::Custom::SynologySANPlugin;
    my $P = 'PVE::Storage::Custom::SynologySANPlugin';

    my $dir = "/tmp/jt-syno-cred-test.$$";
    mkdir $dir;
    # $CRED_DIR is a package variable and not a constant precisely so this works:
    # a constant would be folded into its call sites at compile time.
    our $CRED_DIR;
    local *CRED_DIR = \$PVE::Storage::Custom::SynologySANPlugin::CRED_DIR;
    local $PVE::Storage::Custom::SynologySANPlugin::CRED_DIR = $dir;

    my $file = $P->_cred_file('mystore');
    is($file, "$dir/mystore.syno", 'the file is named after the storage');

    # A storage id that tries to choose the file must not be able to. What
    # matters is not that the name contains no dots — `_.._etc_shadow.syno` is a
    # perfectly harmless flat filename — but that the result never leaves the
    # directory. The first version of this test asserted the wrong property and
    # failed on a sanitiser that was working correctly.
    for my $evil ('../../etc/shadow', 'a/../b', '/etc/shadow') {
        my $got = $P->_cred_file($evil);
        next if !defined $got;
        my ($dir_part) = $got =~ m{\A(.*)/[^/]+\z};
        is($dir_part, $dir, "'$evil' still resolves inside the credential directory");
    }
    is($P->_cred_file('..'), undef, "a storage id of '..' yields no file at all");

    $P->_write_creds('mystore', { password => 's3cret', 'device-id' => 'tok' });
    ok(-e $file, 'the credential file was written');

    my $mode = (stat($file))[2] & 07777;
    is($mode, 0600, 'and is readable only by root');

    my $back = $P->_read_creds('mystore');
    is_deeply($back, { password => 's3cret', 'device-id' => 'tok' },
              'what was written is what comes back');

    # A stray line in the file is not an instruction.
    open(my $fh, '>>', $file); print $fh "unexpected-key=whatever\n"; close($fh);
    my $filtered = $P->_read_creds('mystore');
    ok(!exists $filtered->{'unexpected-key'},
       'an unrecognised key is dropped rather than carried into the API call');

    # Nothing to keep means no file, so "no credential" and "empty credential"
    # are not the same state.
    $P->_write_creds('mystore', { password => '' });
    ok(!-e $file, 'writing nothing removes the file instead of leaving it empty');

    $P->_write_creds('mystore', { password => 'x' });
    $P->_delete_creds('mystore');
    ok(!-e $file, '_delete_creds removes it');

    unlink glob("$dir/*"); rmdir $dir;
}

# --- PVE's own machinery, which is the only opinion that counts -------------
#
# The declaration is only worth anything if PVE reads it. This drives the actual
# code path: `sensitive_properties` for the type, then `extract_sensitive_params`,
# which is what removes the values from the parameters before the config is
# written. Skipped where there is no Proxmox VE, which is how CI runs.
SKIP: {
    skip 'no Proxmox VE on this machine', 5 if !$HAVE_PVE;
    skip 'needs PVE::Tools', 5 if !eval { require PVE::Tools; PVE::Tools->import('extract_sensitive_params'); 1 };

    require PVE::Storage::Custom::SynologySANPlugin;
    PVE::Storage::Custom::SynologySANPlugin->register;

    my $s = PVE::Storage::Plugin::sensitive_properties('synologysan');
    is_deeply([sort @$s],
              [qw(syno-chap-password syno-device-id syno-otp syno-password)],
              'PVE itself reports all four as sensitive for this type');

    # The default PVE falls back to when a plugin declares nothing. `syno-password`
    # is not in it, which is why the omission was silent.
    my $default = PVE::Storage::Plugin::sensitive_properties('nfs');
    ok(!grep({ $_ eq 'syno-password' } @$default),
       'and would NOT have been covered by the fallback list');

    my $param = {
        'syno-portal'    => '192.0.2.1',
        'syno-username'  => 'dev',
        'syno-password'  => 'the-secret',
        'syno-device-id' => 'a-token',
        'syno-location'  => '/volume1',
    };
    my $taken = PVE::Tools::extract_sensitive_params($param, $s, []);

    is_deeply([sort keys %$taken], ['syno-device-id', 'syno-password'],
              'both supplied credentials are handed to the hook instead');
    ok(!exists $param->{'syno-password'},
       'and the password does not reach the config that gets written');
    ok(!exists $param->{'syno-device-id'},
       'nor does the device token, which is a standing second-factor bypass');
}

# --- the fallback that keeps existing installations working ----------------
like($src, qr/fifteen releases wrote the password into storage\.cfg/i,
     'the plaintext fallback is deliberate and documented, not an oversight');
like($src, qr/Datastore\.Audit/,
     'and the migration notice tells the operator what the exposure was');


# --- CHAP: the regression that moving the credentials introduced ------------
#
# `syno-chap-password` is a sensitive property, so $scfg->{'syno-chap-password'}
# is undef on any storage added by 0.5.3~beta1 or later. Both CHAP call sites
# were still reading it from there, and both consumers fell back to
# `$opt{chap_password} // ''` — so the result was not a failure but an EMPTY CHAP
# secret on the target and in the node record. Access control that appears
# configured and protects nothing.

unlike($src, qr/chap_password\s*=>\s*\$scfg->\{/,
       'no CHAP call site reads the secret from $scfg, where PVE strips it');
like($src, qr/sub _chap_password/,
     'there is one accessor for it, so a third call site cannot get it wrong');

for my $mod (qw(Target ISCSI)) {
    my $m = do {
        open(my $fh, '<', "lib/PVE/Storage/Custom/Synology/$mod.pm") or BAIL_OUT("no $mod");
        local $/; <$fh>;
    };
    unlike($m, qr/\$opt\{chap_password\}\s*\/\/\s*''/,
           "$mod.pm does not turn a missing CHAP secret into an empty one");
    my %phrase = (
        Target => qr/there is no CHAP secret/,
        ISCSI  => qr/CHAP username was given for .* with no secret/,
    );
    like($m, $phrase{$mod}, "$mod.pm refuses instead");
}

# And it really refuses, rather than merely mentioning it in a comment.
{
    package ChapAPI;
    sub new { bless { sent => [] }, shift }
    sub storeid { 'chaptest' }
    # `ensure` now checks the target ceiling before it creates anything, so the mock
    # has to answer `limits`. undef means "the NAS did not say", which is the
    # documented signal to stop guarding — exactly what a fixture wants here.
    sub limits { { luns => undef, targets => undef, snapshots_per_lun => undef } }
    # `ensure` lists first, so the listing has to be a real (empty) one or the
    # code dies before it ever reaches the CHAP block.
    sub call {
        my ($self, $api, $method, %p) = @_;
        push @{ $self->{sent} }, [ $method, \%p ];
        return { success => 1, data => { targets => [] } } if $method eq 'list';
        return { success => 1, data => { target_id => 1 } };
    }
    sub call_ok { my $s = shift; return $s->call(@_)->{data} }
    sub sent { $_[0]->{sent} }
}
# The refusal really fires — the block lives in Target::ensure, not create.
{
    require PVE::Storage::Custom::Synology::Target;
    my $mock = ChapAPI->new;
    my $tgt = PVE::Storage::Custom::Synology::Target->new($mock);

    my $err = '';
    eval { $tgt->ensure(name => 'x-tgt', chap_user => 'someone') } or $err = $@;
    like($err, qr/there is no CHAP secret/,
         'a CHAP username with no secret is refused rather than defaulted');
    like($err, qr/accepts anyone while reporting that CHAP is on/,
         'and the message says what an empty secret would actually mean');
    ok(!grep({ $_->[0] eq 'create' } @{ $mock->sent }),
       'no target was created with an empty secret — the refusal precedes it');

    # With a secret it gets past the refusal.
    $err = '';
    eval { $tgt->ensure(name => 'x-tgt', chap_user => 'someone',
                        chap_password => 'a-real-secret') } or $err = $@;
    unlike($err, qr/there is no CHAP secret/,
           'and a supplied secret is accepted');
}


# --- the release-blocker: a sensitive property must NOT be required ---------
#
# PVE strips sensitive properties from the parameters BEFORE check_config
# validates them (API2/Storage/Config.pm does them in that order). So declaring
# one `optional => 0` makes PVE reject the add for a value that WAS supplied:
#
#   # pvesm add synologysan pvesyno --syno-password '...' ...
#   missing value for required option 'syno-password'
#
# 0.5.3~beta1 and 0.5.4~beta1 could not be used at all. No unit test could have
# caught it — the fault is in the interaction between two PVE stages — so this
# one checks the declaration that makes it impossible, and on_add_hook's own
# enforcement that replaces PVE's.

# Matched on the one-line `options` form specifically. A looser pattern hit the
# property DESCRIPTION block instead, which has no `optional` key at all — so the
# first version of this assertion failed against correct code.
my ($optval) = $src =~ /'syno-password'\s+=>\s+\{\s*optional\s*=>\s*(\d)\s*\}/;
ok(defined $optval, 'syno-password has an entry in the options list');
is($optval, '1',
   'and is OPTIONAL to PVE, which cannot validate what it never sees');

like($src, qr/syno-password is required/,
     'the plugin enforces its presence itself instead');

for my $prop (qw(syno-chap-password syno-otp syno-device-id)) {
    my ($v) = $src =~ /'\Q$prop\E'\s+=>\s+\{\s*optional\s*=>\s*(\d)\s*\}/;
    is($v, '1', "$prop is optional too, for the same reason");
}

# --- the update hook must validate the EFFECTIVE config, not $scfg ----------
#
# PVE applies $delete AFTER the hook returns, so $scfg still holds a property the
# operator is removing while the credential store has already honoured it.
# `pvesm set --delete syno-chap-username,syno-chap-password` refused itself.
like($src, qr/my %effective = %\$scfg;/,
     'the update hook builds the effective config');
like($src, qr/delete \$effective\{\$_\} for \@\{ \$delete/,
     'applying the deletions, which PVE has not applied yet');

# --- CHAP on a target that already exists ----------------------------------
{
    my $tm = do {
        open(my $fh, '<', 'lib/PVE/Storage/Custom/Synology/Target.pm') or BAIL_OUT('no Target');
        local $/; <$fh>;
    };
    like($tm, qr/sub reconcile_chap/,
         'Target reconciles CHAP on an existing target, not only on creation');
    like($tm, qr/sub set_chap/, 'and has a writer the update hook can call directly');

    # The early-return path must reach the reconcile, which is the whole bug.
    my ($ensure) = $tm =~ /\nsub ensure \{(.*?)\n\}/s;
    like($ensure, qr/reconcile_chap/,
         'ensure calls it on the path that returns an existing target — the path'
       . ' that used to skip CHAP entirely');
}

done_testing();
