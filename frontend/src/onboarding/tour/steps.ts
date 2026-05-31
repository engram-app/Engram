import type { DriveStep } from 'driver.js'

export const tourSteps: DriveStep[] = [
  {
    element: '[data-tour="sidebar-vaults"]',
    popover: {
      title: 'Your vaults',
      description:
        'A vault is a collection of notes. You can have many. Right now you’re looking at a demo.',
      side: 'right',
      align: 'start',
    },
  },
  {
    element: '[data-tour="folder-tree"]',
    popover: {
      title: 'Folders mirror your filesystem',
      description:
        'The folder structure here matches what lives in your Obsidian vault on disk.',
      side: 'right',
    },
  },
  {
    element: '[data-tour="note-viewer"]',
    popover: {
      title: 'Read and edit anywhere',
      description:
        'Click any note to view it. Full Obsidian-style markdown — wikilinks, callouts, math, mermaid.',
      side: 'left',
    },
  },
  {
    element: '[data-tour="search"]',
    popover: {
      title: 'Search everything',
      description: 'Full-text + semantic search across every note in every vault.',
      side: 'bottom',
    },
  },
  {
    element: '[data-tour="settings-link"]',
    popover: {
      title: 'Settings live here',
      description:
        'Manage vaults, billing, API keys, and (soon) connect Obsidian + AI tools.',
      side: 'right',
    },
  },
  {
    element: '[data-tour="dashboard-root"]',
    popover: {
      title: 'You’re ready',
      description: 'Now let’s create your real first vault.',
      side: 'over',
      doneBtnText: 'Create my vault',
    },
  },
]
