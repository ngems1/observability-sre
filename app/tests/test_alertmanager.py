"""Alertmanager webhook -> incident follow-up tickets."""

from datetime import UTC, datetime, timedelta

import pytest
from prometheus_client import REGISTRY

ALERT_TOKEN = "test-alert-token"  # same value as the settings fixture in conftest.py

URL = "/integrations/alertmanager"
AUTH = {"Authorization": f"Bearer {ALERT_TOKEN}"}
T0 = datetime(2026, 10, 8, 12, 0, tzinfo=UTC)


def alert(status="firing", fp="fp-worker-down", severity="critical", team="platform", starts=T0, ends=None, **labels):
    return {
        "status": status,
        "labels": {"alertname": "OpsDeskWorkerDown", "severity": severity, "team": team, **labels},
        "annotations": {
            "summary": "ticket-worker is not being scraped",
            "description": "No healthy ticket-worker target for 2 minutes.",
            "runbook_url": "https://github.com/example/opsdesk/blob/main/docs/runbook.md#worker-down",
        },
        "startsAt": starts.isoformat(),
        "endsAt": (ends or datetime(1, 1, 1, tzinfo=UTC)).isoformat(),
        "generatorURL": "http://prometheus/graph?g0.expr=up",
        "fingerprint": fp,
    }


def payload(*alerts):
    return {"version": "4", "status": alerts[0]["status"], "receiver": "opsdesk", "alerts": list(alerts)}


def metric(result: str) -> float:
    return REGISTRY.get_sample_value("opsdesk_alert_webhook_total", {"result": result}) or 0.0


def test_requires_bearer_token(client):
    assert client.post(URL, json=payload(alert())).status_code == 401
    assert client.post(URL, json=payload(alert()), headers={"Authorization": "Bearer nope"}).status_code == 401
    # an X-API-Key is not accepted here
    assert client.post(URL, json=payload(alert()), headers={"X-API-Key": "carol-key"}).status_code == 401


def test_disabled_without_token(client, app, monkeypatch):
    monkeypatch.setattr(app.state.settings, "alert_webhook_token", None)
    assert client.post(URL, json=payload(alert()), headers=AUTH).status_code == 503


def test_firing_alert_creates_assigned_incident_ticket(client, headers):
    before = metric("created")
    r = client.post(URL, json=payload(alert(team="database")), headers=AUTH)
    assert r.status_code == 200, r.text
    out = r.json()["results"][0]
    assert out["result"] == "created"
    assert metric("created") == before + 1

    t = client.get(f"/tickets/{out['ticket_id']}", headers=headers("carol")).json()
    assert t["type"] == "incident_followup"
    assert t["source"] == "alert"
    assert t["priority"] == "critical"
    assert t["team"] == "database"
    assert t["requester_name"] == "alertmanager"
    assert t["assignee_name"] in {"bob", "dave"}  # auto-assigned like any ticket
    assert t["title"] == "OpsDeskWorkerDown: ticket-worker is not being scraped"
    assert "Runbook: https://github.com/example/opsdesk" in t["description"]
    assert "Suspected layer: not labelled" in t["description"]
    assert t["alert"]["alertname"] == "OpsDeskWorkerDown"
    assert t["alert"]["resolved_at"] is None
    assert t["alert"]["runbook_url"].endswith("#worker-down")

    audit = client.get(f"/tickets/{t['id']}/audit", headers=headers("carol")).json()
    assert audit[0]["action"] == "created" and audit[0]["new_value"]["source"] == "alert"
    notes = client.get(f"/tickets/{t['id']}/notifications", headers=headers("carol")).json()
    assert [n["event"] for n in notes] == ["ticket_created"]


def test_repeat_notifications_are_idempotent(client, headers):
    first = client.post(URL, json=payload(alert()), headers=AUTH).json()["results"][0]
    before = metric("duplicate")
    for _ in range(3):  # repeat_interval re-sends + the second Alertmanager replica
        again = client.post(URL, json=payload(alert()), headers=AUTH).json()["results"][0]
        assert again == {**again, "result": "duplicate", "ticket_id": first["ticket_id"]}
    assert metric("duplicate") == before + 3
    listed = client.get("/tickets", params={"type": "incident_followup"}, headers=headers("carol")).json()
    assert len(listed) == 1


