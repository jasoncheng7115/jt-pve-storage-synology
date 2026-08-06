# Release archive

Every release's `.deb`, kept forever. A tester running an earlier version must be
able to fetch **exactly** what they are running — a bug report against 0.3.1 is
worth nothing if 0.3.1 can no longer be obtained.

`SHA256SUMS` covers every file here and is regenerated when one is added.

## Nothing here was built locally

Each file was downloaded from its own GitHub release and verified against the
`SHA256SUMS` that release published, so the archive holds the bytes testers
actually received rather than a rebuild that merely ought to match.

## The `~` in the filenames

Debian versions use `~` for a prerelease (`0.5.2~beta1`), which sorts *before*
`0.5.2` — that is the whole point of it. **GitHub rewrites `~` to `.` in a
release asset's filename**, so the asset is `..._0.5.2.beta1-1_all.deb` while the
package inside still declares `0.5.2~beta1-1`, and the two earliest releases'
`SHA256SUMS` name the file with the `~` it no longer has. The filenames here match
the assets; `dpkg-deb --field <file> Version` is the authority on what a file
actually is.
