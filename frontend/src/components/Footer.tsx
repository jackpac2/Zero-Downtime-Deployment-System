import { Icon } from './Icon'

export function Footer() {
  return (
    <footer className="bg-night text-white">
      <div className="mx-auto flex max-w-7xl flex-col gap-8 px-5 py-10 sm:px-8 md:flex-row md:items-end md:justify-between lg:px-10">
        <div>
          <a href="#" className="inline-flex items-center gap-3" aria-label="DeployGuard home">
            <span className="flex h-10 w-10 items-center justify-center rounded-xl bg-lime text-night">
              <Icon name="shield" className="h-5 w-5" />
            </span>
            <span className="font-display text-xl font-black tracking-[-0.04em]">DEPLOYGUARD</span>
          </a>
          <p className="mt-4 max-w-md text-sm font-medium leading-6 text-white/45">
            Zero-downtime delivery for teams who like their infrastructure safe and their interfaces loud.
          </p>
        </div>
        <div className="text-left md:text-right">
          <p className="font-mono text-xs font-bold uppercase tracking-[0.18em] text-cyan">Built to stay online</p>
          <p className="mt-2 text-sm font-medium text-white/40">React ? Node ? Docker ? EC2</p>
        </div>
      </div>
    </footer>
  )
}
