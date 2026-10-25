import os

os.environ["DATABASE_URL"] = "sqlite:///./test_chat.db"
os.environ.pop("REDIS_URL", None)

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.main import Base, app, engine


@pytest.fixture()
def client():
    Base.metadata.drop_all(engine)
    with TestClient(app) as c:
        yield c


def signup(c, name="alice", pw="secret1"):
    assert c.post("/register", json={"username": name, "password": pw}).status_code == 201
    r = c.post("/login", data={"username": name, "password": pw})
    return r.json()["access_token"]


def test_duplicate_register_rejected(client):
    signup(client)
    assert client.post("/register", json={"username": "alice", "password": "secret1"}).status_code == 409


def test_bad_login_rejected(client):
    signup(client)
    assert client.post("/login", data={"username": "alice", "password": "wrong"}).status_code == 401


def test_history_requires_token(client):
    assert client.get("/messages").status_code == 401


def test_ws_rejects_bad_token(client):
    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect("/ws?token=nope"):
            pass


def test_message_broadcast_and_persisted(client):
    token = signup(client)
    with client.websocket_connect(f"/ws?token={token}") as ws:
        assert ws.receive_json()["type"] == "presence"
        ws.send_text("hello")
        msg = ws.receive_json()
        assert (msg["type"], msg["sender"], msg["text"]) == ("message", "alice", "hello")
    rows = client.get("/messages", headers={"Authorization": f"Bearer {token}"}).json()
    assert [m["text"] for m in rows] == ["hello"]