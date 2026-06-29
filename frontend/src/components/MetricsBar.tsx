import { metrics } from '../data/landingData'

export function MetricsBar() {
  return (
    <section id="status" className="border-y border-line bg-white/80">
      <div className="mx-auto grid max-w-7xl gap-4 px-5 py-7 sm:grid-cols-2 sm:px-8 lg:grid-cols-4 lg:px-10">
        {metrics.map((metric) => (
          <div key={metric.label} className="rounded-lg bg-cloud px-5 py-4">
            <p className="text-3xl font-extrabold text-ink">{metric.value}</p>
            <p className="mt-1 text-sm font-semibold text-slate-500">{metric.label}</p>
          </div>
        ))}
      </div>
    </section>
  )
}
