import { features } from '../data/landingData'
import { Icon } from './Icon'

const cardStyles = [
  'bg-lime text-night md:col-span-2',
  'bg-cyan text-night',
  'bg-white text-night',
]

export function FeatureGrid() {
  return (
    <section id="platform" className="relative overflow-hidden bg-night py-24 text-white">
      <div className="pointer-events-none absolute -right-20 top-20 h-72 w-72 rounded-full border-[48px] border-grape/40" />
      <div className="pointer-events-none absolute -left-12 bottom-10 h-40 w-40 rotate-12 bg-pop/20" />

      <div className="relative mx-auto max-w-7xl px-5 sm:px-8 lg:px-10">
        <div className="grid gap-8 lg:grid-cols-[0.8fr_1.2fr] lg:items-end">
          <div>
            <p className="font-mono text-xs font-bold uppercase tracking-[0.22em] text-lime">Inside the machine / 01</p>
            <h2 className="mt-4 font-display text-5xl font-black leading-[0.94] tracking-[-0.065em] sm:text-6xl">
              SERIOUS SYSTEM.
              <span className="block text-pop">LOUD PERSONALITY.</span>
            </h2>
          </div>
          <p className="max-w-2xl text-lg font-medium leading-8 text-white/60 lg:justify-self-end">
            Every release is treated as one connected organism?containers, health, routing,
            rollback, and the signals that tell your team what is really happening.
          </p>
        </div>

        <div className="mt-12 grid gap-5 md:grid-cols-2 lg:grid-cols-3">
          {features.map(({ title, description, icon }, index) => (
            <article
              key={title}
              className={`group min-h-72 rounded-[2rem] border-2 border-white/20 p-6 transition duration-300 hover:-translate-y-2 ${
                cardStyles[index] ?? 'bg-grape text-white md:col-span-2'
              }`}
            >
              <div className="flex items-start justify-between">
                <span className="font-mono text-xs font-black tracking-[0.18em] opacity-55">0{index + 1}</span>
                <span className="flex h-14 w-14 rotate-3 items-center justify-center rounded-2xl border-2 border-current bg-night text-white transition group-hover:-rotate-6">
                  <Icon name={icon} className="h-7 w-7" />
                </span>
              </div>
              <h3 className="mt-12 max-w-md font-display text-3xl font-black leading-none tracking-[-0.045em]">{title}</h3>
              <p className="mt-4 max-w-xl font-medium leading-7 opacity-65">{description}</p>
            </article>
          ))}
        </div>
      </div>
    </section>
  )
}
