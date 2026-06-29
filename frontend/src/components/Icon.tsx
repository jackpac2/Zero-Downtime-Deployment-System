import type { ReactElement, SVGProps } from 'react'

export type IconName =
  | 'activity'
  | 'arrow-right'
  | 'bell'
  | 'boxes'
  | 'branch'
  | 'check'
  | 'history'
  | 'pulse'
  | 'rollback'
  | 'server'
  | 'shield'

type IconProps = SVGProps<SVGSVGElement> & {
  name: IconName
}

const paths: Record<IconName, ReactElement> = {
  activity: <polyline points="3 12 7 12 10 5 14 19 17 12 21 12" />,
  'arrow-right': (
    <>
      <path d="M5 12h14" />
      <path d="m13 6 6 6-6 6" />
    </>
  ),
  bell: (
    <>
      <path d="M6 9a6 6 0 1 1 12 0c0 7 3 6 3 8H3c0-2 3-1 3-8" />
      <path d="M10 21h4" />
    </>
  ),
  boxes: (
    <>
      <path d="M8 4h8v8H8z" />
      <path d="M3 14h8v6H3z" />
      <path d="M13 14h8v6h-8z" />
    </>
  ),
  branch: (
    <>
      <circle cx="6" cy="5" r="2" />
      <circle cx="18" cy="7" r="2" />
      <circle cx="18" cy="19" r="2" />
      <path d="M8 5c5 0 3 14 8 14" />
      <path d="M8 5c4 0 5 2 8 2" />
    </>
  ),
  check: (
    <>
      <circle cx="12" cy="12" r="9" />
      <path d="m8 12 3 3 5-6" />
    </>
  ),
  history: (
    <>
      <path d="M3 12a9 9 0 1 0 3-6.7" />
      <path d="M3 4v6h6" />
      <path d="M12 7v5l4 2" />
    </>
  ),
  pulse: (
    <>
      <path d="M20 12h-4l-2 5-4-10-2 5H4" />
      <path d="M12 21C7 18 4 15 4 10a4 4 0 0 1 7-2 4 4 0 0 1 7 2" />
    </>
  ),
  rollback: (
    <>
      <path d="M4 7v6h6" />
      <path d="M5 13a7 7 0 1 0 2-7" />
      <path d="M12 9v4l3 2" />
    </>
  ),
  server: (
    <>
      <rect x="4" y="4" width="16" height="6" rx="2" />
      <rect x="4" y="14" width="16" height="6" rx="2" />
      <path d="M8 7h.01" />
      <path d="M8 17h.01" />
    </>
  ),
  shield: (
    <>
      <path d="M12 3 5 6v5c0 5 3 8 7 10 4-2 7-5 7-10V6z" />
      <path d="m9 12 2 2 4-5" />
    </>
  ),
}

export function Icon({ name, className, ...props }: IconProps) {
  return (
    <svg
      aria-hidden="true"
      className={className}
      fill="none"
      stroke="currentColor"
      strokeLinecap="round"
      strokeLinejoin="round"
      strokeWidth="2"
      viewBox="0 0 24 24"
      {...props}
    >
      {paths[name]}
    </svg>
  )
}
