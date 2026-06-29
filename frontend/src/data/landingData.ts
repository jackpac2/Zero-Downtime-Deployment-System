import type { IconName } from '../components/Icon'

export type Feature = {
  title: string
  description: string
  icon: IconName
}

export type Milestone = {
  label: string
  title: string
  description: string
  status: 'Live' | 'Next' | 'Planned'
}

export const metrics = [
  { value: '99.99%', label: 'target availability' },
  { value: '<60s', label: 'rollback decision window' },
  { value: '7', label: 'delivery milestones' },
  { value: '24/7', label: 'deployment signal coverage' },
]

export const features: Feature[] = [
  {
    title: 'Compose-ready services',
    description:
      'Frontend and API services are shaped for Docker Compose so EC2 runs the same workflow every time.',
    icon: 'boxes',
  },
  {
    title: 'Health-gated releases',
    description:
      'Readiness checks make deployment status explicit before a release is treated as successful.',
    icon: 'pulse',
  },
  {
    title: 'Rollback confidence',
    description:
      'Failed releases can restore the previous working version instead of leaving production uncertain.',
    icon: 'rollback',
  },
  {
    title: 'Observable delivery',
    description:
      'Deployment events, alerts, and history keep operational context visible beyond a green build.',
    icon: 'activity',
  },
]

export const milestones: Milestone[] = [
  {
    label: 'Milestone 1',
    title: 'It runs on EC2',
    description: 'React frontend, Node API, and Docker Compose running behind a public EC2 address.',
    status: 'Live',
  },
  {
    label: 'Milestone 2',
    title: 'Nginx becomes the gatekeeper',
    description: 'Route browser traffic to the frontend and API traffic to the backend through one edge.',
    status: 'Next',
  },
  {
    label: 'Milestone 4',
    title: 'GitHub Actions CI/CD',
    description: 'Build, deploy, and manage secrets from a repeatable pipeline instead of manual steps.',
    status: 'Planned',
  },
  {
    label: 'Milestone 7',
    title: 'Production observability',
    description: 'Discord notifications, deployment history, and operational visibility for every release.',
    status: 'Planned',
  },
]

export const trustSignals: Array<{ label: string; icon: IconName }> = [
  { label: 'GitHub Actions', icon: 'branch' },
  { label: 'Health checks', icon: 'check' },
  { label: 'Rollback engine', icon: 'history' },
  { label: 'Alerts', icon: 'bell' },
  { label: 'Guardrails', icon: 'shield' },
]
