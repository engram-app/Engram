import { Link } from 'react-router'
import { useBillingStatus } from '../api/queries'
import FilesPanel from './files-panel'
import Rail from './rail'
import SearchPanel from './search-panel'
import { useRailView } from './rail-view-context'

export default function AppSidebarPanel() {
  const { view } = useRailView()
  const billing = useBillingStatus()
  const showFreeFooter = billing.data?.tier === 'free'

  return (
    <div className="flex h-full flex-col">
      <div className="min-h-0 flex-1">
        {view === 'files' ? <FilesPanel /> : <SearchPanel />}
      </div>
      {showFreeFooter && (
        <div className="border-t border-border px-3 py-2 text-xs text-muted-foreground">
          Free tier — 1 connection.{' '}
          <Link
            to="/settings/billing"
            className="font-medium text-foreground underline underline-offset-4"
          >
            Upgrade
          </Link>
        </div>
      )}
    </div>
  )
}

export { Rail }
