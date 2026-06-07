import { FolderTree, Search, Settings } from 'lucide-react'
import { NavLink } from 'react-router'
import { Button } from '@/components/ui/button'
import UserMenu from './user-menu'
import { useRailView, type RailView } from './rail-view-context'

function ViewButton({ id, label, dataTour, Icon }: {
  id: RailView
  label: string
  dataTour?: string
  Icon: typeof Search
}) {
  const { view, setView } = useRailView()
  const active = view === id
  return (
    <Button
      variant="ghost"
      size="icon-sm"
      aria-label={label}
      aria-current={active ? 'page' : undefined}
      data-tour={dataTour}
      title={label}
      onClick={() => setView(id)}
      className={active ? 'bg-accent text-accent-foreground' : undefined}
    >
      <Icon className="h-4 w-4" />
    </Button>
  )
}

export default function Rail() {
  return (
    <nav
      aria-label="App navigation"
      className="flex h-full w-12 shrink-0 flex-col items-center gap-1 border-r border-border bg-card py-2"
    >
      <NavLink
        to="/"
        aria-label="Engram home"
        className="mb-2 flex h-8 w-8 items-center justify-center rounded-md bg-primary text-xs font-semibold text-primary-foreground"
      >
        E
      </NavLink>
      <ViewButton id="files" label="Files" Icon={FolderTree} />
      <ViewButton id="search" label="Search" dataTour="search" Icon={Search} />
      <div className="flex-1" />
      <NavLink
        to="/settings"
        aria-label="Settings"
        title="Settings"
        className={({ isActive }) =>
          `flex h-8 w-8 items-center justify-center rounded-md hover:bg-accent ${isActive ? 'bg-accent text-accent-foreground' : 'text-muted-foreground'}`
        }
      >
        <Settings className="h-4 w-4" />
      </NavLink>
      <UserMenu />
    </nav>
  )
}
