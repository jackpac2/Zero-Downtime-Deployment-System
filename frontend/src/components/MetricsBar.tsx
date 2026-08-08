import { metrics } from '../data/landingData'

const metricStyles = [
  'bg-lime lg:-rotate-1',
  'bg-cyan lg:rotate-1',
  'bg-pop lg:-rotate-1',
  'bg-sun lg:rotate-1',
]

export function MetricsBar() {
  return (
    <section id="status" className="relative z-10 px-5 pb-20 sm:px-8 lg:px-10">
      <div className="mx-auto grid max-w-7xl gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {metrics.map((metric, index) => (
          <article
            key={metric.label}
            className={`rounded-[1.75rem] border-2 border-night p-5 text-night shadow-[6px_6px_0_#16112b] transition hover:-translate-y-1 ${metricStyles[index]}`}
          >
            <p className="font-display text-4xl font-black tracking-[-0.06em]">{metric.value}</p>
            <p className="mt-1 text-xs font-black uppercase tracking-[0.12em] text-night/65">{metric.label}</p>
          </article>
        ))}
      </div>
    </section>
  )
}
