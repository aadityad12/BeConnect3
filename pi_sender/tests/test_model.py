import pytest

from beconnect_pi.model import build_alert, generate_alert_id, now_epoch


def test_generate_alert_id_stable() -> None:
    headline = "Flood warning"
    expires = 1735689600
    assert generate_alert_id(headline, expires) == generate_alert_id(headline, expires)


def test_build_alert_validates_severity() -> None:
    with pytest.raises(ValueError):
        build_alert(
            headline="Bad Severity",
            severity="Critical",
            expires=1735689600,
            instructions="Do something",
            source_url="https://example.com",
            verified=False,
            fetched_at=now_epoch(),
        )


def test_build_alert_sets_generated_id() -> None:
    alert = build_alert(
        headline="Valid Alert",
        severity="Severe",
        expires=1735689600,
        instructions="Take shelter",
        source_url="https://example.com",
        verified=True,
        fetched_at=1735680000,
    )
    assert len(alert.alertId) == 8
