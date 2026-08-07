PACKAGE = jt-pve-storage-synology

# Versioning: the patch number increments per release and runs to .99 before
# the minor number moves — 0.1.0, 0.1.1, ... 0.1.99, then 0.2.0. Keep this in
# step with debian/changelog; release-check refuses when they disagree.
VERSION = 0.6.15

DESTDIR =
PREFIX   = /usr
PERL5DIR = $(DESTDIR)$(PREFIX)/share/perl5
BINDIR   = $(DESTDIR)$(PREFIX)/bin

# Discovered rather than hard-coded: a hand-maintained module list would drift
# out of sync with debian/ and the syntax-check target.
PERL_MODULES = $(shell find lib -type f -name '*.pm' 2>/dev/null | sort)
BIN_SCRIPTS  = $(shell find bin -type f ! -name '.gitkeep' 2>/dev/null | sort)
UNIT_TESTS   = $(wildcard t/*.t)

# Paths scanned by the capital-F flush guard.
GUARD_PATHS = lib bin debian docs t .github Makefile \
              README.md README_zh-TW.md CHANGELOG.md CHANGELOG_zh-TW.md

.PHONY: all install uninstall test syntax unit unit-nopve nopve-stub \
        check-multipath-flush check-secrets check-tool-paths check-zh zh-normalise critic check-doc-urls \
        check-release-archive \
        release-check deb deb-clean clean

all:
	@echo "Nothing to build. Run 'make install', 'make test' or 'make deb'."

install:
	@set -e; for f in $(PERL_MODULES); do \
		rel=$${f#lib/}; \
		install -d $(PERL5DIR)/$$(dirname $$rel); \
		install -m 0644 $$f $(PERL5DIR)/$$rel; \
		echo "  installed $(PERL5DIR)/$$rel"; \
	done
	@set -e; for f in $(BIN_SCRIPTS); do \
		install -d $(BINDIR); \
		install -m 0755 $$f $(BINDIR)/; \
		echo "  installed $(BINDIR)/$$(basename $$f)"; \
	done

uninstall:
	rm -f  $(PERL5DIR)/PVE/Storage/Custom/SynologySANPlugin.pm
	rm -rf $(PERL5DIR)/PVE/Storage/Custom/Synology/
	@for f in $(BIN_SCRIPTS); do rm -f $(BINDIR)/$$(basename $$f); done

test: syntax unit check-multipath-flush check-secrets check-zh
	@echo "All checks passed."

# Modules that subclass PVE::Storage::Plugin cannot be compiled without a
# Proxmox VE installation. On a build host or CI runner that is expected, and
# reporting it as a failure would train everyone to ignore this target — so
# only that specific cause is tolerated, and it is named in the output.
syntax:
	@echo "Running Perl syntax checks..."
	@if [ -z "$(strip $(PERL_MODULES))$(strip $(BIN_SCRIPTS))" ]; then \
		echo "  (no Perl sources yet — skeleton stage)"; \
	fi
	@set -e; skipped=0; for f in $(PERL_MODULES) $(BIN_SCRIPTS); do \
		out=$$(perl -Ilib -c $$f 2>&1) || { \
			if echo "$$out" | grep -qE "Can't locate PVE/|Base class package \"PVE::"; then \
				echo "  skipped $$f (needs Proxmox VE)"; \
				skipped=1; \
				continue; \
			fi; \
			missing=$$(echo "$$out" | sed -n "s/.*Can't locate \([A-Za-z0-9_\/]*\)\.pm.*/\1/p" | head -1); \
			if [ -n "$$missing" ]; then \
				echo "$$out"; \
				echo ""; \
				echo "  $$(echo $$missing | sed 's|/|::|g') is a RUNTIME DEPENDENCY of this"; \
				echo "  plugin, not an optional extra. On Debian:"; \
				echo "    apt install libwww-perl libjson-perl liburi-perl"; \
				exit 1; \
			fi; \
			echo "$$out"; \
			exit 1; \
		}; \
		echo "  checking $$f ... OK"; \
	done; \
	if [ "$$skipped" = "1" ]; then \
		echo "  NOTE: some modules were skipped. Run 'make syntax' on a"; \
		echo "        Proxmox VE node to check them."; \
	fi

# `.perlcriticrc` records, with a reason for each, the policies this project
# deliberately violates — `return undef` is required by the three-valued safety
# contract, and the `_not_a_method` guard must read @_ before unpacking it. Read
# that file before switching anything else off.
# Every released version's .deb must still be fetchable from this tree.
#
# This did not exist for the first fifteen releases and nothing noticed: the
# `.gitignore` carried a `!releases/*.deb` negation waiting for a directory that
# had never been created, so the rule read as satisfied while the archive was
# empty. A tester on 0.3.1 could not have obtained 0.3.1. The archive was
# reconstructed from GitHub and verified against each release's own published
# checksum; this target is what stops it lapsing again.
check-release-archive:
	@echo "Checking the release archive..."
	@missing=0; \
	for tag in $$(git tag -l 'v*' 2>/dev/null); do \
		v=$$(echo "$$tag" | sed 's/^v//; s/-beta/.beta/'); \
		if ! ls releases/*_$$v-*_all.deb >/dev/null 2>&1; then \
			echo "  MISSING: $$tag has no .deb in releases/"; missing=1; \
		fi; \
	done; \
	if [ "$$missing" = "1" ]; then \
		echo ""; \
		echo "A tester on that version cannot fetch what they are running."; \
		echo "Download it from its GitHub release into releases/ and commit it."; \
		exit 1; \
	fi; \
	echo "  OK: every tag has its .deb ($$(ls releases/*.deb 2>/dev/null | wc -l) archived)."

critic:
	@if command -v perlcritic >/dev/null 2>&1; then \
		perlcritic --profile .perlcriticrc lib/ bin/ \
			&& echo "  OK: perlcritic severity 4 is clean."; \
	else \
		echo "  perlcritic is not installed (apt install libperl-critic-perl)"; \
	fi

unit:
	@if [ -n "$(strip $(UNIT_TESTS))" ]; then \
		echo "Running unit tests..."; \
		prove -Ilib $(UNIT_TESTS); \
	else \
		echo "No unit tests yet (t/*.t)."; \
	fi

# The same suite as it runs on a machine with no Proxmox VE, which is what CI
# is. In the dellemc project a suite that was green locally and red in CI
# published nothing for twenty releases, and nobody noticed.
NOPVE_STUB = $(CURDIR)/.nopve-stub

# The die must NOT end in a newline: base.pm treats a require failure as
# "module not installed" only when the message carries perl's own
# " at (eval N)" suffix, which is the message a real runner produces and the
# one `syntax` has to tolerate.
define NOPVE_STUB_SRC
package nopve;
BEGIN {
    unshift @INC, sub {
        my (undef, $$f) = @_;
        return unless $$f =~ m{^PVE/} && $$f !~ m{^PVE/Storage/Custom/};
        (my $$mod = $$f) =~ s{/}{::}g; $$mod =~ s/\.pm$$//;
        die "Can't locate $$f in \@INC (you may need to install the $$mod module)";
    };
}
1;
endef
export NOPVE_STUB_SRC

nopve-stub:
	@mkdir -p $(NOPVE_STUB)
	@printf '%s\n' "$$NOPVE_STUB_SRC" > $(NOPVE_STUB)/nopve.pm

unit-nopve: nopve-stub
	@echo "Running checks as they run without Proxmox VE (as in CI)..."
	@PERL5OPT="-I$(NOPVE_STUB) -Mnopve" $(MAKE) --no-print-directory syntax
	@if [ -n "$(strip $(UNIT_TESTS))" ]; then \
		PERL5OPT="-I$(NOPVE_STUB) -Mnopve" prove -Ilib $(UNIT_TESTS); \
	fi
	@rm -rf $(NOPVE_STUB)

# `multipath -F` (capital F) must NEVER be used: it flushes EVERY unused
# multipath map on the node, including maps belonging to other storages and
# other vendors. Only ever flush one named map with lowercase
# `multipath -f /dev/mapper/<wwid>`. Prose that forbids the command is allowed
# through: such a line must carry never (any case) / 不得 / 不要 / 不會 /
# 絕不 / 禁止.
check-multipath-flush:
	@echo "Checking for forbidden system-wide multipath operations..."
	@hits=$$(grep -rnE "multipath[[:space:]]+(-[A-Za-z]*F|--flush)|(multipathd|MULTIPATHD)['\", ]*(remove|del)['\", ]+(maps|multipaths)" \
		$(GUARD_PATHS) --exclude-dir=.git --binary-files=without-match 2>/dev/null \
		| grep -viE 'never|不得|不要|不會|絕不|禁止' || true); \
	if [ -n "$$hits" ]; then \
		echo "ERROR: forbidden node-wide multipath operation found:"; \
		echo "$$hits" | sed 's/^/  /'; \
		echo ""; \
		echo "These remove EVERY unused map on the node, including other"; \
		echo "vendors' storage. Act on one named map instead:"; \
		echo "  multipath -f /dev/mapper/<wwid>"; \
		exit 1; \
	fi; \
	echo "  OK: no node-wide multipath flush found."

# DSM accepts the login as a GET with the password in the query string, and
# Synology's own CSI driver logs in that way. Doing so writes the credential
# into the NAS's access log and into every proxy in between, so this project
# never builds a URL that carries one — not in code, not in an example, not
# in a log line. A line that forbids it must say so (never / 不得 / 不要).
check-secrets:
	@echo "Checking for credentials in URLs..."
	@hits=$$(grep -rnE "(passwd|password|otp_code)=[^&\"' ]*['\"&]?" \
		$(GUARD_PATHS) --exclude-dir=.git --binary-files=without-match 2>/dev/null \
		| grep -E "https?://|query|GET|url" \
		| grep -viE 'never|不得|不要|不會|絕不|禁止' || true); \
	if [ -n "$$hits" ]; then \
		echo "ERROR: a credential may be travelling in a URL:"; \
		echo "$$hits" | sed 's/^/  /'; \
		exit 1; \
	fi; \
	echo "  OK: no credential found in a URL."

# Three ways a Traditional Chinese document renders wrongly while looking
# correct in the editor: a wrapped paragraph becomes a visible space on GitHub,
# `*text*` is English italics, and a space after full-width punctuation is an
# un-wrapping artefact. All three were found by Jason looking at a rendered
# page, so they are checked rather than remembered.
# Every download URL the documentation tells an operator to run must actually
# resolve.
#
# A `wget .../releases/latest/download/jt-pve-storage-synology_all.deb` shipped on
# the documentation site and answered **404** on the first node someone tried it
# on. Two reasons: the asset name carried the version, and there was no latest
# release at all, because every 0.x was tagged as a prerelease and GitHub's
# `latest` deliberately skips those.
#
# **Both were fixed rather than worked around**, in 0.6.5: the `beta1` suffix is
# gone so releases are normal ones, and the workflow publishes the package a second
# time under a version-free name. So that URL is now the documented one — and this
# target verifies it actually resolves, because the two things it depends on live in
# the release workflow and could silently stop being true.
#
# Writing a command into documentation without running it is the same fault as
# believing an array's success reply, and this project has a rule about that.
#
# A URL for the version being released is reported as `pending` rather than failing:
# release-check runs BEFORE the tag is pushed, so that asset cannot exist yet. Every
# other URL must return 200. Skipping only the one version this run is preparing
# keeps the guard strict — an install URL left pointing at an older release still
# fails, and so does one pointing at a version that was never published.
#
# It matches only a `wget` or `curl` USING that path, not any mention of it. The
# first version matched the string anywhere and condemned the paragraph that
# explains why not to use it — the sixth time in this project that a guard could
# not tell a thing from prose about the thing. Strip, scope, or anchor: never just
# grep the word.
check-doc-urls:
	@echo "Checking the documentation's download URLs..."
	@bad=0; \
	if grep -rn 'dpkg -i jt-pve-storage-synology' docs/ README*.md 2>/dev/null; then \
		echo "  ERROR: dpkg -i does not resolve dependencies. On a node without"; \
		echo "         multipath-tools it unpacks and then leaves the package"; \
		echo "         unconfigured. Document 'apt install ./<file>.deb'."; \
		bad=1; \
	fi; \
	for u in $$(grep -rhoE 'https://github\.com/[^" )]*/releases/latest/download/[^" )]*' docs/ README*.md 2>/dev/null | sort -u); do \
		code=$$(curl -sL -o /dev/null -w '%{http_code}' --max-time 25 "$$u"); \
		if [ "$$code" != "200" ]; then \
			echo "  ERROR: $$code for $$u"; \
			echo "         the release workflow must publish a version-free copy"; \
			echo "         of the .deb, and the newest release must not be a prerelease"; \
			bad=1; \
		else echo "  ok $$code  $$u"; fi; \
	done; \
	pending=v$$(echo "$(VERSION)" | tr '~' '-'); \
	for u in $$(grep -rhoE 'https://github\.com/[^" )]*/releases/download/[^" )]*' docs/ README*.md 2>/dev/null | sort -u); do \
		case "$$u" in \
			*/releases/download/$$pending/*) \
				echo "  pending  $$u"; \
				echo "           (this release is not published yet — release-check runs first)"; \
				continue;; \
		esac; \
		code=$$(curl -sL -o /dev/null -w '%{http_code}' --max-time 20 "$$u"); \
		if [ "$$code" != "200" ]; then echo "  ERROR: $$code for $$u"; bad=1; \
		else echo "  ok $$code  $$u"; fi; \
	done; \
	if [ "$$bad" = "1" ]; then exit 1; fi; \
	echo "  OK: every documented download URL resolves."

# The fixer for what check-zh checks. Kept as a target so nobody re-invents the
# ad hoc version, which manufactured 116 broken bold runs by stripping the space in
# 「。** 只有」 — see the header of tools/zh-normalise.pl.
zh-normalise:
	@perl tools/zh-normalise.pl $$(ls *_zh-TW.md docs/*_zh-TW.md 2>/dev/null)
	@perl tools/check-zh-markdown.pl

# Every external command must reach the tool resolver, never $ENV{PATH}.
#
# A PVE daemon has NO PATH at all — measured on pvestatd, pvedaemon, pveproxy
# and pve-ha-lrm — so exec falls back to /bin:/usr/bin and every tool this
# plugin uses lives in /usr/sbin. A command spawned any other way than through
# run_cmd() bypasses Command::tool_path and fails only when someone drives the
# operation from the web interface instead of a shell.
check-tool-paths:
	@echo "Checking that no command bypasses the tool resolver..."
	@bad=0; \
	for f in $(PERL_MODULES) $(BIN_SCRIPTS); do \
		hits=$$(perl -ne 'next if /^\s*#/; print "$$.: $$_" if /\b(?:system|exec|open3|readpipe)\s*\(/ || /qx\{/' "$$f"); \
		case "$$f" in *"/Synology/Command.pm") continue;; esac; \
		if [ -n "$$hits" ]; then \
			echo "  ERROR: $$f spawns a process outside the command runner:"; \
			echo "$$hits" | sed 's/^/      /'; \
			bad=1; \
		fi; \
	done; \
	if [ "$$bad" = "1" ]; then \
		echo "         Route it through Command::run_cmd, which resolves an"; \
		echo "         absolute path. A PVE daemon has no PATH."; \
		exit 1; \
	fi; \
	echo "  OK: every external command goes through the resolver."

check-zh:
	@echo "Checking the Traditional Chinese documents..."
	@perl tools/check-zh-markdown.pl
	@perl tools/check-zh-markdown.pl >/dev/null 2>&1 || { \
		echo "  (run 'make zh-normalise' — it fixes what it can)"; exit 1; }

release-check: check-multipath-flush check-secrets check-tool-paths check-zh syntax unit unit-nopve critic \
               check-doc-urls \
               check-release-archive
	@echo "Checking version consistency..."
	@deb_version=$$(dpkg-parsechangelog --show-field Version 2>/dev/null \
		| sed 's/-[0-9]*$$//'); \
	tool_version=$$(sed -n "s/^my \$$VERSION = '\(.*\)';/\1/p" \
		bin/pve-syno-api-probe); \
	fail=0; \
	echo "  Makefile:         $(VERSION)"; \
	echo "  debian/changelog: $$deb_version"; \
	echo "  probe tool:       $$tool_version"; \
	if [ -n "$$deb_version" ] && [ "$(VERSION)" != "$$deb_version" ]; then \
		echo "  ERROR: Makefile and debian/changelog disagree"; fail=1; \
	fi; \
	if [ "$(VERSION)" != "$$tool_version" ]; then \
		echo "  ERROR: Makefile and bin/pve-syno-api-probe disagree"; fail=1; \
	fi; \
	for f in CHANGELOG.md CHANGELOG_zh-TW.md; do \
		if ! grep -q "\[$(VERSION)\]" $$f; then \
			echo "  ERROR: $$f has no entry for $(VERSION)"; fail=1; \
		fi; \
	done; \
	badge=$$(sed -n 's/.*hero__badge">[[:space:]]*v\([^ <]*\).*/\1/p' docs/index.html | head -1); \
	echo "  docs site badge:  $$badge"; \
	if [ "$$badge" != "$(VERSION)" ]; then \
		echo "  ERROR: the Pages site badge says '$$badge'"; fail=1; \
	fi; \
	dl_tag=v$$(echo "$(VERSION)" | tr '~' '-'); \
	dl_asset=jt-pve-storage-synology_$$(echo "$(VERSION)" | tr '~' '.')-1_all.deb; \
	for f in docs/index.html README.md README_zh-TW.md; do \
		for u in $$(grep -ohE 'releases/download/[^ "<)]+' $$f 2>/dev/null | grep -v '^releases/download/latest' | sort -u); do \
			if [ "$$u" != "releases/download/$$dl_tag/$$dl_asset" ]; then \
				echo "  ERROR: $$f documents $$u"; \
				echo "         expected releases/download/$$dl_tag/$$dl_asset"; fail=1; \
			fi; \
		done; \
	done; \
	echo "  install URL:      releases/download/$$dl_tag/$$dl_asset"; \
	if [ "$$fail" = "1" ]; then \
		echo ""; \
		echo "A release whose files disagree about its own version is worse"; \
		echo "than no release. Fix the above, then run this again."; \
		exit 1; \
	fi; \
	echo "  OK: every file agrees on $(VERSION), including the docs site"

deb:
	dpkg-buildpackage -us -uc -b

clean:
	rm -rf debian/$(PACKAGE)/
	rm -rf debian/.debhelper/
	rm -f  debian/debhelper-build-stamp
	rm -f  debian/files
	rm -f  debian/*.substvars
	rm -f  debian/*.log
	rm -rf .nopve-stub

deb-clean: clean
	rm -f ../$(PACKAGE)_*.deb
	rm -f ../$(PACKAGE)_*.changes
	rm -f ../$(PACKAGE)_*.buildinfo
