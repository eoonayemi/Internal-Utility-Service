import pytest
from app import app
from utils import calculate_internal_metric


@pytest.fixture
def client():
    app.config["TESTING"] = True
    return app.test_client()


def test_home_status_code(client):
    res = client.get("/")
    assert res.status_code == 200


def test_home_returns_message(client):
    res = client.get("/")
    data = res.get_json()
    assert data["message"] == "Internal Utility Service Running"


def test_home_has_environment_field(client):
    res = client.get("/")
    data = res.get_json()
    assert "environment" in data


def test_users_status_code(client):
    res = client.get("/users")
    assert res.status_code == 200


def test_users_returns_list(client):
    res = client.get("/users")
    data = res.get_json()
    assert isinstance(data, list)


def test_users_returns_two_users(client):
    res = client.get("/users")
    data = res.get_json()
    assert len(data) == 2


def test_users_first_user_is_alice(client):
    res = client.get("/users")
    data = res.get_json()
    assert data[0]["name"] == "Alice"


def test_calculate_metric_basic(client):
    # Tests the utility function in utils.py
    result = calculate_internal_metric(10, 2)
    assert result == 5.0
