import pytest

from app import app as flask_app


@pytest.fixture
def client():
    flask_app.config["TESTING"] = True
    return flask_app.test_client()


def test_health_returns_ok(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.get_json() == {"status": "ok"}


def test_home_returns_message(client):
    response = client.get("/")
    assert response.status_code == 200
    assert "message" in response.get_json()


@pytest.mark.parametrize("path", ["/", "/does-not-exist"])
def test_security_headers_on_every_response(client, path):
    headers = client.get(path).headers
    assert headers["X-Content-Type-Options"] == "nosniff"
    assert "frame-ancestors 'none'" in headers["Content-Security-Policy"]
    assert headers["Cache-Control"] == "no-store"
    assert "Permissions-Policy" in headers
    assert headers["Cross-Origin-Resource-Policy"] == "same-origin"
