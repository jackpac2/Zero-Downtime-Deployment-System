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
    <section className="px-5 pb-24 pt-6 sm:px-8 lg:px-10">
      <div className="relative mx-auto max-w-7xl">
        <div className="absolute -inset-3 rotate-1 rounded-[2.5rem] border-2 border-night bg-cyan" />
        <div className="relative overflow-hidden rounded-[2.5rem] border-2 border-night bg-grape px-6 py-12 text-white shadow-[10px_10px_0_#16112b] sm:px-10 lg:grid lg:grid-cols-[1.2fr_0.8fr] lg:items-center lg:gap-12 lg:px-14 lg:py-16">
          <div className="pointer-events-none absolute -right-16 -top-16 h-52 w-52 rounded-full border-[38px] border-pop/70" />
          <div className="pointer-events-none absolute bottom-5 left-[45%] h-16 w-16 rotate-12 bg-lime/80" />

          <div className="relative max-w-3xl">
            <p className="font-mono text-xs font-bold uppercase tracking-[0.22em] text-lime">Signal check / 03</p>
            <h2 className="mt-4 font-display text-4xl font-black leading-[0.95] tracking-[-0.06em] sm:text-6xl">
              IS YOUR API
              <span className="block text-lime">FEELING ALIVE?</span>
            </h2>
            <p className="mt-5 max-w-2xl text-lg font-medium leading-8 text-white/65">
              Ping the live health endpoint and get an honest answer from the other side of the stack.
            </p>
          </div>

          <div className="relative mt-9 rounded-[1.75rem] border-2 border-white/25 bg-night/35 p-5 backdrop-blur lg:mt-0">
            <div className="mb-4 flex items-center gap-2 font-mono text-xs text-white/55">
              <span className="h-2.5 w-2.5 rounded-full bg-lime" />
              /api/health
            </div>
            <button
              type="button"
              onClick={checkHealth}
              disabled={health.status === 'loading'}
              className="inline-flex w-full items-center justify-center gap-2 rounded-full border-2 border-night bg-lime px-5 py-3.5 text-sm font-black text-night shadow-[4px_4px_0_#16112b] transition hover:-translate-y-0.5 disabled:cursor-wait disabled:opacity-70"
            >
              <Icon name="activity" className="h-4 w-4" />
              {health.status === 'loading' ? 'Pinging the stack...' : 'Run live pulse check'}
            </button>
            <p
              aria-live="polite"
              className={`mt-4 rounded-2xl border px-4 py-3 text-sm font-medium leading-6 ${
                health.status === 'success'
                  ? 'border-lime/50 bg-lime/10 text-lime'
                  : health.status === 'error'
                    ? 'border-pop/60 bg-pop/10 text-pink-100'
                    : 'border-white/15 bg-white/5 text-white/60'
              }`}
            >
              {health.message}
            </p>
            <a href="#" className="mt-4 inline-flex items-center gap-2 text-sm font-black text-white/65 transition hover:text-white">
              Back to launchpad
              <Icon name="arrow-right" className="h-4 w-4 -rotate-90" />
            </a>
          </div>
        </div>
      </div>
    </section>
  )
}
