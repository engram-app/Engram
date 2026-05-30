import { useState, useEffect } from 'react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { useMe, useUpdateProfile } from '../../api/queries'
import { SettingsSectionCard } from './section-card'

const inputClass =
  'mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring'

export function ProfileSectionLocal() {
  const { data } = useMe()
  const update = useUpdateProfile()
  const current = data?.user.display_name ?? ''
  const [value, setValue] = useState(current)

  useEffect(() => {
    setValue(current)
  }, [current])

  const dirty = value.trim() !== (current ?? '').trim()

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault()
    try {
      await update.mutateAsync({ display_name: value.trim() === '' ? null : value.trim() })
      toast.success('Profile updated')
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Could not update profile')
    }
  }

  return (
    <SettingsSectionCard title="Profile" description="How your name appears in the app.">
      <form onSubmit={onSubmit} className="space-y-3">
        <label className="block text-sm font-medium text-foreground" htmlFor="display-name">
          Display name
          <input
            id="display-name"
            className={inputClass}
            value={value}
            maxLength={80}
            onChange={(e) => setValue(e.target.value)}
            placeholder="Leave blank to use your email"
          />
        </label>
        <Button type="submit" size="sm" disabled={!dirty || update.isPending}>
          {update.isPending ? 'Saving…' : 'Save'}
        </Button>
      </form>
    </SettingsSectionCard>
  )
}
