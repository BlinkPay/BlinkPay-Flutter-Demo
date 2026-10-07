# CLAUDE.md

## Project Overview

BlinkPay Flutter Mobile App Demo — the published mobile reference implementation for Blink Payments, using a **backend** that holds the credentials and owns the order. The app lets users add items to a shopping cart and pay via the gateway flow (single payments and enduring consents). Developers and their coding agents copy its patterns into React Native, Swift and Kotlin apps, so behaviour must match the Blink Payments docs (README "Outcome Handling" and "Retries and Idempotency").

## Architecture

```
Flutter App  ──HTTP──>  Dart Shelf Backend  ──HTTPS──>  Blink Payments Sandbox API
(no secrets, no prices) (server/: secrets, orders, amounts, PCR, redirect URI)
```

- The Flutter app **never** holds BlinkPay `client_id` or `client_secret`
- All Blink Payments calls go through the server in `server/`, which builds every consent and payment body itself; the app sends only a quantity and the consent type
- App authenticates to the proxy via a static API key (demo-level; production should use OAuth2/JWT)
- The server manages the OAuth2 `client_credentials` token exchange with Blink Payments
- Deep links (`blinkpaydemo://callback`) go directly from the bank to the app — not through the proxy

## Key Directories

- `lib/` — Flutter app source (Dart)
- `server/` — Dart Shelf proxy server (separate Dart project with its own `pubspec.yaml`)
- `server/.env` — **Server secrets** (BlinkPay credentials + API key). Git-ignored.
- `run.sh` — Helper script to start both server and app

## Running

```bash
# Quick start
cp server/.env.example server/.env   # Fill in BlinkPay credentials
./run.sh                              # Interactive prompt — picks device type, starts everything
./run.sh --simulator                  # Skip prompt: iOS simulator
./run.sh --emulator                   # Skip prompt: Android emulator
./run.sh --lan                        # Skip prompt: physical device (auto-detect LAN IP)
```

Or manually:
```bash
cd server && dart run bin/server.dart     # Terminal 1
flutter run --dart-define=BACKEND_URL=http://10.0.2.2:4567 --dart-define=APP_API_KEY=<key>  # Terminal 2
```

## Configuration

- **Server config**: `server/.env` (BlinkPay credentials, APP_API_KEY, port)
- **App config**: via `--dart-define` flags at build time (BACKEND_URL, APP_API_KEY)
- **No `.env` file is bundled into the app binary** — `flutter_dotenv` has been removed

## Key Files

| File | Purpose |
|------|---------|
| `lib/main.dart` | App entry point and main UI |
| `lib/blinkpay_service.dart` | HTTP client — calls proxy server (NOT BlinkPay directly) |
| `lib/env.dart` | App config from `String.fromEnvironment` / `--dart-define` |
| `lib/managers/payment_manager.dart` | Payment flow state machine |
| `lib/handlers/deep_link_handler.dart` | Deep link callback handler |
| `lib/models/shopping_cart_model.dart` | Shopping cart state |
| `lib/widgets/` | UI components (product card, payment buttons, payment status panel, loading overlay) |
| `lib/utils/` | Logging and error helpers |
| `server/bin/server.dart` | Server entry point |
| `server/lib/src/blinkpay_client.dart` | Server-side BlinkPay API client with OAuth2 token management |
| `server/lib/src/config.dart` | Server configuration from .env |
| `server/lib/src/middleware/auth_middleware.dart` | API key validation middleware |
| `server/lib/src/orders.dart` | In-memory orders, pricing and PCR |
| `server/lib/src/routes/order_routes.dart` | Order, consent and payment endpoints |

## Backend Endpoints

All routes are mounted under `/api/` and need `Authorization: Bearer <APP_API_KEY>`:

| Method | Path | Does |
|--------|------|------|
| POST | `/api/orders` `{"quantity": n}` | Price the cart, create an order |
| POST | `/api/orders/<id>/consent` `{"type": "single"\|"enduring"}` | Create a gateway consent (needs `idempotency-key`) |
| GET | `/api/orders/<id>/consent` | Read the consent |
| DELETE | `/api/orders/<id>/consent` | Revoke the consent |
| POST | `/api/orders/<id>/payments` | Create the payment (needs `idempotency-key`) |
| GET | `/api/orders/<id>/payments/<payment_id>` | Read a payment of this order |

## Security Notes

- Server binds `0.0.0.0` for LAN access — HTTP only in this demo
- Production must use HTTPS/TLS, proper auth (OAuth2/JWT), rate limiting
- The static API key pattern is demo-level only
- `run.sh` auto-generates the API key if not set

## Testing

```bash
flutter test                  # App
cd server && dart test        # Backend

# Create an order, then its consent (requires the API key)
curl -X POST -H "Authorization: Bearer <key>" -H "Content-Type: application/json" \
  -d '{"quantity":2}' http://localhost:4567/api/orders
curl -X POST -H "Authorization: Bearer <key>" -H "Content-Type: application/json" \
  -H "idempotency-key: $(uuidgen)" -d '{"type":"single"}' \
  http://localhost:4567/api/orders/<order_id>/consent

# Static analysis
cd server && dart analyze
cd .. && flutter analyze
```

## Deep Linking

- Custom URL scheme: `blinkpaydemo://callback`
- Deep links go directly from the bank to the app (not through the proxy)
- The server sends `APP_REDIRECT_URI` (default `blinkpaydemo://callback`) as the consent's `redirect_uri`
- Native iOS code in `ios/Runner/AppDelegate.swift` auto-dismisses SFSafariViewController on redirect
