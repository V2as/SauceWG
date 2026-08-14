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
    # The node container republishes uplinks.json on every health tick; anything
    # older than this means its monitor stopped.
    uplink_state_max_age_seconds: int = 60

    # --- generated client configs ---------------------------------------
    client_dns: str = "1.1.1.1, 1.0.0.1"
    client_mtu: int = 1280
    client_allowed_ips: str = "0.0.0.0/0, ::/0"
    client_keepalive: int = 25
    # Junk-packet parameters are client-side only; the panel may hand out values
    # that differ from the server's without breaking the handshake.
    client_jc: int = 0
    client_jmin: int = 0
    client_jmax: int = 0

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
    def uplink_state_file(self) -> str:
        return f"{self.awg_socket_dir}/uplinks.json"

    @property
    def uplink_control_file(self) -> str:
        return f"{self.awg_socket_dir}/uplink-control.json"


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
