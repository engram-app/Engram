import { LogOut, Settings } from 'lucide-react'
import { Link } from 'react-router'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { useAuthAdapter } from '../auth/use-auth-adapter'

// One avatar dropdown for both auth modes — the auth adapter exposes email,
// avatar, and logout regardless of provider, so Clerk's own UserButton isn't
// needed here. Account management still lives under /settings (Settings →
// Account). Clerk supplies a generated imageUrl; local auth falls back to the
// email initial.
export default function UserMenu() {
  const { user, logout } = useAuthAdapter()
  const initial = user?.email?.[0]?.toUpperCase() ?? '?'

  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        aria-label="User menu"
        data-tour="settings-link"
        className="rounded-full outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background"
      >
        {user?.imageUrl ? (
          <img
            src={user.imageUrl}
            alt=""
            className="h-9 w-9 rounded-full object-cover"
          />
        ) : (
          <span className="flex h-9 w-9 items-center justify-center rounded-full bg-primary text-sm font-medium text-primary-foreground">
            {initial}
          </span>
        )}
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-64 p-1.5">
        <DropdownMenuLabel className="truncate px-3 py-2 text-sm font-normal text-muted-foreground">
          {user?.email}
        </DropdownMenuLabel>
        <DropdownMenuSeparator />
        <DropdownMenuItem asChild className="gap-2.5 px-3 py-2.5 text-sm">
          <Link to="/settings">
            <Settings className="h-4 w-4" />
            Settings
          </Link>
        </DropdownMenuItem>
        <DropdownMenuItem
          className="gap-2.5 px-3 py-2.5 text-sm"
          onSelect={() => void logout()}
        >
          <LogOut className="h-4 w-4" />
          Sign out
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
