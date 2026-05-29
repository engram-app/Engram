import type { EngramConfig } from '../config'

export interface SettingsSection {
  to: string
  label: string
}

export function buildSettingsSections(
  authProvider: EngramConfig['authProvider'],
  billingEnabled: boolean,
): SettingsSection[] {
  const sections: SettingsSection[] = [
    { to: 'vaults', label: 'Vaults' },
    { to: 'api-keys', label: 'API Keys' },
  ]
  if (billingEnabled) {
    sections.push({ to: 'billing', label: 'Billing' })
  }
  if (authProvider === 'clerk') {
    return [{ to: 'account', label: 'Account' }, ...sections]
  }
  return sections
}
