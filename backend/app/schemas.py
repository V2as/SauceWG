from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, field_validator

from .awg import protocol as proto
from .models import ClientStatus, ResetStrategy

#: Accepts the spellings an operator is likely to type ("legacy", "2") and stores the
#: canonical one, so everything downstream compares plain strings.
_PROTOCOL_FIELD = Field(
    default=None,
    description=(
        "AmneziaWG generation to speak: "
        f"{', '.join(proto.PROTOCOLS)}. Omit to keep whatever the node already serves."
    ),
)


def _normalize_protocol(value: str | None) -> str | None:
    try:
        return proto.normalize_or_none(value)
    except proto.UnknownProtocol as exc:
        raise ValueError(str(exc)) from None


class Token(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int


class AdminBase(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    is_sudo: bool = False
    is_active: bool = True


class AdminCreate(AdminBase):
    password: str = Field(min_length=6, max_length=128)


class AdminUpdate(BaseModel):
    password: str | None = Field(default=None, min_length=6, max_length=128)
    is_sudo: bool | None = None
    is_active: bool | None = None


class AdminOut(AdminBase):
    model_config = ConfigDict(from_attributes=True)

    id: int
    created_at: datetime
    last_login_at: datetime | None = None


class ClientCreate(BaseModel):
    name: str = Field(min_length=1, max_length=128, pattern=r"^[\w.@ -]+$")
    address: str | None = None
    private_key: str | None = None
    public_key: str | None = None
    use_preshared_key: bool = True
    data_limit: int = Field(default=0, ge=0)
    reset_strategy: ResetStrategy = ResetStrategy.no_reset
    expire_at: datetime | None = None
    expire_in_days: int | None = Field(default=None, ge=0)
    enabled: bool = True
    note: str | None = None

    @field_validator("name")
    @classmethod
    def _clean_name(cls, v: str) -> str:
        return v.strip()


class ClientUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=128, pattern=r"^[\w.@ -]+$")
    data_limit: int | None = Field(default=None, ge=0)
    reset_strategy: ResetStrategy | None = None
    expire_at: datetime | None = None
    enabled: bool | None = None
    note: str | None = None


class ClientOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    address: str
    public_key: str
    status: ClientStatus
    enabled: bool
    data_limit: int
    reset_strategy: ResetStrategy
    used_up: int
    used_down: int
    used_total: int
    lifetime_up: int
    lifetime_down: int
    expire_at: datetime | None
    last_handshake_at: datetime | None
    last_endpoint: str | None
    online_at: datetime | None
    is_online: bool
    sub_token: str
    note: str | None
    created_at: datetime
    subscription_url: str = ""


class ClientList(BaseModel):
    total: int
    items: list[ClientOut]


class UsagePoint(BaseModel):
    bucket: datetime
    up: int
    down: int


class UsageSeries(BaseModel):
    total_up: int
    total_down: int
    points: list[UsagePoint]


class CascadeStatus(BaseModel):
    enabled: bool
    connected: bool
    iface: str
    endpoint: str | None = None
    peer_public_key: str | None = None
    last_handshake_at: datetime | None = None
    rx_bytes: int = 0
    tx_bytes: int = 0
    exit_ip: str | None = None
    # Which of the configured exit nodes is carrying traffic right now.
    node: str | None = None
    mode: str = "auto"
    nodes_total: int = 0
    nodes_healthy: int = 0
    # What happens while no exit node can carry traffic: "direct" lets the entry node
    # carry it, "block" drops it.
    fallback: str = "direct"
    # True while that is what is happening: clients are online through the entry
    # node's own address, or cut off, depending on the mode above.
    fallback_active: bool = False
    # Destinations deliberately routed past the cascade.
    direct_routes: int = 0
    # Destinations the entry node is reopening for itself right now, and how many.
    # Zero with bypass_active false is the normal state of a healthy cascade.
    bypass_active: bool = False
    bypass_routes: int = 0


class NodeRecovery(BaseModel):
    """What the panel has done about an exit node that stopped handshaking.

    The cascade routes around a failed node on its own, so this is about the server:
    the panel restarts its service and, if that is not enough, re-installs the uplink
    key. A server that does not answer SSH at all cannot be fixed from here, which is
    what ``blocked`` says.
    """

    attempts: int = 0
    # What the last attempt got as far as: probe, restart or repair.
    last_action: str | None = None
    last_error: str | None = None
    # `unreachable` means the server does not answer and needs a human — usually a
    # VPS that has been suspended or deleted. `exhausted` means the attempt budget
    # is spent. Null means it is still being worked on.
    blocked: str | None = None
    down_for_seconds: int = 0
    since_last_attempt_seconds: int | None = None
    recovered: bool = False


class ExitNode(BaseModel):
    name: str
    iface: str
    address: str
    priority: int
    endpoint: str | None = None
    exit_ip: str | None = None
    # The entry node's own key for this uplink; install it on the exit node.
    public_key: str
    peer_public_key: str | None = None
    paired: bool
    healthy: bool
    active: bool
    last_handshake_at: datetime | None = None
    latency_ms: float | None = None
    rx_bytes: int = 0
    tx_bytes: int = 0
    # Which AmneziaWG generation this uplink speaks. The exit node decides, since it
    # is the end that answers the handshake.
    protocol: str | None = None
    # True when the panel installed this node and can reach it over SSH again.
    managed: bool = False
    ssh_host: str | None = None
    ssh_port: int | None = None
    ssh_user: str | None = None
    # True when the panel's own SSH key is installed on that server, which is what
    # lets every other call on this node be made without credentials.
    ssh_key: bool = False
    created_at: datetime | None = None
    # Set while an install or removal is still running for this node.
    task_id: str | None = None
    # Present only while the panel is trying to put this node back, or has stopped
    # trying. Absent for a healthy node.
    recovery: NodeRecovery | None = None


class ExitNodeList(BaseModel):
    mode: str
    active: str | None = None
    pinned: str | None = None
    # Kept for clients written before the fallback had two modes; it is exactly
    # `fallback == "block"`.
    killswitch: bool = True
    fallback: str = "direct"
    fallback_active: bool = False
    # True when the node container stopped refreshing its state file.
    stale: bool = False
    updated_at: datetime | None = None
    # Whatever the node container refused about the current list, if anything.
    config_error: str | None = None
    # False when the panel cannot edit the list, e.g. NODE_PROVISION_ENABLED=false
    # or ./config is not mounted read-write.
    provisioning: bool = False
    nodes: list[ExitNode]


class ExitNodeCreate(BaseModel):
    """Installs AmneziaWG on a server over SSH and joins it to the cascade."""

    name: str = Field(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
    host: str = Field(min_length=1, max_length=253, description="IP address or hostname")
    ssh_port: int = Field(default=22, ge=1, le=65535)
    ssh_user: str = Field(default="root", max_length=64)
    # Used for the duration of the install and never stored. Both may be omitted on a
    # server that already carries the panel's public key, which is what
    # GET /api/nodes/ssh-key publishes for exactly this purpose.
    ssh_password: str | None = Field(default=None, repr=False, max_length=512)
    ssh_private_key: str | None = Field(default=None, repr=False, max_length=16384)
    port: int = Field(default=51820, ge=1, le=65535, description="UDP port of the exit node")
    subnet: str = "10.77.0.0/24"
    priority: int | None = Field(default=None, ge=0, le=65535)
    address: str | None = Field(default=None, description="uplink address, allocated when omitted")
    preshared_key: str | None = Field(default=None, repr=False, max_length=64)
    protocol: str | None = _PROTOCOL_FIELD
    # Preset name or literal spec for the signature packet the uplink sends. Ignored
    # on a generation without I1.
    signature: str | None = Field(default=None, max_length=1024)
    note: str | None = Field(default=None, max_length=512)

    @field_validator("name", "host")
    @classmethod
    def _trim(cls, v: str) -> str:
        return v.strip()

    @field_validator("protocol")
    @classmethod
    def _protocol(cls, v: str | None) -> str | None:
        return _normalize_protocol(v)


class ExitNodeAdopt(BaseModel):
    """Registers an exit node that was installed by hand.

    This is the object ``saucewg install-node --json`` prints, so it can be piped
    straight in.
    """

    name: str = Field(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
    endpoint: str = Field(min_length=3, description="host:port of the exit node")
    public_key: str = Field(min_length=1, max_length=128)
    preshared_key: str | None = Field(default=None, repr=False, max_length=64)
    address: str | None = None
    priority: int | None = Field(default=None, ge=0, le=65535)
    protocol: str | None = _PROTOCOL_FIELD
    # The padding and header parameters the exit node chose. They have to be repeated
    # here because both ends of the tunnel must agree on them.
    s1: int | None = None
    s2: int | None = None
    s3: int | None = None
    s4: int | None = None
    h1: str | None = None
    h2: str | None = None
    h3: str | None = None
    h4: str | None = None
    # Signature packets are sender-side, so these are only carried so that a node
    # keeps the disguise it was installed with across a reload.
    i1: str | None = Field(default=None, max_length=1024)
    note: str | None = Field(default=None, max_length=512)

    @field_validator("protocol")
    @classmethod
    def _protocol(cls, v: str | None) -> str | None:
        return _normalize_protocol(v)


class ExitNodeUpdate(BaseModel):
    priority: int | None = Field(default=None, ge=0, le=65535)
    endpoint: str | None = None
    # Changing this rebuilds the uplink, and the exit node has to be moved to the
    # same generation or the handshake stops working.
    protocol: str | None = _PROTOCOL_FIELD
    note: str | None = Field(default=None, max_length=512)

    @field_validator("protocol")
    @classmethod
    def _protocol(cls, v: str | None) -> str | None:
        return _normalize_protocol(v)


class NodeCredentials(BaseModel):
    """Root credentials for one operation. They are never stored, so any command
    that has to touch the server again asks for them again."""

    ssh_password: str | None = Field(default=None, repr=False, max_length=512)
    ssh_private_key: str | None = Field(default=None, repr=False, max_length=16384)


class ExitNodeProtocolChange(NodeCredentials):
    """Moves an installed exit node to another AmneziaWG generation.

    Both ends have to move together, so this reconfigures the exit node over SSH and
    then rebuilds the uplink here with the parameters it reports back.
    """

    protocol: str = Field(description=f"one of: {', '.join(proto.PROTOCOLS)}")
    # Preset name or literal spec for the signature packet. Ignored on 1.0.
    signature: str | None = Field(default=None, max_length=1024)

    @field_validator("protocol")
    @classmethod
    def _protocol(cls, v: str) -> str:
        try:
            return proto.normalize(v)
        except proto.UnknownProtocol as exc:
            raise ValueError(str(exc)) from None


class ExitNodeDelete(NodeCredentials):
    """How far to go when removing a node.

    Taking it out of the cascade only needs the panel; wiping the software off the
    server needs a way in — the panel's enrolled key, or credentials.
    """

    uninstall: bool = False
    # The key is only useful to whoever holds this panel, but a server being handed
    # back to a provider should not keep an authorised key for a machine that no
    # longer manages it.
    revoke_key: bool = True


class DirectRoute(BaseModel):
    """One destination that leaves through the entry node instead of an exit node."""

    cidr: str = Field(description="an IPv4 address or range; a bare address means /32")
    note: str | None = Field(default=None, max_length=512)
    enabled: bool = True
    # True once the node container has this prefix in its routing table. False means
    # the change has not been applied yet, or could not be.
    active: bool = False


class DirectRouteCreate(BaseModel):
    """Adds one or more destinations to the bypass list.

    A list is accepted because these normally arrive in groups — every range a
    service resolves to, exported from somewhere that already knows them.
    """

    cidr: list[str] = Field(min_length=1, max_length=4096)
    note: str | None = Field(default=None, max_length=512)
    enabled: bool = True


class DirectRouteUpdate(BaseModel):
    note: str | None = Field(default=None, max_length=512)
    # Turning a route off leaves it in the list but puts the destination back on the
    # cascade, which is the reversible way to test whether it was the cause.
    enabled: bool | None = None


class DirectRouteList(BaseModel):
    routes: list[DirectRoute]
    # The interface the entry node sends these out of, once it has applied them.
    via: str | None = None
    # False when the node container is not publishing route state: it is down, or
    # older than this feature.
    live: bool = False
    # False when the panel cannot edit the list.
    editable: bool = True
    # Why the list on file is not the list in effect, if it is not.
    config_error: str | None = None


class BypassEntry(BaseModel):
    """One destination the entry node opens the outbound half of itself.

    For destinations blocked at connection establishment rather than by route: the
    SYN to their IPv4 is dropped, so no route change reaches them.
    """

    cidr: str = Field(description="an IPv4 address or range; a bare address means /32")
    # The IPv6 address of the same server, tried first when it is known. Without one
    # the destination's own IPv4 is dialled until a handshake lands.
    v6: str | None = None
    note: str | None = Field(default=None, max_length=512)
    enabled: bool = True
    # True once the node container is redirecting this prefix into the relay. In
    # `auto` every entry reads false while an exit node is carrying client traffic,
    # which is the normal state and not a fault.
    active: bool = False
    # True when the entry comes from a group the node image ships rather than from
    # the file this panel edits, so the UI can say why it cannot be deleted.
    built_in: bool = False


class BypassEntryCreate(BaseModel):
    """Adds one or more destinations to the bypass list."""

    cidr: list[str] = Field(min_length=1, max_length=4096)
    # Only meaningful for a single destination: an IPv6 address is one server, and
    # sending a range of unrelated destinations to it would reach the wrong one.
    v6: str | None = Field(default=None, max_length=64)
    note: str | None = Field(default=None, max_length=512)
    enabled: bool = True


class BypassEntryUpdate(BaseModel):
    v6: str | None = Field(default=None, max_length=64)
    note: str | None = Field(default=None, max_length=512)
    # Turning an entry off stops it being redirected without losing it, which is the
    # reversible way to find out whether the relay was making things worse.
    enabled: bool | None = None


class BypassRelay(BaseModel):
    """What the relay itself reports, which is where the counters live."""

    listen: str | None = None
    prefixes: int = 0
    open: int = 0
    accepted: int = 0
    via_v6: int = 0
    via_retry: int = 0
    failed: int = 0
    # Outbound handshakes spent on the retry path, which is the honest measure of how
    # hard the filter is dropping them: far above `via_retry` means it is dropping
    # nearly all of them.
    attempts: int = 0
    # Flows for a destination already known not to be answering, given one handshake
    # instead of a burst. Rising steadily means clients are hammering something that
    # is blocked outright rather than being sampled, and the address is worth
    # looking at.
    cooled: int = 0
    rx_bytes: int = 0
    tx_bytes: int = 0
    last_error: str | None = None


class BypassList(BaseModel):
    mode: str = "auto"
    # The groups of destinations the node image ships a table for, e.g. `telegram`.
    groups: list[str] = []
    entries: list[BypassEntry]
    # True while the redirect is installed. In `auto` this is false whenever an exit
    # node is carrying client traffic.
    active: bool = False
    relay: BypassRelay | None = None
    # False when the node container is not publishing bypass state: it is down, or
    # older than this feature.
    live: bool = False
    # False when the panel cannot edit the list.
    editable: bool = True
    # Why the list on file is not the list in effect, if it is not.
    config_error: str | None = None


class PanelSshKey(BaseModel):
    """The public half of the key the panel manages exit nodes with.

    Injecting it into a server at creation time — a provider's "SSH keys" field, or
    cloud-init — is what makes ``POST /api/nodes`` work with no password at all.
    """

    public_key: str
    fingerprint: str
    created_at: datetime | None = None
    # False when the panel cannot keep a key, so every call needs credentials.
    enabled: bool = True


class NodeCheck(NodeCredentials):
    """A dry run against a server before committing to an install."""

    host: str = Field(min_length=1, max_length=253)
    ssh_port: int = Field(default=22, ge=1, le=65535)
    ssh_user: str = Field(default="root", max_length=64)

    @field_validator("host")
    @classmethod
    def _trim(cls, v: str) -> str:
        return v.strip()


class NodeCheckResult(BaseModel):
    """What one SSH session found. Nothing here changes the server."""

    reachable: bool = False
    # A sentence to show when reachable is false; null otherwise.
    error: str | None = None
    # True when the account can act as root, which an install needs.
    root: bool = False
    os: str | None = None
    kernel: str | None = None
    arch: str | None = None
    cpus: int = 0
    memory_mb: int = 0
    disk_free_mb: int = 0
    uptime_seconds: int = 0
    docker: bool = False
    # True when SauceWG is already on this server; role says which kind.
    saucewg: bool = False
    role: str | None = None
    # The host key the server presented, recorded when the node is installed.
    host_key: str | None = None
    # True when the panel got in with its own key and needs no password to install.
    used_panel_key: bool = False


class NodeContainer(BaseModel):
    name: str
    state: str = ""
    status: str = ""


class NodeStatus(BaseModel):
    """An exit server as it describes itself, over SSH."""

    name: str
    reachable: bool = False
    error: str | None = None
    ssh_host: str | None = None
    role: str | None = None
    cli_version: str | None = None
    dir: str | None = None
    os: str | None = None
    kernel: str | None = None
    arch: str | None = None
    cpus: int = 0
    memory_mb: int = 0
    disk_free_mb: int = 0
    uptime_seconds: int = 0
    docker: bool = False
    saucewg: bool = False
    containers: list[NodeContainer] = []


class NodeLogs(BaseModel):
    name: str
    service: str | None = None
    lines: int
    text: str


class NodeServiceRequest(NodeCredentials):
    """Credentials are optional: a node with the panel's key needs none."""


class NodeUpgradeRequest(NodeCredentials):
    # Which image tag to move the exit node to. Omitted keeps the tag the panel
    # itself installs, so a fleet stays on one release.
    tag: str | None = Field(default=None, max_length=128)


class TaskLogLine(BaseModel):
    at: datetime
    text: str


class TaskOut(BaseModel):
    id: str
    action: str
    target: str
    status: str
    step: str
    error: str | None = None
    result: dict[str, object] | None = None
    created_at: datetime
    finished_at: datetime | None = None
    log: list[TaskLogLine] = []


class SystemStats(BaseModel):
    panel_title: str
    version: str
    cpu_percent: float
    cpu_cores: int
    mem_total: int
    mem_used: int
    disk_total: int
    disk_used: int
    uptime_seconds: int
    clients_total: int
    clients_active: int
    clients_online: int
    total_up: int
    total_down: int
    incoming_speed: int
    outgoing_speed: int
    node_ready: bool
    server_public_key: str
    endpoint: str
    cascade: CascadeStatus


class NodeSettings(BaseModel):
    iface: str
    subnet: str
    address: str
    listen_port: int
    endpoint_host: str
    endpoint_port: int
    server_public_key: str
    mtu: int
    client_dns: str
    client_mtu: int
    client_allowed_ips: str
    # Which AmneziaWG generation the entry interface serves, and the generations a
    # client can be asked to speak.
    protocol: str
    protocols_supported: list[str]
    # Every parameter the generation in force carries. Values are strings because an
    # H-parameter may be a range and I1-I5 are signature specs.
    obfuscation: dict[str, str]
