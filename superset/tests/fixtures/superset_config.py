"""Private regression config; not a production deployment example."""
from pathlib import Path
import time

SECRET_KEY = "private-regression-only-key-never-for-production"
SQLALCHEMY_DATABASE_URI = "sqlite:////kubedoop/run/superset.db"
WTF_CSRF_ENABLED = True


def _hold_request():
    Path('/kubedoop/run/hold-started').touch()
    time.sleep(2)
    Path('/kubedoop/run/hold-done').touch()
    return 'REQUEST_COMPLETED'


def FLASK_APP_MUTATOR(app):
    app.add_url_rule('/lifecycle/hold', view_func=_hold_request)
