import type { Step } from 'react-joyride'

// Step indexes that require the user to interact with the highlighted target
// before the tour advances. TourController hides the Next button on these
// steps and listens for clicks on the target instead.
export const GATED_STEP_INDEXES = new Set<number>([0])

// react-joyride v3 renamed `disableBeacon` → `skipBeacon`. Lives in Options, so
// declaring it at the step level just sets the per-step override.
export const tourSteps: Step[] = [
  {
    target: '[data-tour="sidebar-vaults"]',
    title: 'Your vaults',
    content:
      'A vault is a collection of notes. You can have many — click here to swap between them. Right now you’re looking at a demo.',
    placement: 'right',
    skipBeacon: true,
    // Gated: empty buttons array hides the footer (v3 replaces `hideFooter`);
    // blockTargetInteraction:false lets the click reach the underlying element.
    // TourController watches for that click and advances the stepIndex.
    buttons: [],
    blockTargetInteraction: false,
  },
  {
    target: '[data-tour="folder-tree"]',
    title: 'Folders mirror your filesystem',
    content:
      'The folder structure here matches what lives in your Obsidian vault on disk.',
    placement: 'right',
    skipBeacon: true,
  },
  {
    target: '[data-tour="note-viewer"]',
    title: 'Read and edit anywhere',
    content:
      'Click any note to view it. Full Obsidian-style markdown — wikilinks, callouts, math, mermaid.',
    placement: 'left',
    skipBeacon: true,
  },
  {
    target: '[data-tour="search"]',
    title: 'Search everything',
    content: 'Full-text + semantic search across every note in every vault.',
    placement: 'bottom',
    skipBeacon: true,
  },
  {
    target: '[data-tour="settings-link"]',
    title: 'Settings live here',
    content:
      'Manage vaults, billing, API keys, and (soon) connect Obsidian + AI tools.',
    placement: 'right',
    skipBeacon: true,
  },
  {
    target: '[data-tour="dashboard-root"]',
    title: 'You’re ready',
    content: 'Now let’s create your real first vault.',
    placement: 'center',
    skipBeacon: true,
  },
]
