import type { Step } from 'react-joyride'

// Step indexes that require the user to perform a specific interaction
// before the tour advances. Maps the step index → the window CustomEvent
// name TourController should listen for. Steps in this map have their
// footer hidden (via `buttons: []`) so the only way forward is the
// configured interaction.
export const GATED_STEPS: Record<number, string> = {
  0: 'engram:vault-switched',
}

// react-joyride v3 renamed `disableBeacon` → `skipBeacon`. Lives in Options, so
// declaring it at the step level just sets the per-step override.
export const tourSteps: Step[] = [
  {
    target: '[data-tour="sidebar-vaults"]',
    title: 'Your vaults',
    content:
      'A vault is a collection of notes. Open this menu and switch to another vault to continue — you can always swap back.',
    placement: 'right',
    skipBeacon: true,
    // Gated: empty buttons array hides the footer (v3 replaces `hideFooter`);
    // blockTargetInteraction:false lets clicks reach the dropdown trigger
    // and items underneath. TourController listens for `engram:vault-switched`
    // (dispatched by VaultSwitcher.onValueChange) and advances on real switch.
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
