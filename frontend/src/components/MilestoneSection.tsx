import { milestones } from '../data/landingData'

const statusStyles = {
  Live: 'bg-lime text-night',
  Next: 'bg-sun text-night',
  Planned: 'bg-white text-night',
}

const cardAccents = ['border-lime', 'border-sun', 'border-cyan', 'border-pop']

export function MilestoneSection() {
  return (
    <section id="milestones" className="relative overflow-hidden py-24">
      <div className="dot-grid pointer-events-none absolute inset-0 opacity-35" />
      <div className="relative mx-auto grid max-w-7xl gap-12 px-5 sm:px-8 lg:grid-cols-[0.82fr_1.18fr] lg:px-10">
        <div>
          <div className="lg:sticky lg:top-8">
            <p className="font-mono text-xs font-bold uppercase tracking-[0.22em] text-grape">The flight plan / 02</p>
            <h2 className="mt-4 max-w-xl font-display text-5xl font-black leading-[0.94] tracking-[-0.065em] text-night sm:text-6xl">
              FROM FIRST BOOT TO
              <span className="block text-grape">BULLETPROOF.</span>
            </h2>
            <p className="mt-6 max-w-lg text-lg font-medium leading-8 text-night/65">
              A practical roadmap where every hard deployment lesson becomes the next automatic guardrail.
            </p>
            <div className="mt-8 inline-flex rotate-2 items-center gap-3 rounded-2xl border-2 border-night bg-pop px-4 py-3 text-sm font-black text-night shadow-[5px_5px_0_#16112b]">
              <span className="h-3 w-3 rounded-full bg-night" />
              4 checkpoints in view
            </div>
          </div>
        </div>

        <div className="relative space-y-5 before:absolute before:bottom-8 before:left-6 before:top-8 before:w-1 before:rounded-full before:bg-night/10 sm:before:left-8">
          {milestones.map((milestone, index) => (
            <article
              key={milestone.label}
              className={`relative ml-4 rounded-[2rem] border-2 border-night border-l-[10px] bg-white p-6 shadow-[7px_7px_0_rgba(22,17,43,0.16)] transition hover:translate-x-1 sm:ml-8 ${cardAccents[index]}`}
            >
              <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
                <div className="flex gap-4">
                  <span className="font-display text-4xl font-black leading-none text-night/15">0{index + 1}</span>
                  <div>
                    <p className="font-mono text-xs font-black uppercase tracking-[0.15em] text-grape">{milestone.label}</p>
                    <h3 className="mt-1 font-display text-2xl font-black tracking-[-0.035em] text-night">{milestone.title}</h3>
                  </div>
                </div>
                <span className={`w-fit rounded-full border-2 border-night px-3 py-1 text-xs font-black uppercase ${statusStyles[milestone.status]}`}>
                  {milestone.status}
                </span>
              </div>
              <p className="mt-4 pl-0 font-medium leading-7 text-night/60 sm:pl-16">{milestone.description}</p>
            </article>
          ))}
        </div>
      </div>
    </section>
  )
}
