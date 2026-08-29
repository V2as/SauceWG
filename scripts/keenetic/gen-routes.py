#!/usr/bin/env python3
"""Generates Keenetic static routes that send Claude, Gemini and Instagram down a tunnel.

Run it to refresh the .bat files next to this script:

    ./scripts/keenetic/gen-routes.py

They are written in the Windows `route add` syntax that the router's
"Static routes -> Import" dialog expects, with a 0.0.0.0 gateway so the tunnel interface
is picked in that dialog rather than baked into the file. See write_keenetic for the
details the importer is fussy about.

Why the lists look the way they do
----------------------------------
Cursor does not talk to Anthropic or Google from your machine. Model requests go to
Cursor's own backend and it calls the providers server-side, so routing api.anthropic.com
does nothing for the Claude you use inside the editor. Three destinations therefore have
to be handled separately, and the generated files keep them apart:

  cursor    Cursor's backend. This is what makes Claude *and* Gemini work in the editor.
  claude    Anthropic direct: claude.ai, Claude Code, or Cursor with your own API key.
  gemini    Google direct: AI Studio, gemini.google.com, or your own Gemini API key.

Instagram and Clash Royale are unrelated to any of that and get their own files. See
META_ASNS for why Instagram is built from BGP rather than DNS, and CLASH_HOSTS for the
two halves the game is split across.

Cursor's api2.cursor.sh answers from a rotating pool of EC2 addresses in us-east-1 — three
rounds of DNS across three resolvers already turn up ~60 distinct ones — so host routes are
useless here. The pool is mapped onto the AWS-published prefixes that contain it instead,
which is stable across rotation. Everything else comes from a provider's own published
ranges rather than from DNS, for the same reason.

Anthropic is the easy case: they own one ARIN allocation, 160.79.104.0/21, and serve
everything from it. That single route is the whole Claude story.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent

AWS_URL = "https://ip-ranges.amazonaws.com/ip-ranges.json"
CLOUDFLARE_URL = "https://www.cloudflare.com/ips-v4"
RIPE_URL = "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS{asn}"
RIPE_NETWORK_URL = "https://stat.ripe.net/data/network-info/data.json?resource={ip}"

# Meta publishes no IP list, so the routes come from what their networks announce to BGP.
# All three matter for Instagram, and the second one is the reason Reels play at all:
#
#   32934  FACEBOOK          the main network, where instagram.com and graph.* answer
#   63293  FACEBOOK-OFFNET   the CDN that serves video from *.fbcdn.net
#   54115  FACEBOOK-CORP     a small block that some API and upload hosts sit in
#
# Meta announces IPv6 too, but instagram.com and video.xx.fbcdn.net have no AAAA records,
# so v4 routes are the whole picture and the router has nothing to leak around them.
META_ASNS = (32934, 63293, 54115)

# Supercell's own network. Beware of AS207811 and AS209193, which are unrelated ISPs that
# happen to be called SuperCell too; routing those would send a stranger's customers down
# the tunnel. AS212916 is the one registered to Supercell Oy, the Helsinki game studio.
SUPERCELL_ASN = (212916,)

# Clash Royale is scattered far wider than the game server suggests. The match server is
# EC2 in us-west-2, the site and assets are on CloudFront and Akamai, and Supercell ID -
# which the game will not get past the loading screen without - answers from eu-central-1,
# us-east-1 and Asia depending on which security-*.id host the client is sent to. Routing
# us-west-2 alone gets you a game that loads and then refuses to log in.
CLASH_HOSTS = [
    "game.clashroyaleapp.com", "game-assets.clashroyaleapp.com",
    "clashroyale.com", "www.clashroyale.com", "api.clashroyale.com",
    "link.clashroyale.com", "play.clashroyale.com", "support.clashroyale.com",
    "partner-api.clashroyale.com", "deck-wizard.clashroyale.com",
    "event-assets.clashroyale.com", "event-assets-2.clashroyale.com",
    "event-assets-v2.clashroyale.com", "game-assets-2.clashroyale.com",
    "esports.clashroyale.com",
    "supercell.com", "www.supercell.com", "api.supercell.com", "cdn.supercell.com",
    "id.supercell.com", "api-alb.id.supercell.com", "hermes.id.supercell.com",
    "security-eu.id.supercell.com", "security-us.id.supercell.com",
    "security-apac.id.supercell.com", "security-global.id.supercell.com",
    "login.supercell.com", "inbox.supercell.com", "payment-api.supercell.com",
    "chronos.supercell.com", "spell-factory.api.supercell.com",
    "supercell.helpshift.com",
]

# What each file's domain list carries. Keenetic's DNS-based routes match subdomains on
# their own, so a parent name covers every host under it and the lists stay this short.
DOMAIN_LISTS = {
    "clashroyale": ["clashroyale.com", "clashroyaleapp.com", "supercell.com",
                    "supercellid.com", "supercell.net", "helpshift.com"],
    "cursor": ["cursor.com", "cursor.sh", "cursorapi.com", "todesktop.com"],
    "claude": ["anthropic.com", "claude.ai"],
    "gemini": ["generativelanguage.googleapis.com", "aistudio.google.com",
               "gemini.google.com", "ai.google.dev"],
    "instagram": ["instagram.com", "cdninstagram.com", "fbcdn.net", "facebook.com",
                  "fb.com"],
}

# Anthropic's full ARIN allocation. AS399358 only announces the /23 today, but the /21 is
# theirs and costs three extra bits, so it survives them growing into it.
ANTHROPIC = ["160.79.104.0/21"]

# Vercel's edge, which serves cursor.com and the login/checkout pages.
VERCEL = ["76.76.21.0/24", "66.33.60.0/24"]

# The Cursor names worth resolving. api2 is the one that carries model traffic; the rest
# are sign-in, extensions, indexing and updates, which all break the editor if they hang.
CURSOR_HOSTS = [
    "api2.cursor.sh", "api2geo.cursor.sh", "api2direct.cursor.sh",
    "api3.cursor.sh", "api4.cursor.sh", "api.cursor.com",
    "repo42.cursor.sh", "cursor.com", "www.cursor.com",
    "marketplace.cursorapi.com", "us-only.gcpp.cursor.sh",
    "download.todesktop.com",
]

# Resolvers to ask. Each one hands back a different slice of the EC2 pool, and asking
# several of them repeatedly is what makes the AWS prefix mapping below converge.
RESOLVERS = ["1.1.1.1", "8.8.8.8"]
ROUNDS = 3

# Google's frontend ranges, which is where generativelanguage.googleapis.com,
# aistudio.google.com and gemini.google.com all answer from. Google publishes
# gstatic.com/ipranges/goog.json (everything) and cloud.json (the GCP customer subset),
# but subtracting one from the other yields 262 fragments for the same coverage, so the
# netblocks are listed whole instead: far fewer routes for a router to hold.
#
# Google Public DNS (8.8.8.0/24, 8.8.4.0/24) is deliberately absent. It is in goog.json,
# but nothing Gemini answers from it, and tunnelling the resolver you use to find the
# tunnel's own endpoint is a good way to make an outage unrecoverable.
GOOGLE_FRONTEND = [
    "64.233.160.0/19", "66.102.0.0/20", "66.249.64.0/19", "72.14.192.0/18",
    "74.125.0.0/16", "108.177.0.0/17", "142.250.0.0/15", "172.217.0.0/16",
    "172.253.0.0/16", "173.194.0.0/16", "192.178.0.0/15", "209.85.128.0/17",
    "216.58.192.0/19", "216.239.32.0/19",
]


def fetch(url: str, attempts: int = 4) -> bytes:
    # cloudflare.com/ips-v4 answers 403 to urllib's default User-Agent.
    request = urllib.request.Request(url, headers={"User-Agent": "curl/8"})
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.read()
        except (urllib.error.URLError, ConnectionError, TimeoutError) as error:
            # ip-ranges.amazonaws.com is a 10 MB download that does reset mid-stream, and
            # losing it means losing the DNS sampling that ran before it.
            if attempt == attempts - 1:
                raise
            print(f"  {url} failed ({error}), retrying", file=sys.stderr)
            time.sleep(2 ** attempt)
    raise AssertionError("unreachable")


def ripe_prefixes(asns) -> list[str]:
    """Every IPv4 prefix the given networks announce, according to RIPEstat.

    Asking BGP rather than DNS is what makes the Instagram list complete: Meta answers
    from whichever of their POPs is nearest, so no amount of resolving from one country
    sees more than a corner of it. The 342 raw prefixes collapse to 77.
    """
    found: list[str] = []
    for asn in asns:
        data = json.loads(fetch(RIPE_URL.format(asn=asn)))
        found += [p["prefix"] for p in data["data"]["prefixes"] if ":" not in p["prefix"]]
    return found


def bgp_prefixes(ips) -> list[str]:
    """The prefix each address is announced in, whoever happens to own it.

    Supercell rents from more than one provider, so a published list only ever explains
    part of what the game resolves to: the asset hosts land on Akamai and the site on
    Cloudflare. Asking the routing table what a leftover address belongs to covers those
    without hardcoding a CDN that Supercell may stop using next month.
    """
    found: set[str] = set()
    for ip in sorted(ips):
        data = json.loads(fetch(RIPE_NETWORK_URL.format(ip=ip)))
        prefix = data["data"].get("prefix")
        if prefix and ":" not in prefix:
            found.add(prefix)
    return sorted(found)


def resolve(hosts: list[str]) -> set[str]:
    """Every A record the resolvers will admit to, across a few rounds."""
    found: set[str] = set()
    for _ in range(ROUNDS):
        for resolver in RESOLVERS:
            for host in hosts:
                try:
                    out = subprocess.run(
                        ["dig", "+short", "+time=2", "+tries=1", "A", host, f"@{resolver}"],
                        capture_output=True, text=True, timeout=10,
                    ).stdout
                except (subprocess.TimeoutExpired, FileNotFoundError):
                    continue
                for line in out.split():
                    try:
                        found.add(str(ipaddress.IPv4Address(line.strip())))
                    except ValueError:
                        pass  # CNAMEs come back on their own lines
    return found


def collapse(prefixes) -> list[ipaddress.IPv4Network]:
    nets = [ipaddress.ip_network(p) for p in prefixes]
    return sorted(ipaddress.collapse_addresses(nets), key=lambda n: (int(n.network_address), n.prefixlen))


def remember(seen: dict[str, list[str]]) -> dict[str, list[str]]:
    """Folds this run's findings into observed-prefixes.json and returns the union.

    A single run only sees the slice of the pool the resolvers felt like handing over:
    consecutive runs turned up 74 addresses in 34 prefixes and then 60 in 26. Taking one
    run at face value would drop routes that worked yesterday and leave Cursor failing
    intermittently, so observations accumulate on disk and only ever grow.
    """
    store = HERE / "observed-prefixes.json"
    known = json.loads(store.read_text()) if store.exists() else {}
    # Start from everything on disk, not just the keys passed in: this runs once per
    # service, and rebuilding the dict from `seen` alone would drop the other services'
    # history on every call.
    merged = dict(known)
    for key, prefixes in seen.items():
        merged[key] = sorted(set(known.get(key, [])) | set(prefixes))
    store.write_text(json.dumps(merged, indent=2) + "\n")
    return merged


def prefixes_covering(candidates: list[str], ips: set[str]) -> list[str]:
    """The published prefixes that the observed addresses actually fall into.

    Both AWS and Cloudflare hand out addresses from a pool, so host routes rot within
    hours, but the prefix behind the pool does not. Keeping only the prefixes that were
    seen is what holds the route count down: all of us-east-1 EC2 is 230-odd routes and
    all of Cloudflare is the fifth of the web sitting behind it, where the ones Cursor
    answers from are about 30 and 3.
    """
    nets = [ipaddress.ip_network(p) for p in candidates]
    hit: set[str] = set()
    for ip in ips:
        addr = ipaddress.ip_address(ip)
        for net in nets:
            if addr in net:
                hit.add(str(net))
    return sorted(hit)


def write_keenetic(path: Path, blocks: list[tuple[str, list]], labels: bool) -> None:
    """Writes a file the router's route importer will actually take.

    Keenetic's "Static routes -> Import" reads the Windows `route add` syntax and nothing
    else: one route per line, no header, no comments of their own, CRLF. A gateway of
    0.0.0.0 leaves the interface to the dropdown in the import dialog, which is why these
    files carry no interface name. The optional `:: rem` suffix lands in the Description
    column, and is the only way to tell 65 near-identical rows apart afterwards.
    """
    lines = []
    for label, nets in blocks:
        for net in nets:
            line = f"route ADD {net.network_address} MASK {net.netmask} 0.0.0.0"
            lines.append(f"{line} :: rem {label}" if labels else line)
    path.write_text("\r\n".join(lines) + "\r\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-labels", action="store_true",
                        help="omit the ':: rem' descriptions, for a firmware that chokes on them")
    args = parser.parse_args()

    print("Downloading provider ranges...", file=sys.stderr)
    aws = json.loads(fetch(AWS_URL))
    cloudflare = fetch(CLOUDFLARE_URL).decode().split()

    print("Resolving Cursor hosts...", file=sys.stderr)
    cursor_ips = resolve(CURSOR_HOSTS)
    print(f"  {len(cursor_ips)} distinct addresses", file=sys.stderr)

    aws_candidates = [p["ip_prefix"] for p in aws["prefixes"]
                      if p["service"] in ("EC2", "GLOBALACCELERATOR")]
    union = remember({
        "aws": prefixes_covering(aws_candidates, cursor_ips),
        "cloudflare": prefixes_covering(cloudflare, cursor_ips),
    })
    print(f"  {len(union['aws'])} AWS and {len(union['cloudflare'])} Cloudflare prefixes"
          " (this run plus everything seen before)", file=sys.stderr)

    # The belt-and-braces variant: every prefix of the two regions Cursor answers from,
    # for when an occasional miss matters more than the route count does.
    regions = ("us-east-1", "eu-central-1", "GLOBAL")
    everything = [p["ip_prefix"] for p in aws["prefixes"]
                  if p["service"] in ("EC2", "GLOBALACCELERATOR") and p["region"] in regions]

    # Labels land in the router's Description column, so they are kept short.
    cursor_blocks = [
        ("Cursor AWS", collapse(union["aws"])),
        ("Cursor Cloudflare", collapse(union["cloudflare"])),
        ("Cursor Vercel", collapse(VERCEL)),
    ]
    full_blocks = [
        ("Cursor AWS full", collapse(everything)),
        ("Cursor Cloudflare", collapse(union["cloudflare"])),
        ("Cursor Vercel", collapse(VERCEL)),
    ]
    claude_blocks = [("Claude Anthropic", collapse(ANTHROPIC))]
    gemini_blocks = [("Gemini Google", collapse(GOOGLE_FRONTEND))]

    print("Fetching Meta's announced prefixes...", file=sys.stderr)
    instagram_blocks = [("Instagram Meta", collapse(ripe_prefixes(META_ASNS)))]

    print("Resolving Clash Royale hosts...", file=sys.stderr)
    clash_ips = resolve(CLASH_HOSTS)

    # EC2 across every region, not just us-west-2: the login endpoints are in Frankfurt,
    # Virginia and Asia, and pinning to the game server's region is what left the game
    # loadable but unable to sign in.
    ec2 = [p["ip_prefix"] for p in aws["prefixes"] if p["service"] == "EC2"]
    clash_aws = prefixes_covering(ec2, clash_ips)
    covered = [ipaddress.ip_network(p) for p in clash_aws]
    leftover = {ip for ip in clash_ips
                if not any(ipaddress.ip_address(ip) in n for n in covered)}
    print(f"  {len(clash_ips)} addresses: {len(clash_aws)} EC2 prefixes,"
          f" {len(leftover)} off AWS", file=sys.stderr)

    clash_union = remember({"clash_aws": clash_aws, "clash_bgp": bgp_prefixes(leftover)})

    # Every CloudFront range, not just the edges seen from here. CloudFront picks an edge
    # by where the client appears to be, so going through the tunnel moves the game onto
    # edges this machine will never resolve, and a partial list would break login.
    cloudfront = [p["ip_prefix"] for p in aws["prefixes"] if p["service"] == "CLOUDFRONT"]
    supercell = ripe_prefixes(SUPERCELL_ASN)
    clash_blocks = [
        ("Clash Royale AWS", collapse(clash_union["clash_aws"])),
        ("Clash Royale CDN", collapse(cloudfront)),
        ("Clash Royale other", collapse(clash_union["clash_bgp"])),
        ("Supercell", collapse(supercell)),
    ]
    clash_full_blocks = [
        ("Clash Royale AWS full", collapse([p["ip_prefix"] for p in aws["prefixes"]
                                            if p["service"] == "EC2"
                                            and p["region"] in ("us-west-2", "us-east-1",
                                                                "eu-central-1")])),
        ("Clash Royale CDN", collapse(cloudfront)),
        ("Clash Royale other", collapse(clash_union["clash_bgp"])),
        ("Supercell", collapse(supercell)),
    ]

    targets = [
        ("keenetic-cursor.bat", cursor_blocks),
        ("keenetic-claude.bat", claude_blocks),
        ("keenetic-gemini.bat", gemini_blocks),
        ("keenetic-instagram.bat", instagram_blocks),
        ("keenetic-clashroyale.bat", clash_blocks),
        ("keenetic-all.bat", cursor_blocks + claude_blocks + gemini_blocks),
        ("keenetic-cursor-full.bat", full_blocks),
        ("keenetic-clashroyale-full.bat", clash_full_blocks),
    ]
    for name, blocks in targets:
        write_keenetic(HERE / name, blocks, labels=not args.no_labels)
        print(f"  {name}: {sum(len(n) for _, n in blocks)} routes", file=sys.stderr)

    # For "Routing -> DNS-based routes", which takes names instead of prefixes and so does
    # not care that Supercell moves between regions and CDNs. Needs KeeneticOS 5.0.
    for name, domains in DOMAIN_LISTS.items():
        path = HERE / f"domains-{name}.txt"
        path.write_text("\n".join(domains) + "\n")
        print(f"  domains-{name}.txt: {len(domains)} domains", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
