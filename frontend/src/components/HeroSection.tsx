import { trustSignals } from '../data/landingData'
import { Icon } from './Icon'

export function HeroSection() {
  return (
    <section className="mx-auto grid w-full max-w-7xl items-center gap-12 px-5 pb-16 pt-10 sm:px-8 lg:grid-cols-[1.02fr_0.98fr] lg:px-10 lg:pb-20 lg:pt-16">
      <div>
        <div className="mb-6 inline-flex items-center gap-2 rounded-lg border border-line bg-white/80 px-3 py-2 text-sm font-bold text-slate-700 shadow-sm">
          <span className="h-2 w-2 rounded-full bg-mint" />
          Blue/Green release command center
        </div>

        <h1 className="max-w-4xl text-5xl font-extrabold leading-[1.03] tracking-normal text-ink sm:text-6xl lg:text-7xl">
          Ship full-stack releases without the outage drama.
        </h1>

        <p className="mt-6 max-w-2xl text-lg leading-8 text-slate-600">
          DeployGuard turns a React and Node deployment into a visible pipeline for Docker,
          EC2, health checks, rollback decisions, and production signals.
        </p>

        <div className="mt-8 flex flex-col gap-3 sm:flex-row text-white">
          <a
            href="#platform"
            className="inline-flex items-center justify-center gap-2 rounded-lg bg-ink px-5 py-3 text-sm font-bold text-white shadow-xl shadow-slate-300 transition hover:bg-slate-800"
          >
            Explore platform
            <Icon name="arrow-right" className="h-4 w-4" />
          </a>
        </div>

        <div className="mt-9 flex flex-wrap gap-3">
          {trustSignals.map(({ label, icon }) => (
            <span
              key={label}
              className="inline-flex items-center gap-2 rounded-lg border border-line bg-white/75 px-3 py-2 text-sm font-semibold text-slate-600"
            >
              <Icon name={icon} className="h-4 w-4 text-action" />
              {label}
            </span>
          ))}
        </div>
      </div>

      <div className="relative" aria-label="Deployment pipeline preview">
        <div className="rounded-[1.5rem] border border-line bg-white p-4 shadow-2xl shadow-slate-200">
          <div className="rounded-2xl bg-ink p-5 text-white">
            <div className="flex items-center justify-between border-b border-white/10 pb-4">
              <div>
                <p className="text-sm font-semibold text-slate-300">Production release</p>
                <p className="mt-1 text-xl font-extrabold">api-v1.8.0 to EC2</p>
              </div>
              <span className="rounded-lg bg-mint/15 px-3 py-1 text-sm font-bold text-teal-200">
                Healthy
              </span>
            </div>

            <div className="mt-5 space-y-3">
              {['Build image', 'Compose up', 'Probe /api/health', 'Promote release'].map(
                (step, index) => (
                  <div
                    key={step}
                    className="flex items-center justify-between rounded-xl bg-white/8 px-4 py-3"
                  >
                    <div className="flex items-center gap-3">
                      <span className="flex h-8 w-8 items-center justify-center rounded-lg bg-white/10 text-sm font-bold">
                        {index + 1}
                      </span>
                      <span className="font-semibold">{step}</span>
                    </div>
                    <Icon name="check" className="h-5 w-5 text-teal-200" />
                  </div>
                ),
              )}
            </div>

            <div className="mt-5 grid gap-3 sm:grid-cols-2">
              <div className="rounded-xl bg-white p-4 text-ink">
                <Icon name="server" className="h-5 w-5 text-action" />
                <p className="mt-3 text-sm font-semibold text-slate-500">Target</p>
                <p className="text-2xl font-extrabold">EC2 Ubuntu</p>
              </div>
              <div className="rounded-xl bg-signal p-4 text-ink">
                <p className="text-sm font-bold">Rollback window</p>
                <p className="mt-2 text-3xl font-extrabold">Ready</p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}
