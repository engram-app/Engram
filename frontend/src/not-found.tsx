import { Link } from 'react-router'
import { ROUTES } from './routes'

export default function NotFoundPage() {
  return (
    <main className="flex min-h-screen flex-col items-center justify-center px-6 text-center">
      <p className="text-sm font-medium uppercase tracking-wide text-gray-500">404</p>
      <h1 className="mt-2 text-2xl font-semibold text-gray-900">Page not found</h1>
      <p className="mt-2 max-w-md text-sm text-gray-600">
        We couldn't find what you're looking for. The link may be broken or the page may have moved.
      </p>
      <Link
        to={ROUTES.HOME}
        className="mt-6 inline-block rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
      >
        Back to home
      </Link>
    </main>
  )
}
