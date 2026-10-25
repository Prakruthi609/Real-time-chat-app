# Real-Time Chat App

Flutter (Riverpod) client + FastAPI WebSocket backend with JWT auth, SQL storage and optional Redis pub/sub.

- **Backend:** FastAPI, WebSockets, JWT, SQLAlchemy (SQLite locally, PostgreSQL in Docker), Redis fan-out + presence when `REDIS_URL` is set
- **Client:** Flutter, Riverpod, loading / empty / error / retry states, reconnect banner
- **Tests/CI:** pytest (API + WebSocket), Flutter widget test, GitHub Actions

## Run backend
    cd backend && pip install -r requirements.txt
    uvicorn app.main:app --reload
    pytest -q

Or everything with Postgres + Redis: `docker compose up --build`

## Run Flutter app
    cd flutter_app
    flutter create . --project-name chat_app   # generates android/ios/web folders
    git checkout lib test pubspec.yaml          # restore if flutter create overwrote them
    flutter run --dart-define=API_URL=http://10.0.2.2:8000   # Android emulator

## Design notes
- Passwords: PBKDF2-SHA256 with per-user salt. Tokens: HS256 JWT, 12h expiry.
- Messages are saved before broadcast so history survives restarts; the client de-duplicates history and live messages by id.
- Known limits: no refresh tokens, no rate limiting, single global room. Next steps: rooms, rate limiting, read receipts.