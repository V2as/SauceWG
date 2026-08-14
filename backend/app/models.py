from __future__ import annotations

import enum
from datetime import datetime, timezone

from sqlalchemy import (
    BigInteger,
    Boolean,
    DateTime,
    Enum,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .db import Base


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


class ClientStatus(str, enum.Enum):
    active = "active"
    disabled = "disabled"
    limited = "limited"
    expired = "expired"


class ResetStrategy(str, enum.Enum):
    no_reset = "no_reset"
    day = "day"
    week = "week"
    month = "month"


class Admin(Base):
    __tablename__ = "admins"

    id: Mapped[int] = mapped_column(primary_key=True)
    username: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    hashed_password: Mapped[str] = mapped_column(String(255))
    is_sudo: Mapped[bool] = mapped_column(Boolean, default=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    last_login_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # Bumped on password change so tokens issued earlier stop validating.
    token_epoch: Mapped[int] = mapped_column(Integer, default=0)

    clients: Mapped[list["Client"]] = relationship(back_populates="admin")


class Client(Base):
    __tablename__ = "clients"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(128), unique=True, index=True)
    admin_id: Mapped[int | None] = mapped_column(ForeignKey("admins.id", ondelete="SET NULL"))

    private_key: Mapped[str | None] = mapped_column(String(64), nullable=True)
    public_key: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    preshared_key: Mapped[str | None] = mapped_column(String(64), nullable=True)
    address: Mapped[str] = mapped_column(String(64), unique=True)

    enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    status: Mapped[ClientStatus] = mapped_column(
        Enum(ClientStatus, name="client_status"), default=ClientStatus.active, index=True
    )

    data_limit: Mapped[int] = mapped_column(BigInteger, default=0)
    reset_strategy: Mapped[ResetStrategy] = mapped_column(
        Enum(ResetStrategy, name="reset_strategy"), default=ResetStrategy.no_reset
    )
    used_up: Mapped[int] = mapped_column(BigInteger, default=0)
    used_down: Mapped[int] = mapped_column(BigInteger, default=0)
    lifetime_up: Mapped[int] = mapped_column(BigInteger, default=0)
    lifetime_down: Mapped[int] = mapped_column(BigInteger, default=0)

    # Raw device counters from the previous poll, used to compute deltas.
    counter_rx: Mapped[int] = mapped_column(BigInteger, default=0)
    counter_tx: Mapped[int] = mapped_column(BigInteger, default=0)

    expire_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    last_handshake_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    last_endpoint: Mapped[str | None] = mapped_column(String(64), nullable=True)
    online_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    traffic_reset_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    sub_token: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    note: Mapped[str | None] = mapped_column(Text, nullable=True)

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow
    )

    admin: Mapped[Admin | None] = relationship(back_populates="clients")
    usages: Mapped[list["ClientUsage"]] = relationship(
        back_populates="client", cascade="all, delete-orphan"
    )

    @property
    def used_total(self) -> int:
        # Column defaults are applied on INSERT, so a freshly constructed instance
        # still has None here.
        return (self.used_up or 0) + (self.used_down or 0)

    @property
    def is_online(self) -> bool:
        return self.online_at is not None


class ClientUsage(Base):
    __tablename__ = "client_usages"
    __table_args__ = (
        UniqueConstraint("client_id", "bucket", name="uq_client_usage_bucket"),
        Index("ix_client_usage_bucket", "bucket"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    client_id: Mapped[int] = mapped_column(ForeignKey("clients.id", ondelete="CASCADE"), index=True)
    bucket: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    up: Mapped[int] = mapped_column(BigInteger, default=0)
    down: Mapped[int] = mapped_column(BigInteger, default=0)

    client: Mapped[Client] = relationship(back_populates="usages")


class NodeUsage(Base):
    __tablename__ = "node_usages"
    __table_args__ = (UniqueConstraint("bucket", "iface", name="uq_node_usage_bucket"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    bucket: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    iface: Mapped[str] = mapped_column(String(32), default="awg0")
    up: Mapped[int] = mapped_column(BigInteger, default=0)
    down: Mapped[int] = mapped_column(BigInteger, default=0)


class Setting(Base):
    __tablename__ = "settings"

    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    value: Mapped[str] = mapped_column(Text)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow, server_default=func.now()
    )
