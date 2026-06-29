import { features } from '../data/landingData'
import { Icon } from './Icon'

export function FeatureGrid() {
  return (
    <section id="platform" className="mx-auto max-w-7xl px-5 py-20 sm:px-8 lg:px-10">
      <div className="max-w-3xl">
        <p className="text-sm font-extrabold uppercase tracking-[0.14em] text-action">Platform</p>
        <h2 className="mt-3 text-4xl font-extrabold leading-tight text-ink sm:text-5xl">
          Built around the deployment problems that usually stay invisible.
        </h2>
        <p className="mt-4 text-lg leading-8 text-slate-600">
          The interface frames every release as a system: containers, health, routing, rollback,
          and the lessons learned when something breaks.
        </p>
      </div>

      <div className="mt-10 grid gap-4 md:grid-cols-2">
        {features.map(({ title, description, icon }) => (
          <article
            key={title}
            className="rounded-xl border border-line bg-white p-6 shadow-sm transition hover:-translate-y-1 hover:shadow-xl hover:shadow-slate-200"
          >
            <div className="flex h-12 w-12 items-center justify-center rounded-lg bg-blue-50 text-action">
              <Icon name={icon} className="h-6 w-6" />
            </div>
            <h3 className="mt-5 text-xl font-extrabold text-ink">{title}</h3>
            <p className="mt-3 leading-7 text-slate-600">{description}</p>
          </article>
        ))}
      </div>
    </section>
  )
}
