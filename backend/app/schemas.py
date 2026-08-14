from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, field_validator

from .models import ClientStatus, ResetStrategy


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
    obfuscation: dict[str, int]
