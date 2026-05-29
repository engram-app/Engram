import { Link } from 'react-router'
import { ROUTES } from './routes'
import AuthShell from './layout/auth-shell'
import AuthPanel from './layout/auth-panel'
import { Button } from '@/components/ui/button'
import { heading } from '@/lib/ui-classes'

export default function NotFoundPage() {
  return (
    <AuthShell>
      <AuthPanel className="flex flex-col items-center gap-4 text-center">
        <p className="bg-gradient-to-r from-brand-purple to-primary bg-clip-text font-extrabold leading-none tracking-tight text-transparent text-7xl sm:text-8xl">
          404
        </p>
        <h1 className={heading}>
          Page not found
        </h1>
        <p className="max-w-md text-sm text-muted-foreground">
          We couldn't find what you're looking for. The link may be broken or the page may
          have moved.
        </p>
        <Button asChild className="mt-2">
          <Link to={ROUTES.HOME}>Back to home</Link>
        </Button>
      </AuthPanel>
    </AuthShell>
  )
}
