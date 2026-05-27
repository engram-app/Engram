import type { EngramConfig } from '../config'

export interface SettingsSection {
  to: string
  label: string
}

const BASE_SECTIONS: SettingsSection[] = [
  { to: 'appearance', label: 'Appearance' },
  { to: 'api-keys', label: 'API Keys' },
  { to: 'encryption', label: 'Encryption' },
  { to: 'billing', label: 'Billing' },
]

export function buildSettingsSections(
  authProvider: EngramConfig['authProvider'],
): SettingsSection[] {
  if (authProvider === 'clerk') {
    return [{ to: 'account', label: 'Account' }, ...BASE_SECTIONS]
  }
  return BASE_SECTIONS
}
