import { Icon } from './Icon'

const navItems = ['Platform', 'Pipeline', 'Milestones', 'Status']

export function Header() {
  return (
    <header className="relative z-20 mx-auto flex w-full max-w-7xl items-center justify-between px-5 py-5 sm:px-8 lg:px-10">
      <a href="#" className="group flex items-center gap-3" aria-label="DeployGuard home">
        <span className="flex h-11 w-11 rotate-3 items-center justify-center rounded-2xl bg-grape text-white shadow-[4px_4px_0_#16112b] transition group-hover:-rotate-3">
          <Icon name="shield" className="h-5 w-5" />
        </span>
        <span className="text-lg font-black tracking-[-0.04em] text-night">DEPLOYGUARD</span>
      </a>

      <nav className="hidden items-center gap-1 rounded-full border-2 border-night bg-white/70 p-1 text-sm font-bold text-night shadow-[4px_4px_0_rgba(22,17,43,0.15)] backdrop-blur md:flex">
        {navItems.map((item) => (
          <a
            key={item}
            href={`#${item.toLowerCase()}`}
            className="rounded-full px-4 py-2 transition hover:bg-lime"
          >
            {item}
          </a>
        ))}
      </nav>

      <a
        href="#pipeline"
        className="hidden items-center gap-2 rounded-full border-2 border-night bg-night px-5 py-2.5 text-sm font-black text-white shadow-[4px_4px_0_#c7ff5e] transition hover:-translate-y-0.5 sm:inline-flex"
      >
        Open console
        <Icon name="arrow-right" className="h-4 w-4" />
      </a>
    </header>
  )
}
