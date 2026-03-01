"""Alert packet model and validation."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import hashlib

from .constants import ALLOWED_SEVERITIES


@dataclass(slots=True)
class AlertPacket:
    alertId: str
    severity: str
    headline: str
    expires: int
    instructions: str
    sourceUrl: str
    verified: bool
    fetchedAt: int

    def validate(self) -> None:
        if self.severity not in ALLOWED_SEVERITIES:
            raise ValueError(
                f"Invalid severity '{self.severity}'. Must be one of: {', '.join(ALLOWED_SEVERITIES)}"
            )
        if not self.headline.strip():
            raise ValueError("headline must not be empty")
        if not self.instructions.strip():
            raise ValueError("instructions must not be empty")
        if not self.sourceUrl.strip():
            raise ValueError("sourceUrl must not be empty")
        if self.expires <= 0:
            raise ValueError("expires must be a positive unix timestamp")
        if self.fetchedAt <= 0:
            raise ValueError("fetchedAt must be a positive unix timestamp")

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, payload: dict) -> "AlertPacket":
        required = {
            "alertId",
            "severity",
            "headline",
            "expires",
            "instructions",
            "sourceUrl",
            "verified",
            "fetchedAt",
        }
        missing = required - set(payload.keys())
        if missing:
            raise ValueError(f"Missing required fields: {', '.join(sorted(missing))}")
        packet = cls(
            alertId=str(payload["alertId"]),
            severity=str(payload["severity"]),
            headline=str(payload["headline"]),
            expires=int(payload["expires"]),
            instructions=str(payload["instructions"]),
            sourceUrl=str(payload["sourceUrl"]),
            verified=bool(payload["verified"]),
            fetchedAt=int(payload["fetchedAt"]),
        )
        packet.validate()
        return packet


def now_epoch() -> int:
    return int(datetime.now(tz=timezone.utc).timestamp())


def parse_epoch(value: str) -> int:
    """Accept unix seconds or ISO8601 strings."""

    try:
        return int(value)
    except ValueError:
        pass

    iso = value.replace("Z", "+00:00")
    dt = datetime.fromisoformat(iso)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp())


def generate_alert_id(headline: str, expires: int) -> str:
    # Match Android parser convention: sha1("$headline$expires").take(8)
    src = f"{headline}{expires}".encode("utf-8")
    return hashlib.sha1(src).hexdigest()[:8]


def build_alert(
    *,
    headline: str,
    severity: str,
    expires: int,
    instructions: str,
    source_url: str,
    verified: bool,
    alert_id: str | None = None,
    fetched_at: int | None = None,
) -> AlertPacket:
    fetched = fetched_at if fetched_at is not None else now_epoch()
    aid = alert_id if alert_id else generate_alert_id(headline, expires)
    packet = AlertPacket(
        alertId=aid,
        severity=severity,
        headline=headline,
        expires=expires,
        instructions=instructions,
        sourceUrl=source_url,
        verified=verified,
        fetchedAt=fetched,
    )
    packet.validate()
    return packet
