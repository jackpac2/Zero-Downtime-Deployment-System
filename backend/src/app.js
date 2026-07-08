import express from 'express'

const app = express()
const startedAt = new Date()

app.disable('x-powered-by')
app.use(express.json())

app.use((req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', process.env.CORS_ORIGIN || 'http://localhost:5173')
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type')
  res.setHeader('Access-Control-Allow-Methods', 'GET,OPTIONS')

  if (req.method === 'OPTIONS') {
    res.sendStatus(204)
    return
  }

  next()
})

app.get('/api/health', (_req, res) => {
  res.status(500).json({
    status: 'ok',
    service: 'zero-downtime-backend',
    uptime: Math.round(process.uptime()),
    startedAt: startedAt.toISOString(),
    timestamp: new Date().toISOString(),
  })
})

app.use((_req, res) => {
  res.status(404).json({ error: 'Not found' })
})

export { app }
