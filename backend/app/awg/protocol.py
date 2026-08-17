"""The AmneziaWG generations this panel can serve, and what each one carries.

A tunnel's generation is not negotiated: it is decided by which ``[Interface]``
obfuscation parameters the two ends carry. AmneziaVPN and KeeneticOS identify a
profile the same way, so getting the set right is what makes a config loadable.

    1.0   Jc Jmin Jmax S1 S2 H1-H4        every KeeneticOS from 4.2 Alpha 2 on
    1.5   the same, plus I1               KeeneticOS 5.1 Alpha 3 and newer
    2.0   the same, plus I1, S3 and S4    KeeneticOS 5.1 Alpha 3 and newer

AWG 3.0 is deliberately absent: no router firmware speaks it, so a 3.0 profile
cannot be loaded into a Keenetic at all.

This mirrors ``docker/awg/lib.sh``; the two must agree, because the node writes the
profile and the panel renders the clients that have to match it.
"""

from __future__ import annotations

from typing import Final

PROTOCOL_1_0: Final = "1.0"
PROTOCOL_1_5: Final = "1.5"
PROTOCOL_2_0: Final = "2.0"

#: Newest generation KeeneticOS 5.1 Alpha 3 and later accept, and what a fresh install
#: is given. The installer owns that choice (``AWG_PROTOCOL_DEFAULT`` in lib.sh); this
#: is here so the panel can say what "newest" means without asking the node.
LATEST_KEENETIC_PROTOCOL: Final = PROTOCOL_2_0

#: What to read state as when it records no generation at all. Deliberately *not* the
#: newest: such a node has been serving 1.0 clients since before generations were
#: recorded, and answering "2.0" would hand its clients a profile it cannot speak.
ASSUMED_PROTOCOL: Final = PROTOCOL_1_0

PROTOCOLS: Final = (PROTOCOL_1_0, PROTOCOL_1_5, PROTOCOL_2_0)

#: Every parameter any generation can carry, in the order a .conf lists them.
ALL_PARAMS: Final = (
    "JC", "JMIN", "JMAX",
    "S1", "S2", "S3", "S4",
    "H1", "H2", "H3", "H4",
    "I1", "I2", "I3", "I4", "I5",
)  # fmt: skip

#: Parameters that identify each generation. I2-I5 are opt-in extras rather than
#: part of the identity, so they are absent here.
PROTOCOL_PARAMS: Final[dict[str, tuple[str, ...]]] = {
    PROTOCOL_1_0: ("JC", "JMIN", "JMAX", "S1", "S2", "H1", "H2", "H3", "H4"),
    PROTOCOL_1_5: ("JC", "JMIN", "JMAX", "S1", "S2", "H1", "H2", "H3", "H4", "I1"),
    PROTOCOL_2_0: (
        "JC", "JMIN", "JMAX", "S1", "S2", "S3", "S4",
        "H1", "H2", "H3", "H4", "I1",
    ),  # fmt: skip
}

#: Parameters both ends must agree on, because they change the shape of packets the
#: far end has to parse. The rest (junk and signature packets) are sender-side only,
#: so the panel may hand a client its own values.
SHARED_PARAMS: Final = ("S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4")

#: Parameters whose value is a signature-packet spec rather than a number.
TEXT_PARAMS: Final = ("I1", "I2", "I3", "I4", "I5")

#: How each parameter is spelled in a .conf file.
_LABELS: Final = {"JC": "Jc", "JMIN": "Jmin", "JMAX": "Jmax"}

_ALIASES: Final = {
    "": PROTOCOL_1_0,
    "legacy": PROTOCOL_1_0,
    "awglegacy": PROTOCOL_1_0,
    "awg-legacy": PROTOCOL_1_0,
    "1": PROTOCOL_1_0,
    "1.0": PROTOCOL_1_0,
    "1.5": PROTOCOL_1_5,
    "2": PROTOCOL_2_0,
    "2.0": PROTOCOL_2_0,
}


