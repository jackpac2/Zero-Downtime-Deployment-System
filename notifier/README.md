# Notifier Service

Small Node.js service for sending deployment notifications to Discord. It exposes a health endpoint and a notification endpoint that can later be called by deployment and rollback scripts.

## Environment

- `DISCORD_WEBHOOK_URL`: Discord webhook URL used to send alerts. If unset, `/notify` returns a skipped response instead of failing.
- `PORT`: Optional service port. Defaults to `4000`.

## Run Locally

```sh
npm install
npm start
```

With a webhook configured:

```sh
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..." npm start
```

## Test Health

```sh
curl http://localhost:4000/health
```

Expected response:

```json
{
  "status": "ok"
}
```

## Test Notify

```sh
curl -X POST http://localhost:4000/notify \
  -H "Content-Type: application/json" \
  -d '{
    "event": "manual_test",
    "status": "info",
    "project": "Zero-Downtime Deployment Challenge",
    "sha": "abc123",
    "appUrl": "http://example.com",
    "message": "Test alert"
  }'
```

If `DISCORD_WEBHOOK_URL` is not configured, the request succeeds with a JSON response showing the notification was skipped.
