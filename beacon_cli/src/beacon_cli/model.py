"""AlertPacket model — wire-compatible with BeConnect Flutter data model."""

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
            raise ValueError(f"severity must be one of: {', '.join(ALLOWED_SEVERITIES)}")
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
    def from_dict(cls, d: dict) -> AlertPacket:
        required = {"alertId", "severity", "headline", "expires",
                    "instructions", "sourceUrl", "verified", "fetchedAt"}
        missing = required - set(d.keys())
        if missing:
            raise ValueError(f"Missing fields: {', '.join(sorted(missing))}")
        p = cls(
            alertId=str(d["alertId"]),
            severity=str(d["severity"]),
            headline=str(d["headline"]),
            expires=int(d["expires"]),
            instructions=str(d["instructions"]),
            sourceUrl=str(d["sourceUrl"]),
            verified=bool(d["verified"]),
            fetchedAt=int(d["fetchedAt"]),
        )
        p.validate()
        return p


def now_epoch() -> int:
    return int(datetime.now(tz=timezone.utc).timestamp())


def parse_epoch(value: str) -> int:
    """Accept unix seconds (int string) or ISO 8601."""
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
    """SHA-1(headline + expires), first 8 hex chars — matches Flutter parser."""
    src = f"{headline}{expires}".encode()
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
    aid = alert_id or generate_alert_id(headline, expires)
    p = AlertPacket(
        alertId=aid,
        severity=severity,
        headline=headline,
        expires=expires,
        instructions=instructions,
        sourceUrl=source_url,
        verified=verified,
        fetchedAt=fetched,
    )
    p.validate()
    return p
