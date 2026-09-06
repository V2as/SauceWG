from functools import lru_cache
from typing import Literal

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore", case_sensitive=False)

    # --- service ---------------------------------------------------------
    panel_title: str = "SauceWG"
    debug: bool = False
    docs_enabled: bool = True
    cors_origins: str = "*"

    # --- database --------------------------------------------------------
    postgres_host: str = "postgres"
    postgres_port: int = 5432
    postgres_db: str = "saucewg"
    postgres_user: str = "saucewg"
    postgres_password: str = "saucewg"
    database_url: str = ""

    # --- auth ------------------------------------------------------------
    jwt_secret: str = Field(default="change-me-please")
    jwt_algorithm: str = "HS256"
    jwt_access_token_expire_minutes: int = 60 * 24
    admin_username: str = "admin"
    admin_password: str = "admin"

    # --- AmneziaWG node --------------------------------------------------
    awg_socket_dir: str = "/var/run/amneziawg"
    awg_config_dir: str = "/etc/amnezia/amneziawg"
    awg_iface: str = "awg0"
    awg_subnet: str = "10.8.0.0/24"
    awg_endpoint_host: str = ""
    awg_endpoint_port: int = 51820

    cascade_enabled: bool = True
    cascade_iface: str = "awg1"
    cascade_uplink_subnet: str = "10.77.0.0/24"
    # The node container republishes uplinks.json on every health tick; anything
    # older than this means its monitor stopped.
    uplink_state_max_age_seconds: int = 60
    # The node container's own health rule, which the panel applies again to what it
    # publishes: an uplink whose last handshake is older than the timeout plus the
    # time the hysteresis may take to act on it is dead, however healthy the node
    # container says it is. The container publishes both numbers in uplinks.json, so
    # these are only read for one too old to — and must match the defaults in
    # docker/awg/uplinks.sh.
    cascade_handshake_timeout: int = 180
    cascade_probe_interval: int = 10
    cascade_fail_threshold: int = 3

    # --- exit node provisioning ------------------------------------------
    # The exit node list, bind-mounted read-write from the host so the panel can
    # edit the same file the node container reads.
    node_registry_file: str = "/etc/saucewg/host/exit-nodes.json"
    # Destinations that bypass the cascade, in the same bind-mounted directory. The
    # node container reads it from its own side of the mount.
    routes_registry_file: str = "/etc/saucewg/host/direct-routes.json"
    # Destinations the entry node reopens for itself because the handshake to their
    # IPv4 is what is being dropped, which no route can fix. Same directory again.
    bypass_registry_file: str = "/etc/saucewg/host/bypass.json"
    # Whether the node blocks BitTorrent in the traffic it forwards, and how hard.
    # One client seeding is what gets an exit server suspended, so this is a switch
    # rather than a list. Same directory again.
    torrent_registry_file: str = "/etc/saucewg/host/torrent-block.json"
    # Set to false to make the panel read-only with respect to the cascade, e.g.
    # when the node list is managed by configuration management.
    node_provision_enabled: bool = True
    node_default_port: int = 51820
    node_ssh_port: int = 22
    node_ssh_user: str = "root"
    # A cold install pulls Docker and three images, which is minutes on a slow VPS.
    node_ssh_timeout_seconds: int = 900
    node_ssh_connect_timeout_seconds: int = 20
    # Ceiling for the calls that answer inside one HTTP request — a status read, a
    # log fetch, a reachability probe — rather than becoming a task.
    node_ssh_query_timeout_seconds: int = 60
    # The panel's own SSH key pair. It is enrolled on every node the panel installs,
    # which is what lets a bot manage the fleet without holding root passwords.
    node_ssh_key_file: str = "/etc/saucewg/host/panel-ssh-key"
    # false stops the panel from enrolling its key, at the cost of having to supply
    # credentials on every call that touches an exit server.
    node_ssh_key_enabled: bool = True
    # How long to wait for the node container to confirm it applied a new list.
    node_reload_timeout_seconds: int = 90

    # --- exit node recovery ----------------------------------------------
    # The cascade fails over on its own, so an unhealthy exit node costs nobody
    # their connection — which is exactly why one can stay down for days without
    # anybody noticing until the last node goes too. When the panel can reach a
    # node over SSH it can also put it back, so it tries.
    node_recovery_enabled: bool = True
    # How often to look at the fleet. Cheap: it reads the state file the node
    # container already publishes and only opens an SSH session for a node that
    # has been down long enough to be worth acting on.
    node_recovery_interval_seconds: int = 60
    # How long an uplink must have been unhealthy before the first attempt. Long
    # enough that a restart, a reboot or a reload is not chased by a repair.
    node_recovery_grace_seconds: int = 300
    # Attempts are spaced out geometrically from the interval above, so a server
    # that is simply gone is probed a few times an hour rather than every minute.
    node_recovery_backoff_factor: float = 3.0
    node_recovery_max_backoff_seconds: int = 3600
    # After this many consecutive failed attempts the node is left alone until it
    # recovers by itself or an operator intervenes. Retrying for ever would hide
    # the one thing worth escalating: a server that no longer exists.
    node_recovery_max_attempts: int = 6
    # Uploaded to every exit node and executed there. Falls back to fetching the
    # script from GitHub when the image does not carry a copy.
    saucewg_installer_path: str = "/app/assets/saucewg.sh"
    saucewg_repo: str = "V2as/SauceWG"
    saucewg_ref: str = "main"
    saucewg_namespace: str = "v2as"
    saucewg_image_prefix: str = "saucewg-"
    saucewg_tag: str = "latest"

    # --- generated client configs ---------------------------------------
    client_dns: str = "1.1.1.1, 1.0.0.1"
    client_mtu: int = 1280
    client_allowed_ips: str = "0.0.0.0/0, ::/0"
    client_keepalive: int = 25
    # Junk and signature packets are built by the sender alone, so the panel may
    # hand out values that differ from the server's without breaking the handshake.
    # Zero (or empty) means "use whatever the interface itself carries".
    client_jc: int = 0
    client_jmin: int = 0
    client_jmax: int = 0
    # A preset name (quic, dns, random, short, none) or a literal spec, applied only
    # on a generation that has I1 at all.
    client_signature: str = ""

    # --- workers ---------------------------------------------------------
    collector_interval_seconds: int = 10
    sync_interval_seconds: int = 30
    usage_bucket_minutes: int = 60
    online_timeout_seconds: int = 180
    usage_retention_days: int = 90

    # --- subscriptions ---------------------------------------------------
    subscription_url_prefix: str = ""

    log_level: Literal["debug", "info", "warning", "error"] = "info"

    @field_validator("cors_origins")
    @classmethod
    def _strip(cls, v: str) -> str:
        return v.strip()

    @property
    def sqlalchemy_url(self) -> str:
        if self.database_url:
            return self.database_url
        return (
            f"postgresql+asyncpg://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )

    @property
    def cors_origin_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]

    @property
    def server_params_file(self) -> str:
        return f"{self.awg_config_dir}/{self.awg_iface}.params"

    @property
    def cascade_params_file(self) -> str:
        return f"{self.awg_config_dir}/{self.cascade_iface}.params"

    @property
    def cascade_failover_seconds(self) -> int:
        """How long the node container's failover may take once a handshake stops.

        Its hysteresis keeps an uplink healthy through ``CASCADE_FAIL_THRESHOLD`` bad
        probes on purpose, so a handshake may legitimately be this much older than
        ``CASCADE_HANDSHAKE_TIMEOUT`` while the verdict is still "healthy".
        """
        return self.cascade_probe_interval * self.cascade_fail_threshold

    @property
    def uplink_state_file(self) -> str:
        return f"{self.awg_socket_dir}/uplinks.json"

    @property
    def uplink_control_file(self) -> str:
        return f"{self.awg_socket_dir}/uplink-control.json"

    @property
    def torrent_state_file(self) -> str:
        # Its own file rather than a key in uplinks.json: the same filter runs on
        # an exit node, which has no cascade state to publish it alongside.
        return f"{self.awg_socket_dir}/torrents.json"

    @property
    def uplink_reload_file(self) -> str:
        return f"{self.awg_socket_dir}/reload.request"


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
