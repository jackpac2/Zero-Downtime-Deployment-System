import { Icon } from './Icon'

const navItems = ['Platform', 'Pipeline', 'Milestones', 'Status']

export function Header() {
  return (
    <header className="mx-auto flex w-full max-w-7xl items-center justify-between px-5 py-5 sm:px-8 lg:px-10">
      <a href="#" className="flex items-center gap-3" aria-label="DeployGuard home">
        <span className="flex h-10 w-10 items-center justify-center rounded-lg bg-ink text-white shadow-sm">
          <Icon name="shield" className="h-5 w-5" />
        </span>
        <span className="text-lg font-extrabold tracking-normal text-ink">DeployGuard</span>
      </a>

      <nav className="hidden items-center gap-8 text-sm font-semibold text-slate-600 md:flex">
        {navItems.map((item) => (
          <a key={item} href={`#${item.toLowerCase()}`} className="transition hover:text-ink">
            {item}
          </a>
        ))}
      </nav>

      <a
        href="#pipeline"
        className="hidden items-center gap-2 rounded-lg bg-action px-4 py-2.5 text-sm font-bold text-white shadow-sm shadow-blue-200 transition hover:bg-blue-700 sm:inline-flex"
      >
        View pipeline
        <Icon name="arrow-right" className="h-4 w-4" />
      </a>
    </header>
  )
}
