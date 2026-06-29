import { useState } from 'react'
import { Icon } from './Icon'

type HealthState =
  | { status: 'idle'; message: string }
  | { status: 'loading'; message: string }
  | { status: 'success'; message: string }
  | { status: 'error'; message: string }

export function CtaSection() {
  const [health, setHealth] = useState<HealthState>({
    status: 'idle',
    message: 'Backend status has not been checked yet.',
  })

  async function checkHealth() {
    setHealth({ status: 'loading', message: 'Checking backend health...' })

    try {
      const response = await fetch('/api/health')

      if (!response.ok) {
        throw new Error(`Health check failed with ${response.status}`)
      }

      const data = (await response.json()) as {
        status?: string
        service?: string
        timestamp?: string
      }

      setHealth({
        status: 'success',
        message: `${data.service ?? 'Backend'} is ${data.status ?? 'available'} at ${
          data.timestamp ?? 'the latest check'
        }.`,
      })
    } catch (error) {
      setHealth({
        status: 'error',
        message: error instanceof Error ? error.message : 'Unable to reach the backend.',
      })
    }
  }

  return (
    <section className="mx-auto max-w-7xl px-5 py-20 sm:px-8 lg:px-10">
      <div className="rounded-2xl bg-ink px-6 py-10 text-white shadow-2xl shadow-slate-300 sm:px-10 lg:flex lg:items-center lg:justify-between lg:gap-10">
        <div className="max-w-2xl">
          <p className="text-sm font-extrabold uppercase tracking-[0.14em] text-teal-200">
            Ready for milestone 1
          </p>
          <h2 className="mt-3 text-3xl font-extrabold leading-tight sm:text-4xl">
            Start with a frontend that already feels production-minded.
          </h2>
          <p className="mt-4 leading-7 text-slate-300">
            The next layer can connect the Node API, Docker Compose, and EC2 deployment flow
            without redesigning the first impression.
          </p>
        </div>
        <div className="mt-8 w-full max-w-sm lg:mt-0">
          <button
            type="button"
            onClick={checkHealth}
            disabled={health.status === 'loading'}
            className="inline-flex w-full items-center justify-center gap-2 rounded-lg bg-white px-5 py-3 text-sm font-extrabold text-ink transition hover:bg-slate-100 disabled:cursor-wait disabled:opacity-70"
          >
            <Icon name="activity" className="h-4 w-4" />
            {health.status === 'loading' ? 'Checking API...' : 'Check API health'}
          </button>
          <p
            className={`mt-3 rounded-lg border px-4 py-3 text-sm leading-6 ${
              health.status === 'success'
                ? 'border-teal-300 bg-teal-400/10 text-teal-100'
                : health.status === 'error'
                  ? 'border-red-300 bg-red-400/10 text-red-100'
                  : 'border-white/15 bg-white/5 text-slate-300'
            }`}
          >
            {health.message}
          </p>
          <a
            href="#"
            className="mt-4 inline-flex items-center justify-center gap-2 text-sm font-extrabold text-slate-200 transition hover:text-white"
          >
            Back to top
            <Icon name="arrow-right" className="h-4 w-4" />
          </a>
        </div>
      </div>
    </section>
  )
}
