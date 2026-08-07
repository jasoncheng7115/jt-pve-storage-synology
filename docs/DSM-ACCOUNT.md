# The DSM account this plugin needs

**Do not give this plugin your `admin` account.** Make a dedicated one, turn
everything off that it does not need, and restrict where it may log in from.
This page is how, and it is honest about the part Synology does not let you
restrict.

Everything below was read from a **DS918+ running DSM 7.1.1-42962 Update 9**
, read-only. Where a claim could not be established that way, it
says so.

---

## The short version

```
Create a local user, e.g.  pve-storage
  Groups            administrators          <-- required, and see below
  Shared folders    No access to everything
  Applications      Deny everything except DSM
  Quota             none needed
  Speed limit       none needed
  2FA               optional (see below — the plugin can carry a device token)
Then, in Control Panel:
  Security > Firewall     allow DSM ports only from your PVE node addresses
  Security > Account      leave Auto Block ON (it protects you; the plugin
                          is written not to trip it)
```

---

## Why `administrators`, and what that does and does not mean

SAN Manager's Web API — `SYNO.Core.ISCSI.LUN`, `SYNO.Core.ISCSI.Target`,
`SYNO.Core.ISCSI.Host`, `SYNO.Core.Storage.Volume` — is part of DSM's core,
not of a package. **DSM has no privilege you can grant for "manage LUNs".**
There is no SAN operator role, and the per-user Application privileges list
does not contain SAN Manager. So a non-administrator account has no documented
way to reach these APIs.

**This is a limitation of DSM, not a shortcut taken by this plugin.** Compared
with the arrays the related projects talk to — where a storage-scoped role can
be created — it is a real step down, and you should know that before you decide
how to network the NAS.

What being in `administrators` does **not** have to mean:

| Also grant? | No, because |
|---|---|
| Access to shared folders | The plugin never reads or writes a file. Set every shared folder to **No access** |
| File Station, Drive, Photos, … | Deny every application except **DSM**. The plugin only ever calls the DSM Web API |
| A home folder | Not used. Disable the user home if your policy allows |
| SSH / rsync | Never used |
| Access from anywhere | See the firewall section |

Hardening the account this way is worth doing even though the group is
privileged: it means a leaked credential cannot be used to browse your files
over SMB or Drive, which is the difference between an incident and a disaster.

### Verifying the minimum for yourself

**This has now been tested and the earlier text on this page was wrong about what
would happen.** A non-administrator account was created on the test NAS and probed:
it did not get as far as being denied the LUN listing with `105`. It was refused at
**login**, with error **402**, both with no groups and as a member of `users`.

The full measurement, and the DSM-interface check that could still narrow it, are in
the section above — see *What the plugin's DSM account actually needs*.

---

## The API calls the plugin makes, in full

Nothing else is called. This is the complete list, so you can audit it.

| API | Methods | Why |
|---|---|---|
| `SYNO.API.Info` | `query` | Discover paths and version ranges. **No session needed** |
| `SYNO.API.Auth` | `login`, `logout` | Session |
| `SYNO.Core.System` | `info` | Model, firmware, and the capability gates |
| `SYNO.Core.ISCSI.Node` | `list` | The NAS's own uuid, used as the storage's identity |
| `SYNO.Core.Storage.Volume` | `list`, `get` | Which volume, its filesystem, its free space |
| `SYNO.Core.ISCSI.LUN` | `list`, `get`, `create`, `set`, `delete`, `clone`, `map_target`, `unmap_target`, `take_snapshot`, `list_snapshot`, `get_snapshot`, `delete_snapshot`, `clone_snapshot` | One VM disk is one LUN |
| `SYNO.Core.ISCSI.Target` | `list`, `get`, `create`, `set`, `delete` | The iSCSI target the nodes log in to |
| `SYNO.Core.ISCSI.Host` | to be determined | Restricting the target to your nodes' IQNs |
| `SYNO.Core.Network.Interface` | `list` | Finding the data portals |

The plugin never calls anything under `SYNO.Core.Share`, `SYNO.FileStation`,
`SYNO.Core.User`, `SYNO.Core.Security`, or any package API.

---

## Auto Block: leave it on, and know what it protects you from

Read from the test NAS:

```json
{"enable": true, "attempts": 3, "within_mins": 5, "expire_day": 1}
```

**Three failed logins in five minutes blocks that IP address for a day.**

This matters more than it looks. Proxmox VE polls every storage roughly every
ten seconds, on every node. A storage configured with the wrong password would,
without care, make three failed logins in about thirty seconds — and then that
node is locked out of the NAS for twenty-four hours. On a five-node cluster,
five nodes.

Worse, the symptom afterwards is not "authentication failed". It is a refused
connection, which looks like a network fault or a NAS that has fallen over.

**So this plugin stops on the first credential failure.** A rejected
credential — DSM error 400, 402, 403 or 404 — is reported once, the storage is
marked as needing a human, and nothing retries until the configuration
changes. That is a deliberate design rule, not an implementation detail, and
it is the reason you can safely leave Auto Block enabled.