class UnknownProtocol(ValueError):
    """Raised for a generation this panel cannot serve."""

    def __init__(self, value: str) -> None:
        super().__init__(
            f"{value!r} is not an AmneziaWG generation SauceWG can serve "
            f"(one of: {', '.join(PROTOCOLS)})"
        )
        self.value = value


def normalize(value: str | None) -> str:
    """Canonical name of a generation, accepting the spellings operators use."""
    key = (value or "").strip().lower().replace("_", "").replace(" ", "")
    try:
        return _ALIASES[key]
    except KeyError:
        raise UnknownProtocol(value or "") from None


def normalize_or_none(value: str | None) -> str | None:
    """Same as :func:`normalize`, but an absent value stays absent.

    Used where "not specified" has to keep meaning "leave whatever the node
    already decided", which is what keeps an upgrade from moving a running tunnel
    to a generation its clients do not speak.
    """
    if value is None or not str(value).strip():
        return None
    return normalize(value)


def params_for(protocol: str) -> tuple[str, ...]:
    return PROTOCOL_PARAMS[normalize(protocol)]


def carries(protocol: str, param: str) -> bool:
    """True when the generation carries the named parameter.

    I2-I5 ride along with I1: a generation that sends signature packets at all
    accepts the extra ones.
    """
    param = param.upper()
    if param in ("I2", "I3", "I4", "I5"):
        param = "I1"
    return param in params_for(protocol)


def label(param: str) -> str:
    param = param.upper()
    return _LABELS.get(param, param)


def infer(params: dict[str, object], *, prefix: str = "") -> str:
    """Works out which generation a profile describes from what it carries.

    Used for state written before generations were recorded: such a node has been
    serving 1.0 clients all along, so the absence of S3/S4/I1 is the answer rather
    than a reason to guess the current default.
    """

    def present(name: str) -> bool:
        value = params.get(f"{prefix}{name}")
        return value is not None and str(value).strip() not in ("", "0")

    if present("S3") or present("S4"):
        return PROTOCOL_2_0
    if present("I1"):
        return PROTOCOL_1_5
    return PROTOCOL_1_0


# ---------------------------------------------------------------------------
# Custom protocol signatures (I1-I5)
# ---------------------------------------------------------------------------
#
# A signature packet goes out ahead of the handshake so that the first thing a
# censor's classifier sees is a protocol it already passes. The far end never reads
# them, which is why the choice can differ per client.

CPS_PRESETS: Final[dict[str, str]] = {
    # A QUIC v1 long header: 0xc3, version 1, then 8-byte connection ids. UDP/443
    # is the usual entry port, so this matches what the traffic already looks like.
    "quic": "<b 0xc30000000108><r 8><b 0x08><r 8><b 0x0045dc><t><r 16>",
    # A recursive A-record query for a random <6 chars>.com name.
    "dns": (
        "<r 2><b 0x01000001000000000000><b 0x03><rc 3><b 0x06><rc 6>"
        "<b 0x03636f6d00><b 0x00010001>"
    ),
    "random": "<r 128>",
    # Some mobile carriers pass a short signature where a long one is dropped.
    "short": "<r 48>",
    "none": "",
}

DEFAULT_CPS: Final = "quic"


class UnknownSignaturePreset(ValueError):
    def __init__(self, value: str) -> None:
        super().__init__(
            f"{value!r} is not a signature packet preset "
            f"(one of: {', '.join(CPS_PRESETS)}), nor a spec containing '<'"
        )
        self.value = value


def cps_spec(value: str | None) -> str:
    """Resolves a preset name to its spec and leaves a literal spec untouched."""
    text = (value or "").strip()
    if not text:
        return ""
    if "<" in text:
        return text
    try:
        return CPS_PRESETS[text.lower()]
    except KeyError:
        raise UnknownSignaturePreset(text) from None
