"""API features added for the web UI: teams, OPS keys, SLA, views, assignment, /me, /users, /config, static UI."""

from datetime import UTC, datetime, timedelta

from sqlalchemy import text

CHANGE = {"type": "change_request", "title": "Upgrade ingress controller", "priority": "high", "team": "network_ops"}
ACCESS = {
    "type": "access_request",
    "title": "Access to prod RDS",
    "team": "database",
    "access": {"resource": "prod-rds", "requested_role": "read-only", "justification": "query tuning"},
}


def test_ticket_has_key_team_names_sla_and_next_statuses(client, headers):
    t = client.post("/tickets", json=CHANGE, headers=headers("alice")).json()
    assert t["key"] == f"OPS-{t['id']}"
    assert t["team"] == "network_ops"
    assert t["requester_name"] == "alice"
    assert t["assignee_name"] in ("bob", "dave")
    assert t["sla"]["state"] == "on_track" and 100 <= t["sla"]["minutes_left"] <= 120  # high = 2 h
    assert t["next_statuses"] == ["triaged"]


def test_invalid_team_rejected(client, headers):
    assert client.post("/tickets", json={**CHANGE, "team": "finance"}, headers=headers("alice")).status_code == 422


def test_sla_states(app):
    from opsdesk.models import triage_sla

    now = datetime.now(UTC)
    assert triage_sla("critical", now - timedelta(minutes=40), None, "open", now)["state"] == "breached"
    assert triage_sla("critical", now - timedelta(minutes=25), None, "open", now)["state"] == "due_soon"
    assert triage_sla("low", now, None, "open", now)["state"] == "on_track"
    late = triage_sla("critical", now - timedelta(hours=2), now - timedelta(minutes=10), "triaged", now)
    assert late["state"] == "breached" and late["minutes_left"] is None
    assert triage_sla("low", now - timedelta(hours=1), now, "triaged", now)["state"] == "met"


def test_views_and_summary(client, headers):
    client.post("/tickets", json=CHANGE, headers=headers("alice"))
    client.post("/tickets", json=ACCESS, headers=headers("alice"))
    bobs = client.post("/tickets", json=CHANGE, headers=headers("bob")).json()
    client.patch(f"/tickets/{bobs['id']}/status", json={"status": "triaged"}, headers=headers("dave"))
    # make one ticket breach its triage SLA by back-dating it
    from opsdesk.db import get_engine

    with get_engine().begin() as conn:
        conn.execute(text("UPDATE tickets SET created_at = now() - interval '3 hours' WHERE id = 1"))

    s = client.get("/tickets/summary", headers=headers("carol")).json()
    assert s == {"mine": 0, "pending_approval": 1, "open": 3, "breached": 1, "all": 3}
    assert client.get("/tickets/summary", headers=headers("alice")).json()["all"] == 2  # requesters see their own

    keys = lambda view, who="carol": [t["id"] for t in client.get(f"/tickets?view={view}", headers=headers(who)).json()]  # noqa: E731
    assert keys("breached") == [1]
    assert keys("pending_approval") == [2]
    assert set(keys("mine", "bob")) >= {bobs["id"]}
    assert client.get("/tickets?view=bogus", headers=headers("carol")).status_code == 422


def test_filters(client, headers):
    client.post("/tickets", json=CHANGE, headers=headers("alice"))
    client.post("/tickets", json=ACCESS, headers=headers("alice"))
    assert len(client.get("/tickets?team=database", headers=headers("bob")).json()) == 1
    assert len(client.get("/tickets?priority=high", headers=headers("bob")).json()) == 1
    assert [t["title"] for t in client.get("/tickets?q=ingress", headers=headers("bob")).json()] == [CHANGE["title"]]


def test_assignment(client, headers):
    t = client.post("/tickets", json=CHANGE, headers=headers("alice")).json()
    assert (
        client.patch(f"/tickets/{t['id']}/assignee", json={"assignee_id": 3}, headers=headers("alice")).status_code
        == 403
    )
    assert (
        client.patch(f"/tickets/{t['id']}/assignee", json={"assignee_id": 1}, headers=headers("bob")).status_code == 422
    )
    r = client.patch(f"/tickets/{t['id']}/assignee", json={"assignee_id": 3}, headers=headers("bob"))
    assert r.status_code == 200 and r.json()["assignee_name"] == "carol"
    audit = client.get(f"/tickets/{t['id']}/audit", headers=headers("carol")).json()
    assert audit[-1]["action"] == "assigned" and audit[-1]["actor_name"] == "bob"
    assert (
        client.patch(f"/tickets/{t['id']}/assignee", json={"assignee_id": None}, headers=headers("bob")).json()[
            "assignee_id"
        ]
        is None
    )


def test_triage_sla_metric(client, headers):
    t = client.post("/tickets", json=CHANGE, headers=headers("alice")).json()
    client.patch(f"/tickets/{t['id']}/status", json={"status": "triaged"}, headers=headers("bob"))
    body = client.get("/metrics").text
    assert 'opsdesk_triage_sla_total{priority="high",result="met"}' in body
    assert "opsdesk_time_to_triage_seconds_bucket" in body


def test_me_users_comments_names(client, headers):
    assert client.get("/me", headers=headers("bob")).json() == {"id": 2, "name": "bob", "role": "approver"}
    approvers = client.get("/users?role=approver", headers=headers("alice")).json()
    assert [u["name"] for u in approvers] == ["bob", "dave"]
    t = client.post("/tickets", json=CHANGE, headers=headers("alice")).json()
    client.post(f"/tickets/{t['id']}/comments", json={"body": "on it"}, headers=headers("bob"))
    assert client.get(f"/tickets/{t['id']}", headers=headers("alice")).json()["comments"][0]["author_name"] == "bob"


def test_config_exposes_demo_users_only_locally(settings, aws):
    from fastapi.testclient import TestClient

    from opsdesk.api.main import create_app

    users = "alice:requester:k1,bob:approver:k2"
    local = TestClient(create_app(settings.model_copy(update={"environment": "local", "bootstrap_users": users})))
    cfg = local.get("/config").json()
    assert [u["name"] for u in cfg["demo_users"]] == ["alice", "bob"]
    eks = TestClient(create_app(settings.model_copy(update={"environment": "eks", "bootstrap_users": users})))
    assert eks.get("/config").json()["demo_users"] == []


def test_ui_is_served_with_security_headers(client):
    r = client.get("/", follow_redirects=False)
    assert r.status_code in (302, 307) and r.headers["location"] == "/ui/"
    page = client.get("/ui/")
    assert page.status_code == 200 and "<title>OpsDesk</title>" in page.text
    csp = page.headers["content-security-policy"]
    assert "script-src 'self'" in csp and "frame-ancestors 'none'" in csp
    assert client.get("/ui/app.js").status_code == 200
    assert client.get("/ui/styles.css").status_code == 200
    # API responses do not carry the UI headers
    assert "content-security-policy" not in client.get("/healthz").headers


def test_browser_traceparent_is_honoured(client, headers):
    """A trace id generated in the browser becomes the server-side trace id (and lands in the audit log)."""
    trace_id = "4bf92f3577b34da6a3ce929d0e0e4736"
    t = client.post(
        "/tickets",
        json=CHANGE,
        headers={**headers("alice"), "traceparent": f"00-{trace_id}-00f067aa0ba902b7-01"},
    ).json()
    audit = client.get(f"/tickets/{t['id']}/audit", headers=headers("carol")).json()
    assert audit[0]["trace_id"] == trace_id
