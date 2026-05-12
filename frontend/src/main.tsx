import { StrictMode, lazy, Suspense } from 'react'
import { createRoot } from 'react-dom/client'
import { RouterProvider } from 'react-router'
import { QueryClientProvider } from '@tanstack/react-query'
import { Toaster } from '@/components/ui/sonner'
import { router } from './router'
import { queryClient } from './api/query-client'
import { config } from './config'
import { ThemeProvider } from './theme/theme-provider'
import './main.css'

const isClerk = config.authProvider === 'clerk'

const AuthProvider = isClerk
  ? lazy(() => import('./auth/clerk-auth-provider'))
  : lazy(() => import('./auth/local-auth-provider'))

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ThemeProvider>
      <Suspense fallback={<p>Loading...</p>}>
        <AuthProvider>
          <QueryClientProvider client={queryClient}>
            <RouterProvider router={router} />
            <Toaster richColors closeButton />
          </QueryClientProvider>
        </AuthProvider>
      </Suspense>
    </ThemeProvider>
  </StrictMode>,
)
