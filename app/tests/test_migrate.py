def test_migrate_is_idempotent_and_bootstraps_users(app, monkeypatch, caplog):
    """The initContainer entrypoint: safe to run again on every pod start."""
    from sqlalchemy import select

    from opsdesk import migrate
    from opsdesk.db import session_factory
    from opsdesk.models import User

    monkeypatch.setenv("OPSDESK_BOOTSTRAP_USERS", "erin:approver:erin-key")
    migrate.main()
    migrate.main()
    with session_factory()() as s:
        assert s.scalar(select(User.role).where(User.name == "erin")) == "approver"
