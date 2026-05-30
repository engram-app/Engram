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
    { to: 'vaults', label: 'Vaults' },
    { to: 'api-keys', label: 'API Keys' },
  ]
  if (billingEnabled) {
    sections.push({ to: 'billing', label: 'Billing' })
  }
  // Self-host only: admins manage members/invites/registration here.
  if (authProvider === 'local' && isAdmin) {
    sections.push({ to: 'admin', label: 'Administration' })
  }
  if (authProvider === 'clerk') {
    return [{ to: 'account', label: 'Account' }, ...sections]
  }
  return sections
}
