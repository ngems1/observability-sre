"""Ticket status state machine. Anything not listed here is rejected with HTTP 409."""

ALLOWED_TRANSITIONS: dict[str, set[str]] = {
    "open": {"triaged"},
    "triaged": {"in_progress"},
    "in_progress": {"resolved"},
    "resolved": {"closed", "in_progress"},  # resolved -> in_progress = reopen
    "closed": set(),
}


def can_transition(current: str, target: str) -> bool:
    return target in ALLOWED_TRANSITIONS.get(current, set())
