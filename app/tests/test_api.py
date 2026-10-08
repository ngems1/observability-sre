import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError

CHANGE = {"type": "change_request", "title": "Rotate prod DB credentials", "priority": "high"}
ACCESS = {
    "type": "access_request",
    "title": "Read-only access to prod EKS",
    "access": {
        "resource": "prod-eks",
        "requested_role": "read-only",
        "justification": "on-call week",
        "duration_days": 5,
    },
}


def test_probes(client):
    assert client.get("/healthz").json() == {"status": "ok"}
    r = client.get("/readyz")
    assert r.status_code == 200 and r.json()["database"] is True


def test_auth_required(client):
    assert client.get("/tickets").status_code == 401
    assert client.get("/tickets", headers={"X-API-Key": "nope"}).status_code == 401


def test_create_ticket_auto_assigns_and_enqueues(client, headers, aws):
    r = client.post("/tickets", json=CHANGE, headers=headers("alice"))
    assert r.status_code == 201, r.text
    ticket = r.json()
    assert ticket["status"] == "open"
    assert ticket["assignee_id"] in (2, 4)  # bob or dave (approvers)

    notes = client.get(f"/tickets/{ticket['id']}/notifications", headers=headers("alice")).json()
    assert [n["status"] for n in notes] == ["queued"]

    url = aws.get_queue_url(QueueName="opsdesk-notifications")["QueueUrl"]
    msgs = aws.receive_message(QueueUrl=url, MessageAttributeNames=["All"]).get("Messages", [])
    assert len(msgs) == 1
    assert "traceparent" in msgs[0]["MessageAttributes"]  # trace context crosses the queue


def test_auto_assign_balances_load(client, headers):
    assignees = [client.post("/tickets", json=CHANGE, headers=headers("alice")).json()["assignee_id"] for _ in range(4)]
    assert sorted(assignees) == [2, 2, 4, 4]


def test_access_request_needs_details(client, headers):
    bad = {"type": "access_request", "title": "missing details"}
    assert client.post("/tickets", json=bad, headers=headers("alice")).status_code == 422
    bad2 = {**CHANGE, "access": ACCESS["access"]}
    assert client.post("/tickets", json=bad2, headers=headers("alice")).status_code == 422


def test_status_workflow(client, headers):
    tid = client.post("/tickets", json=CHANGE, headers=headers("alice")).json()["id"]
    # requesters cannot move tickets
    assert (
        client.patch(f"/tickets/{tid}/status", json={"status": "triaged"}, headers=headers("alice")).status_code == 403
    )
    # skipping a step is a 409
    assert (
        client.patch(f"/tickets/{tid}/status", json={"status": "resolved"}, headers=headers("bob")).status_code == 409
    )
    for step in ("triaged", "in_progress", "resolved"):
        r = client.patch(f"/tickets/{tid}/status", json={"status": step}, headers=headers("bob"))
        assert r.status_code == 200, r.text
    body = r.json()
    assert body["triaged_at"] and body["resolved_at"]
    # reopen clears resolved_at
    r = client.patch(f"/tickets/{tid}/status", json={"status": "in_progress"}, headers=headers("bob"))
    assert r.json()["resolved_at"] is None
    for step in ("resolved", "closed"):
        client.patch(f"/tickets/{tid}/status", json={"status": step}, headers=headers("bob"))
    assert client.patch(f"/tickets/{tid}/status", json={"status": "open"}, headers=headers("bob")).status_code == 409

    audit = client.get(f"/tickets/{tid}/audit", headers=headers("carol")).json()
    assert audit[0]["action"] == "created"
    assert [a["new_value"]["status"] for a in audit[1:]] == [
        "triaged",
        "in_progress",
        "resolved",
        "in_progress",
        "resolved",
        "closed",
    ]


def test_access_approval(client, headers):
    tid = client.post("/tickets", json=ACCESS, headers=headers("alice")).json()["id"]
    assert client.post(f"/tickets/{tid}/approve", headers=headers("alice")).status_code == 403  # requester role
    r = client.post(f"/tickets/{tid}/approve", json={"reason": "on-call"}, headers=headers("bob"))
    assert r.status_code == 200, r.text
    ar = r.json()["access_request"]
    assert ar["decision"] == "approved" and ar["approver_id"] == 2 and ar["expires_at"]
    assert client.post(f"/tickets/{tid}/reject", headers=headers("dave")).status_code == 409  # already decided
    detail = client.get(f"/tickets/{tid}", headers=headers("alice")).json()
    assert detail["comments"][0]["body"] == "[approved] on-call"


def test_self_approval_blocked(client, headers):
    tid = client.post("/tickets", json=ACCESS, headers=headers("bob")).json()["id"]
    r = client.post(f"/tickets/{tid}/approve", headers=headers("bob"))
    assert r.status_code == 403 and "self-approval" in r.text
    assert client.post(f"/tickets/{tid}/approve", headers=headers("dave")).status_code == 200


def test_approve_non_access_ticket_conflicts(client, headers):
    tid = client.post("/tickets", json=CHANGE, headers=headers("alice")).json()["id"]
    assert client.post(f"/tickets/{tid}/approve", headers=headers("bob")).status_code == 409


def test_requester_isolation(client, headers):
    tid = client.post("/tickets", json=CHANGE, headers=headers("bob")).json()["id"]
    assert client.get(f"/tickets/{tid}", headers=headers("alice")).status_code == 403
    assert client.get("/tickets", headers=headers("alice")).json() == []
    assert len(client.get("/tickets", headers=headers("carol")).json()) == 1


def test_comments(client, headers):
    tid = client.post("/tickets", json=CHANGE, headers=headers("alice")).json()["id"]
    r = client.post(f"/tickets/{tid}/comments", json={"body": "done in staging"}, headers=headers("bob"))
    assert r.status_code == 201
    assert client.get(f"/tickets/{tid}", headers=headers("alice")).json()["comments"][0]["body"] == "done in staging"


def test_audit_log_is_append_only(client, headers):
    from opsdesk.db import get_engine

    client.post("/tickets", json=CHANGE, headers=headers("alice"))
    with pytest.raises(DBAPIError, match="append-only"):
        with get_engine().begin() as conn:
            conn.execute(text("UPDATE audit_log SET action = 'tampered'"))
    with pytest.raises(DBAPIError, match="append-only"):
        with get_engine().begin() as conn:
            conn.execute(text("DELETE FROM audit_log"))


def test_metrics_exposed(client, headers):
    client.post("/tickets", json=CHANGE, headers=headers("alice"))
    body = client.get("/metrics").text
    assert (
        'http_server_request_duration_seconds_bucket{le="0.5",method="POST",route="/tickets",status_code="201"}' in body
    )
    assert "opsdesk_tickets_created_total" in body
    assert "opsdesk_db_pool_connections" in body


def test_chaos_error_injection(settings, aws):
    from fastapi.testclient import TestClient

    from opsdesk.api.main import create_app

    chaotic = create_app(settings.model_copy(update={"chaos_error_rate": 1.0}))
    c = TestClient(chaotic)
    assert c.get("/tickets").status_code == 500
    assert c.get("/healthz").status_code == 200  # probes are never affected
