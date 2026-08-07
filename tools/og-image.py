#!/usr/bin/env python3
"""Generate docs/og-image.png, the card a link to the documentation site shows.

Run it with `make og-image`. The VERSION is baked into the badge, so the file
goes stale on every release — `release-check` fails when it is older than
debian/changelog rather than leaving that to whoever remembers.

The accent is #0086E5, which is DSM's own `mask-icon` colour, read off a real
NAS rather than picked. The layout follows the sibling projects' cards so the
four read as one family.
"""
import sys
from PIL import Image, ImageDraw, ImageFont

VERSION = sys.argv[1] if len(sys.argv) > 1 else "dev"
BADGE = f"v{VERSION}  |  MIT License  |  Open Source"

W, H   = 1200, 630
BG     = (16, 20, 28)
ACCENT = (0, 134, 229)          # DSM's own mask-icon colour, read off the NAS
WHITE  = (255, 255, 255)
DESC   = (201, 213, 226)
MUTED  = (148, 163, 184)
RULE   = (42, 52, 68)

F = "/usr/share/fonts/truetype/dejavu/"
mono_b = lambda s: ImageFont.truetype(F + "DejaVuSansMono-Bold.ttf", s)
sans_b = lambda s: ImageFont.truetype(F + "DejaVuSans-Bold.ttf", s)
sans   = lambda s: ImageFont.truetype(F + "DejaVuSans.ttf", s)

im = Image.new("RGB", (W, H), BG)

# Two soft discs, drawn oversampled then blended so they read as a glow rather
# than as flat shapes.
glow = Image.new("RGB", (W * 2, H * 2), BG)
gd = ImageDraw.Draw(glow)
gd.ellipse([W * 2 - 620, -420, W * 2 + 380, 580], fill=(22, 44, 74))
gd.ellipse([-360, H * 2 - 420, 440, H * 2 + 380], fill=(20, 38, 64))
im = Image.blend(im, glow.resize((W, H), Image.LANCZOS), 0.85)

d = ImageDraw.Draw(im)
d.rectangle([0, 0, W, 6], fill=ACCENT)          # the family's top accent bar

X = 72

def pill(x, y, text, font, fill, fg=WHITE, padx=15, pady=9, r=None):
    w = d.textlength(text, font=font)
    a = font.getbbox("Ay"); h = a[3] - a[1]
    box = [x, y, x + w + padx * 2, y + h + pady * 2]
    d.rounded_rectangle(box, radius=(r if r is not None else (box[3] - box[1]) // 2), fill=fill)
    d.text((x + padx, y + pady - a[1]), text, font=font, fill=fg)
    return box[2], box[3]

# Badge
_, by = pill(X, 74, BADGE, mono_b(21), ACCENT)

# Title
d.text((X, by + 24), "jt-pve-storage-synology", font=mono_b(58), fill=WHITE)

# Subtitle
d.text((X, by + 116), "Synology SAN Manager iSCSI Plugin for Proxmox VE",
       font=sans_b(29), fill=WHITE)

# Description
for i, line in enumerate([
    "One VM disk is one Btrfs thin LUN on the NAS, so DSM's own snapshots,",
    "clones and capacity act on the unit an operator thinks about — no LVM",
    "layer, and no shared LUN carved up locally.",
]):
    d.text((X, by + 172 + i * 33), line, font=sans(21), fill=DESC)

# Feature pills
x, y = X, by + 292
for t in ["iSCSI", "Multipath", "Btrfs Thin LUN", "Snapshots", "Rollback",
          "Reflink Clone", "Live Migration"]:
    nx, _ = pill(x, y, t, sans_b(17), ACCENT, padx=13, pady=8)
    x = nx + 10

# Footer
d.line([X, H - 78, W - X, H - 78], fill=RULE, width=1)
d.text((X, H - 56), "github.com/jasoncheng7115/jt-pve-storage-synology",
       font=sans(19), fill=MUTED)
right = "Jason Cheng (Jason Tools)"
d.text((W - X - d.textlength(right, font=sans(19)), H - 56), right,
       font=sans(19), fill=MUTED)

im.save("docs/og-image.png", optimize=True)
print("docs/og-image.png", im.size)
