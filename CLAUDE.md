# CLAUDE.md

## Project Overview

BlinkPay Flutter Mobile App Demo — demonstrates BlinkPay payment gateway integration from a Flutter mobile app using a **backend proxy server** architecture. The app lets users add items to a shopping cart and pay via BlinkPay's gateway flow (single payments and enduring consents).

## Architecture

```
Flutter App  ──HTTP──>  Dart Shelf Proxy Server  ──HTTPS──>  BlinkPay Sandbox API
(no secrets)            (server/, holds secrets)
```

- The Flutter app **never** holds BlinkPay `client_id` or `client_secret`
- All BlinkPay API calls are proxied through the Dart Shelf server in `server/`
- App authenticates to the proxy via a static API key (demo-level; production should use OAuth2/JWT)
- The proxy manages OAuth2 `client_credentials` token exchange with BlinkPay internally
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
| `lib/widgets/` | UI components (product card, payment buttons, status indicator, loading overlay) |
| `lib/utils/` | Logging and error helpers |
| `server/bin/server.dart` | Server entry point |
| `server/lib/src/blinkpay_client.dart` | Server-side BlinkPay API client with OAuth2 token management |
| `server/lib/src/config.dart` | Server configuration from .env |
| `server/lib/src/middleware/auth_middleware.dart` | API key validation middleware |
| `server/lib/src/routes/consent_routes.dart` | Consent proxy endpoints |
| `server/lib/src/routes/payment_routes.dart` | Payment proxy endpoint |

## Proxy Endpoints

All proxy routes are mounted under `/api/payments/v1/` on the server:

| Method | Path | Proxies to BlinkPay |
|--------|------|-------------------|
| POST | `/api/payments/v1/single-consents` | Create single consent |
| GET | `/api/payments/v1/single-consents/<id>` | Get consent status |
| DELETE | `/api/payments/v1/single-consents/<id>` | Revoke consent |
| POST | `/api/payments/v1/enduring-consents` | Create enduring consent |
| GET | `/api/payments/v1/enduring-consents/<id>` | Get enduring consent status |
| DELETE | `/api/payments/v1/enduring-consents/<id>` | Revoke enduring consent |
| POST | `/api/payments/v1/payments` | Create payment |

## Security Notes

- Server binds `0.0.0.0` for LAN access — HTTP only in this demo
- Production must use HTTPS/TLS, proper auth (OAuth2/JWT), rate limiting
- The static API key pattern is demo-level only
- `run.sh` auto-generates the API key if not set

## Testing

```bash
# Server standalone
cd server && dart run bin/server.dart

# Create consent (requires API key)
curl -X POST -H "Authorization: Bearer <key>" -H "Content-Type: application/json" \
  -d '{"flow":{"detail":{"type":"gateway","redirect_uri":"blinkpaydemo://callback"}},"pcr":{"particulars":"Test"},"amount":{"total":"1.00","currency":"NZD"}}' \
  http://localhost:4567/api/payments/v1/single-consents

# Static analysis
cd server && dart analyze
cd .. && flutter analyze
```

## Deep Linking

- Custom URL scheme: `blinkpaydemo://callback`
- Deep links go directly from the bank to the app (not through the proxy)
- The `redirect_uri` in consent creation bodies is `blinkpaydemo://callback`
- Native iOS code in `ios/Runner/AppDelegate.swift` auto-dismisses SFSafariViewController on redirect