If you do get blocked: Control Panel → Security → Account → Auto Block →
Allow/Block List, and remove the address.

---

---

### What the plugin's DSM account actually needs

**Measured, and the answer is uncomfortable: this has not been narrowed to a
minimum.** What was established on hardware, with a temporary account created and
deleted with the owner's permission:

- DSM 7.1.1 offers exactly three groups — `administrators`, `http`, `users` — and
  **none of them is iSCSI- or SAN-specific.** There is no "storage operator" role to
  grant.
- An account with **no groups** is refused at login with error **402**.
- An account in **`users`** is *also* refused at login with **402**. So it is not
  that a plain user can log in and then be denied the storage calls — it cannot
  authenticate at all.
- `SYNO.Core.User get` returns only `name` and `uid`. The privilege model is not
  exposed there.
- `SYNO.Core.Group.Member add` to `administrators` reports `success: true` and
  changes nothing, so the API cannot even be used to test the administrator case.

**So the honest position is: the account this plugin uses today is an administrator,
and no smaller working configuration has been demonstrated.** That is a real
consideration for a production deployment and it is stated here rather than glossed.

#### Answered: there is no SAN Manager privilege to grant

On **DSM 7.4.1-90080 (DS918+)** the account's **Applications** tab was
read directly. It lists twenty applications:

> AFP · Active Backup for Business (three entries) · Audio Station · Central
> Management System · Cloud Sync · DSM · Download Station · FTP · File Station ·
> Notification Center · Note Station · SFTP · SMB · Synology Photos · Surveillance
> Station · Synology Drive · Universal Search · rsync · the text editor

**Not one of them is SAN Manager, Storage Manager or iSCSI.** So the access this
plugin needs cannot be allowed or denied as an application: it arrives with
`administrators` and there is nothing smaller to hand out. Together with the API
findings above — a groupless account and a `users` account both refused at login
with 402 — that closes the question. It is a reading of DSM's own interface, not an
inference from the API's silence.

#### What that means you should do

The finding is not only a limitation; it names the smallest configuration that
actually exists. Every one of those twenty applications **can** be denied to the
account, so:

1. A **dedicated** administrator, used by nothing but this plugin.
2. No shared-folder permissions and no home folder.
3. On the **Applications** tab, deny every application. DSM itself is what the API
   logs in through, so leave that one alone and deny the rest.
4. 2FA, if you accept a standing device token in `/etc/pve/priv/storage/<id>.syno`.
5. An IP restriction in Control Panel → Security → Firewall, pinned to the nodes.

That is as far as it can be reduced on this DSM version, and it is worth doing —
the point of the finding is that steps 1 to 5 are available even though a
non-administrator is not.

Until then, treat the account as privileged: dedicated to this plugin, no shared
folders, no other applications, 2FA if you accept a standing device token, and
pinned by IP in the firewall.

## Where the credentials are stored

`/etc/pve/priv/storage/<storage>.syno`, mode `0600`, in a directory the cluster
filesystem serves to **root only**. It holds the DSM password, the CHAP secret
and the 2FA device token. Being under `/etc/pve` it replicates to every node,
which a shared storage needs.

They are declared to Proxmox VE as `sensitive-properties`, which is what makes
PVE strip them out of the configuration before it is written and hand them to
the plugin instead. The same mechanism PVE's own CIFS, PBS and ESXi plugins use.


## Networking

Two settings are worth more than any account tuning:

1. **Firewall** — Control Panel → Security → Firewall. Allow the DSM port
   (5001) only from your PVE nodes' addresses. The plugin's whole conversation
   with the NAS is from those hosts, so anything else reaching that port is
   not this plugin.
2. **Separate the data path** — iSCSI traffic (3260) belongs on its own
   network or VLAN, and the DSM management port does not have to be reachable
   from it.

DSM ties a session to the client's IP address by default
(`skip_ip_checking: false` on the test NAS), so a session cannot be replayed
from elsewhere and each node necessarily has its own.

Note also: **the DSM session timeout is 15 minutes** by default. The plugin
re-logs in when a session expires, which is a normal event and not an error.

---

## HTTPS

DSM ships a self-signed certificate, so certificate verification is **off by
default** in this plugin (`syno-ssl-verify 0`). A default of "on" would mean
almost no fresh DSM could be added at all, and a default nobody can use
protects nobody.

If you have a certificate the node can verify — Let's Encrypt via DSM, or your
own CA — turn it on:

```bash
pvesm set <storage> --syno-ssl-verify 1 --syno-tls-ca /etc/ssl/certs/your-ca.pem
```

Plain HTTP is refused. DSM will accept the login as a GET with the password in
the query string — Synology's own CSI driver logs in that way — and this
plugin does not: that writes the password into the NAS's own access log and
into every proxy in between.
