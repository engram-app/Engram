import type { EngramConfig } from '../config'

export interface SettingsSection {
  to: string
  label: string
}

export function buildSettingsSections(
  authProvider: EngramConfig['authProvider'],
  billingEnabled: boolean,
  isAdmin = false,
): SettingsSection[] {
  const sections: SettingsSection[] = [
    { to: 'account', label: 'Account' },
    { to: 'vaults', label: 'Vaults' },
    { to: 'api-keys', label: 'API Keys' },
  ]

  if (billingEnabled) {
    sections.push({ to: 'billing', label: 'Billing' })
  }

  if (authProvider === 'local' && isAdmin) {
    sections.push({ to: 'admin', label: 'Administration' })
  }

  return sections
}
