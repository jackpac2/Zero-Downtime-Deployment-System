import { trustSignals } from '../data/landingData'
import { Icon } from './Icon'

const releaseSteps = [
  { name: 'Build image', detail: '12s', color: 'bg-cyan' },
  { name: 'Health probe', detail: '200 OK', color: 'bg-lime' },
  { name: 'Shift traffic', detail: '100%', color: 'bg-sun' },
]

export function HeroSection() {
  return (
    <section id="pipeline" className="relative isolate overflow-hidden px-5 pb-20 pt-8 sm:px-8 lg:px-10 lg:pb-28 lg:pt-14">
      <div className="pointer-events-none absolute -left-20 top-14 h-64 w-64 rounded-full bg-cyan/50 blur-3xl" />
      <div className="pointer-events-none absolute -right-24 bottom-10 h-80 w-80 rounded-full bg-pop/30 blur-3xl" />
      <div className="pointer-events-none absolute right-[8%] top-5 h-20 w-20 rotate-12 rounded-3xl border-[10px] border-sun" />

      <div className="relative mx-auto grid w-full max-w-7xl items-center gap-14 lg:grid-cols-[1.03fr_0.97fr]">
        <div>
          <div className="mb-7 inline-flex -rotate-2 items-center gap-2 rounded-full border-2 border-night bg-lime px-4 py-2 text-xs font-black uppercase tracking-[0.14em] text-night shadow-[4px_4px_0_#16112b]">
            <span className="h-2.5 w-2.5 animate-pulse rounded-full bg-grape" />
            The release safety studio
          </div>

          <h1 className="max-w-4xl font-display text-[3.6rem] font-black leading-[0.9] tracking-[-0.075em] text-night sm:text-7xl lg:text-[5.8rem]">
            DEPLOY BOLD.
            <span className="mt-2 block text-grape">STAY ONLINE.</span>
          </h1>

          <p className="mt-7 max-w-xl text-lg font-medium leading-8 text-night/70 sm:text-xl">
            A technicolor command center for shipping React and Node releases with health gates,
            instant rollback, and absolutely zero outage drama.
          </p>

          <div className="mt-9 flex flex-col gap-3 sm:flex-row">
            <a
              href="#platform"
              className="inline-flex items-center justify-center gap-2 rounded-full border-2 border-night bg-grape px-6 py-3.5 text-sm font-black text-white shadow-[5px_5px_0_#16112b] transition hover:-translate-y-1 hover:shadow-[7px_7px_0_#16112b]"
            >
              Explore the system
              <Icon name="arrow-right" className="h-4 w-4" />
            </a>
            <a
              href="#status"
              className="inline-flex items-center justify-center gap-2 rounded-full border-2 border-night bg-white px-6 py-3.5 text-sm font-black text-night transition hover:bg-cyan"
            >
              <span className="h-2.5 w-2.5 rounded-full bg-lime ring-2 ring-night" />
              All systems bright
            </a>
          </div>

          <div className="mt-10 flex max-w-2xl flex-wrap gap-2.5">
            {trustSignals.map(({ label, icon }, index) => (
              <span
                key={label}
                className={`inline-flex items-center gap-2 rounded-full border-2 border-night px-3 py-2 text-xs font-black text-night ${
                  index % 3 === 0 ? 'bg-sun' : index % 3 === 1 ? 'bg-white' : 'bg-cyan'
                }`}
              >
                <Icon name={icon} className="h-3.5 w-3.5" />
                {label}
              </span>
            ))}
          </div>
        </div>

        <div className="relative mx-auto w-full max-w-xl lg:rotate-2" aria-label="Deployment pipeline preview">
          <div className="absolute -left-5 -top-5 h-full w-full rounded-[2rem] border-2 border-night bg-pop" />
          <div className="absolute -bottom-5 -right-5 h-full w-full rounded-[2rem] border-2 border-night bg-cyan" />
          <div className="relative overflow-hidden rounded-[2rem] border-2 border-night bg-night p-5 text-white shadow-[10px_10px_0_rgba(22,17,43,0.18)] sm:p-7">
            <div className="flex items-center justify-between border-b border-white/15 pb-5">
              <div className="flex items-center gap-3">
                <div className="flex gap-1.5">
                  <span className="h-3 w-3 rounded-full bg-pop" />
                  <span className="h-3 w-3 rounded-full bg-sun" />
                  <span className="h-3 w-3 rounded-full bg-lime" />
                </div>
                <span className="font-mono text-xs font-bold text-white/55">LIVE_RELEASE.EXE</span>
              </div>
              <span className="rounded-full bg-lime px-3 py-1 text-xs font-black text-night">
                HEALTHY
              </span>
            </div>

            <div className="py-6">
              <p className="font-mono text-xs font-bold uppercase tracking-[0.16em] text-cyan">Production release</p>
              <div className="mt-2 flex items-end justify-between gap-4">
                <p className="font-display text-3xl font-black leading-none tracking-[-0.05em] sm:text-4xl">
                  api-v1.8.0
                </p>
                <p className="font-mono text-xs text-white/50">EC2 / UBUNTU</p>
              </div>
            </div>

            <div className="space-y-3">
              {releaseSteps.map((step, index) => (
                <div key={step.name} className="flex items-center gap-3 rounded-2xl border border-white/15 bg-white/7 p-3.5">
                  <span className={`flex h-10 w-10 items-center justify-center rounded-xl font-black text-night ${step.color}`}>
                    {index + 1}
                  </span>
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center justify-between gap-3">
                      <span className="font-bold">{step.name}</span>
                      <span className="font-mono text-xs text-white/55">{step.detail}</span>
                    </div>
                    <div className="mt-2 h-1.5 overflow-hidden rounded-full bg-white/10">
                      <div className={`h-full rounded-full ${step.color}`} style={{ width: `${82 + index * 9}%` }} />
                    </div>
                  </div>
                  <Icon name="check" className="h-5 w-5 text-lime" />
                </div>
              ))}
            </div>

            <div className="mt-5 grid grid-cols-2 gap-3">
              <div className="rounded-2xl bg-grape p-4">
                <p className="font-mono text-[10px] font-bold uppercase tracking-widest text-white/60">Downtime</p>
                <p className="mt-1 font-display text-3xl font-black">0.00s</p>
              </div>
              <div className="rounded-2xl bg-sun p-4 text-night">
                <p className="font-mono text-[10px] font-bold uppercase tracking-widest text-night/55">Rollback</p>
                <p className="mt-1 font-display text-3xl font-black">ARMED</p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}
