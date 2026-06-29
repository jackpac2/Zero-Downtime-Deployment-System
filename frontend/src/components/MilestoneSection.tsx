import { milestones } from '../data/landingData'

const statusStyles = {
  Live: 'bg-teal-50 text-teal-700 ring-teal-200',
  Next: 'bg-amber-50 text-amber-700 ring-amber-200',
  Planned: 'bg-slate-100 text-slate-600 ring-slate-200',
}

export function MilestoneSection() {
  return (
    <section id="milestones" className="bg-white py-20">
      <div className="mx-auto grid max-w-7xl gap-10 px-5 sm:px-8 lg:grid-cols-[0.85fr_1.15fr] lg:px-10">
        <div>
          <p className="text-sm font-extrabold uppercase tracking-[0.14em] text-mint">Pipeline</p>
          <h2 className="mt-3 text-4xl font-extrabold leading-tight text-ink sm:text-5xl">
            A roadmap that turns deployment failures into operating knowledge.
          </h2>
          <p className="mt-4 text-lg leading-8 text-slate-600">
            Each milestone keeps the product surface focused on the next practical capability,
            from EC2 basics to observable rollback automation.
          </p>
        </div>

        <div className="space-y-4">
          {milestones.map((milestone) => (
            <article key={milestone.label} className="rounded-xl border border-line bg-cloud p-5">
              <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                <div>
                  <p className="text-sm font-bold text-action">{milestone.label}</p>
                  <h3 className="mt-1 text-xl font-extrabold text-ink">{milestone.title}</h3>
                </div>
                <span
                  className={`w-fit rounded-lg px-3 py-1 text-xs font-extrabold ring-1 ${statusStyles[milestone.status]}`}
                >
                  {milestone.status}
                </span>
              </div>
              <p className="mt-3 leading-7 text-slate-600">{milestone.description}</p>
            </article>
          ))}
        </div>
      </div>
    </section>
  )
}
