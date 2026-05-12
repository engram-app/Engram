import { NavLink, Outlet } from 'react-router'

const SECTIONS = [
  { to: 'appearance', label: 'Appearance' },
  { to: 'api-keys', label: 'API Keys' },
  { to: 'encryption', label: 'Encryption' },
  { to: 'billing', label: 'Billing' },
] as const

export default function SettingsLayout() {
  return (
    <section className="mx-auto flex max-w-5xl gap-8 py-2">
      <nav aria-label="Settings sections" className="w-48 shrink-0">
        <h2 className="mb-3 text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">
          Settings
        </h2>
        <ul className="space-y-1">
          {SECTIONS.map((s) => (
            <li key={s.to}>
              <NavLink
                to={s.to}
                className={({ isActive }) =>
                  `block rounded-md px-3 py-2 text-sm transition-colors ${
                    isActive
                      ? 'bg-blue-50 dark:bg-blue-950 font-medium text-blue-700 dark:text-blue-300'
                      : 'text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-800'
                  }`
                }
              >
                {s.label}
              </NavLink>
            </li>
          ))}
        </ul>
      </nav>
      <section className="min-w-0 flex-1">
        <Outlet />
      </section>
    </section>
  )
}
