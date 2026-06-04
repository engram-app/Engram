import type { Step } from 'react-joyride'

// Step indexes that require the user to perform a specific interaction
// before the tour advances. Maps the step index → the window CustomEvent
// name TourController should listen for. Steps in this map have their
// footer hidden (via `buttons: []`) so the only way forward is the
// configured interaction.
export const GATED_STEPS: Record<number, string> = {
  0: 'engram:vault-switched',
  1: 'engram:note-opened',
  2: 'engram:edit-mode-entered',
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
    title: 'Open a note',
    content:
      'Real files and folders that sync across every device. Your AI tools read from the same files. Expand one and click any note.',
    placement: 'right',
    skipBeacon: true,
    // Gated on `engram:note-opened` — NotePage dispatches this when it
    // mounts with a path. See controller.tsx + steps.ts GATED_STEPS.
    buttons: [],
    blockTargetInteraction: false,
  },
  {
    target: '[data-tour="note-tabs"]',
    title: 'Swap between Preview and Edit mode',
    content: 'Click Edit to keep going.',
    placement: 'left',
    skipBeacon: true,
    // Gated on `engram:edit-mode-entered` — NotePage dispatches this when
    // the tab switches to "edit". See controller.tsx + GATED_STEPS.
    buttons: [],
    blockTargetInteraction: false,
  },
  {
    target: '[data-tour="note-editor"]',
    title: 'Edit in plain markdown',
    content:
      'Type markdown directly. Saved changes sync everywhere your files live.',
    placement: 'left',
    skipBeacon: true,
  },
  {
    target: '[data-tour="search"]',
    title: 'Search everything',
    content:
      'Ask in your own words and Engram surfaces the notes that fit — even if they don’t use the same exact words.',
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