def test_resolved_alert_records_time_to_recover(client, headers):
    tid = client.post(URL, json=payload(alert()), headers=AUTH).json()["results"][0]["ticket_id"]
    count = "opsdesk_incident_time_to_recover_seconds_count"
    labels = {"alertname": "OpsDeskWorkerDown", "severity": "critical"}
    before = REGISTRY.get_sample_value(count, labels) or 0.0

    ends = T0 + timedelta(minutes=7, seconds=30)
    out = client.post(URL, json=payload(alert(status="resolved", ends=ends)), headers=AUTH).json()["results"][0]
    assert out["result"] == "resolved"
    assert out["time_to_recover_s"] == 450
    assert REGISTRY.get_sample_value(count, labels) == before + 1

    t = client.get(f"/tickets/{tid}", headers=headers("carol")).json()
    assert t["status"] == "open"  # the follow-up work is still to do
    assert t["alert"]["time_to_recover_s"] == 450
    assert "recovered after 7m 30s" in t["comments"][-1]["body"]
    assert t["comments"][-1]["author_name"] == "alertmanager"

    # resolved again (HA replica) -> nothing left to resolve
    again = client.post(URL, json=payload(alert(status="resolved", ends=ends)), headers=AUTH).json()
    assert again["results"][0]["result"] == "resolved_unknown"


def test_refire_while_ticket_open_reuses_ticket_then_new_ticket_after_close(client, headers):
    tid = client.post(URL, json=payload(alert()), headers=AUTH).json()["results"][0]["ticket_id"]
    client.post(URL, json=payload(alert(status="resolved", ends=T0 + timedelta(minutes=2))), headers=AUTH)

    # flapping: fires again before anyone closed the ticket -> same ticket, comment + audit
    t1 = T0 + timedelta(minutes=10)
    out = client.post(URL, json=payload(alert(starts=t1)), headers=AUTH).json()["results"][0]
    assert out == {**out, "result": "refired", "ticket_id": tid}
    t = client.get(f"/tickets/{tid}", headers=headers("carol")).json()
    assert t["comments"][-1]["body"].startswith("[alert fired again]")
    assert t["alert"]["started_at"].startswith("2026-10-08T12:10")

    # on-call works the ticket to resolved -> the next firing is a new incident
    for s in ("triaged", "in_progress", "resolved"):
        assert client.patch(f"/tickets/{tid}/status", json={"status": s}, headers=headers("bob")).status_code == 200
    client.post(URL, json=payload(alert(status="resolved", starts=t1, ends=t1 + timedelta(minutes=1))), headers=AUTH)
    out = client.post(URL, json=payload(alert(starts=T0 + timedelta(hours=1))), headers=AUTH).json()["results"][0]
    assert out["result"] == "created" and out["ticket_id"] != tid


def test_layer_label_is_named_in_the_ticket(client, headers):
    body = payload(alert(fp="net-1", alertname="OpsDeskDependencyUnreachable", layer="network", dependency="postgres"))
    tid = client.post(URL, json=body, headers=AUTH).json()["results"][0]["ticket_id"]
    t = client.get(f"/tickets/{tid}", headers=headers("carol")).json()
    assert "Suspected layer: network" in t["description"]
    assert t["alert"]["labels"]["layer"] == "network"


@pytest.mark.parametrize(
    ("severity", "team", "expected"),
    [("warning", "network_ops", ("high", "network_ops")), ("critical", "marketing", ("critical", "platform"))],
)
def test_priority_and_team_mapping(client, headers, severity, team, expected):
    out = client.post(URL, json=payload(alert(severity=severity, team=team)), headers=AUTH).json()["results"][0]
    t = client.get(f"/tickets/{out['ticket_id']}", headers=headers("carol")).json()
    assert (t["priority"], t["team"]) == expected


def test_severity_filter_and_batch(client, headers):
    before = metric("ignored")
    body = payload(alert(fp="a1"), alert(fp="a2", severity="info"), alert(fp="a3", alertname="OpsDeskHighErrorRate"))
    results = client.post(URL, json=body, headers=AUTH).json()["results"]
    assert [r["result"] for r in results] == ["created", "ignored", "created"]
    assert metric("ignored") == before + 1
    assert len(client.get("/tickets", headers=headers("carol")).json()) == 2


def test_requesters_do_not_see_alert_tickets(client, headers):
    client.post(URL, json=payload(alert()), headers=AUTH)
    assert client.get("/tickets", headers=headers("alice")).json() == []
    row = client.get("/tickets", headers=headers("carol")).json()[0]
    assert row["source"] == "alert"


def test_bad_payload_is_rejected(client):
    assert client.post(URL, json={"alerts": [{"status": "firing"}]}, headers=AUTH).status_code == 422
