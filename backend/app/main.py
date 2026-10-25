"""Real-time chat API: FastAPI + WebSockets + JWT + SQL (+ optional Redis pub/sub)."""
import asyncio, hashlib, hmac, json, os, secrets
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import Depends, FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from pydantic import BaseModel, Field
from sqlalchemy import DateTime, String, Text, create_engine, select
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column, sessionmaker

DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./chat.db")
SECRET = os.getenv("JWT_SECRET", "dev-only-change-me")
engine = create_engine(DATABASE_URL, connect_args={"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {})
SessionLocal = sessionmaker(engine, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


class User(Base):
    __tablename__ = "users"
    id: Mapped[int] = mapped_column(primary_key=True)
    username: Mapped[str] = mapped_column(String(32), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(200))


class Message(Base):
    __tablename__ = "messages"
    id: Mapped[int] = mapped_column(primary_key=True)
    sender: Mapped[str] = mapped_column(String(32))
    text: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=lambda: datetime.now(timezone.utc))


def hash_pw(pw: str) -> str:
    salt = secrets.token_hex(16)
    return f"{salt}${hashlib.pbkdf2_hmac('sha256', pw.encode(), salt.encode(), 200_000).hex()}"


def check_pw(pw: str, stored: str) -> bool:
    salt, digest = stored.split("$")
    return hmac.compare_digest(hashlib.pbkdf2_hmac("sha256", pw.encode(), salt.encode(), 200_000).hex(), digest)


def make_token(username: str) -> str:
    return jwt.encode({"sub": username, "exp": datetime.now(timezone.utc) + timedelta(hours=12)}, SECRET, "HS256")


def read_token(token: str) -> str | None:
    try:
        return jwt.decode(token, SECRET, algorithms=["HS256"])["sub"]
    except jwt.PyJWTError:
        return None


class Hub:
    """Tracks sockets. With REDIS_URL set, fan-out and presence go through Redis so multiple API instances share a chat."""

    def __init__(self):
        self.conns: dict[WebSocket, str] = {}
        self.redis = None
        self.task = None

    async def start(self):
        if url := os.getenv("REDIS_URL"):
            import redis.asyncio as aioredis
            self.redis = aioredis.from_url(url, decode_responses=True)
            self.task = asyncio.create_task(self._listen())

    async def stop(self):
        if self.task:
            self.task.cancel()
        if self.redis:
            await self.redis.aclose()

    async def _listen(self):
        pubsub = self.redis.pubsub()
        await pubsub.subscribe("chat")
        async for m in pubsub.listen():
            if m["type"] == "message":
                await self._local(m["data"])

    async def _local(self, data: str):
        for ws in list(self.conns):
            try:
                await ws.send_text(data)
            except Exception:
                self.conns.pop(ws, None)

    async def emit(self, payload: dict):
        data = json.dumps(payload)
        await (self.redis.publish("chat", data) if self.redis else self._local(data))

    async def online(self) -> list[str]:
        return sorted(await self.redis.smembers("online")) if self.redis else sorted(set(self.conns.values()))

    async def join(self, ws: WebSocket, user: str):
        self.conns[ws] = user
        if self.redis:
            await self.redis.sadd("online", user)
        await self.emit({"type": "presence", "users": await self.online()})

    async def leave(self, ws: WebSocket):
        user = self.conns.pop(ws, None)
        if self.redis and user and user not in self.conns.values():
            await self.redis.srem("online", user)
        await self.emit({"type": "presence", "users": await self.online()})


hub = Hub()


@asynccontextmanager
async def lifespan(_: FastAPI):
    Base.metadata.create_all(engine)
    await hub.start()
    yield
    await hub.stop()


app = FastAPI(title="Realtime Chat API", lifespan=lifespan)
oauth2 = OAuth2PasswordBearer(tokenUrl="login")


def get_db():
    with SessionLocal() as db:
        yield db


def current_user(token: str = Depends(oauth2)) -> str:
    if not (user := read_token(token)):
        raise HTTPException(401, "Invalid or expired token")
    return user


class Credentials(BaseModel):
    username: str = Field(min_length=3, max_length=32, pattern=r"^[A-Za-z0-9_]+$")
    password: str = Field(min_length=6, max_length=128)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/register", status_code=201)
def register(body: Credentials, db: Session = Depends(get_db)):
    if db.scalar(select(User).where(User.username == body.username)):
        raise HTTPException(409, "Username already taken")
    db.add(User(username=body.username, password_hash=hash_pw(body.password)))
    db.commit()
    return {"username": body.username}


@app.post("/login")
def login(form: OAuth2PasswordRequestForm = Depends(), db: Session = Depends(get_db)):
    user = db.scalar(select(User).where(User.username == form.username))
    if not user or not check_pw(form.password, user.password_hash):
        raise HTTPException(401, "Invalid username or password")
    return {"access_token": make_token(user.username), "token_type": "bearer"}


@app.get("/messages")
def history(limit: int = 50, user: str = Depends(current_user), db: Session = Depends(get_db)):
    rows = db.scalars(select(Message).order_by(Message.id.desc()).limit(min(limit, 200))).all()
    return [{"id": m.id, "sender": m.sender, "text": m.text, "created_at": m.created_at.isoformat()} for m in reversed(rows)]


@app.websocket("/ws")
async def chat(ws: WebSocket, token: str = ""):
    user = read_token(token)
    if not user:
        await ws.close(code=1008)
        return
    await ws.accept()
    await hub.join(ws, user)
    try:
        while True:
            text = (await ws.receive_text()).strip()
            if not text or len(text) > 1000:
                continue
            with SessionLocal() as db:
                msg = Message(sender=user, text=text)
                db.add(msg)
                db.commit()
            await hub.emit({"type": "message", "id": msg.id, "sender": user, "text": text, "created_at": msg.created_at.isoformat()})
    except WebSocketDisconnect:
        pass
    finally:
        await hub.leave(ws)