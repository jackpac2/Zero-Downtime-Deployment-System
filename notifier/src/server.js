const express = require("express");

const app = express();
const port = process.env.PORT || 4000;

app.use(express.json({ limit: "64kb" }));

app.get("/health", (_req, res) => {
  res.json({ status: "ok" });
});

app.post("/notify", async (req, res, next) => {
  try {
    const payload = req.body;

    if (!payload || Object.keys(payload).length === 0) {
      return res.status(400).json({
        sent: false,
        error: "Request body is required"
      });
    }

    if (!payload.event) {
      return res.status(400).json({
        sent: false,
        error: "event field is required"
      });
    }

    const webhookUrl = process.env.DISCORD_WEBHOOK_URL;

    if (!webhookUrl) {
      return res.json({
        sent: false,
        skipped: true,
        reason: "DISCORD_WEBHOOK_URL is not configured"
      });
    }

    const discordPayload = buildDiscordPayload(payload);
    let response;

    try {
      response = await fetch(webhookUrl, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(discordPayload)
      });
    } catch (error) {
      console.error('Discord webhook request failed:', error);

      return res.status(502).json({
        sent: false,
        error: 'Discord webhook request failed'
      });
    }

    if (!response.ok) {
      return res.status(502).json({
        sent: false,
        error: "Discord webhook request failed",
        statusCode: response.status
      });
    }

    return res.json({
      sent: true,
      skipped: false
    });
  } catch (error) {
    return next(error);
  }
});

app.use((err, _req, res, _next) => {
  if (err instanceof SyntaxError && "body" in err) {
    return res.status(400).json({
      sent: false,
      error: "Invalid JSON payload"
    });
  }

  console.error("Unexpected notifier error:", err);

  return res.status(500).json({
    sent: false,
    error: "Unexpected server error"
  });
});

function buildDiscordPayload(payload) {
  const status = payload.status || "info";
  const project = payload.project || "Deployment";
  const title = `${project}: ${status}`;
  const description = payload.message || `Deployment event received: ${payload.event}`;
  const fields = [
    {
      name: "Status",
      value: String(status),
      inline: true
    },
    {
      name: "Event",
      value: String(payload.event),
      inline: true
    }
  ];

  if (payload.sha) {
    fields.push({
      name: "SHA",
      value: String(payload.sha),
      inline: true
    });
  }

  if (payload.appUrl) {
    fields.push({
      name: "App URL",
      value: String(payload.appUrl),
      inline: false
    });
  }

  return {
    embeds: [
      {
        title,
        description,
        color: statusColor(status),
        fields,
        timestamp: new Date().toISOString()
      }
    ]
  };
}

function statusColor(status) {
  switch (String(status).toLowerCase()) {
    case "success":
      return 0x2ecc71;
    case "warning":
      return 0xf1c40f;
    case "error":
    case "failed":
    case "failure":
      return 0xe74c3c;
    default:
      return 0x3498db;
  }
}

app.listen(port, () => {
  console.log(`Notifier listening on port ${port}`);
});
