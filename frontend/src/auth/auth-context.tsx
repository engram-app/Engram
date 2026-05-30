import { createContext } from 'react'

export interface AuthAdapter {
  isLoaded: boolean
  isSignedIn: boolean
  user: { email: string; imageUrl?: string } | null

  getToken(): Promise<string | null>

  login?(email: string, password: string): Promise<void>
  register?(email: string, password: string, invite?: string): Promise<void>
  logout(): Promise<void>

  /** Clerk renders its own SignIn/SignUp/UserButton; local mode uses custom components */
  hasBuiltInUI: boolean
}

export const AuthContext = createContext<AuthAdapter | null>(null)
