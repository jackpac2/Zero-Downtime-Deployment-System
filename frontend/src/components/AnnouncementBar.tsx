import { Icon } from './Icon'

export function AnnouncementBar() {
  return (
    <a
      href="#pipeline"
      className="group flex min-h-10 w-full items-center justify-center gap-2 bg-ink px-4 py-2 text-center text-sm font-semibold text-white transition hover:bg-slate-800"
      aria-label="Welcome to my update. View the pipeline."
    >
      <span>Welcome to my update</span>
      <Icon
        name="arrow-right"
        className="h-4 w-4 transition-transform duration-200 group-hover:translate-x-1"
      />
    </a>
  )
}
