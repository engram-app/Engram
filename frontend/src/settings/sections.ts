import type { EngramConfig } from '../config'

export interface SettingsSection {
  to: string
  label: string
}

const BASE_SECTIONS: SettingsSection[] = [
  { to: 'api-keys', label: 'API Keys' },
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
