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


class ExitNodeList(BaseModel):
    mode: str
    active: str | None = None
    pinned: str | None = None
    killswitch: bool = True
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
