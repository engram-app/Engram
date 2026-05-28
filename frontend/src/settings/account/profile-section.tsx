import { useState } from 'react'
import { useUser } from '@clerk/clerk-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { SettingsSectionCard } from './section-card'

const inputClass =
  'mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring'

export function ProfileSection() {
  const { user, isLoaded } = useUser()
  const [firstName, setFirstName] = useState('')
  const [lastName, setLastName] = useState('')
  const [seeded, setSeeded] = useState(false)
  const [saving, setSaving] = useState(false)

  if (!isLoaded || !user) return null
  if (!seeded) {
    setFirstName(user.firstName ?? '')
    setLastName(user.lastName ?? '')
    setSeeded(true)
  }

  async function save() {
    setSaving(true)
    try {
      await user!.update({ firstName, lastName })
      toast.success('Profile updated')
    } catch {
      toast.error('Could not update profile')
    } finally {
      setSaving(false)
    }
  }

  async function onImage(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (!file) return
    try {
      await user!.setProfileImage({ file })
      toast.success('Profile image updated')
    } catch {
      toast.error('Could not update image')
    }
  }

  return (
    <SettingsSectionCard title="Profile" description="Your name and avatar.">
      <div className="flex items-center gap-4">
        <img src={user.imageUrl} alt="" className="size-12 rounded-full border border-border" />
        <label className="text-sm text-muted-foreground">
          <span className="sr-only">Profile image</span>
          <input aria-label="Profile image" type="file" accept="image/*" onChange={onImage} className="text-sm" />
        </label>
      </div>
      <div className="mt-4 grid gap-4 sm:grid-cols-2">
        <label className="block text-sm font-medium text-foreground">
          First name
          <input className={inputClass} value={firstName} onChange={(e) => setFirstName(e.target.value)} />
        </label>
        <label className="block text-sm font-medium text-foreground">
          Last name
          <input className={inputClass} value={lastName} onChange={(e) => setLastName(e.target.value)} />
        </label>
      </div>
      <Button className="mt-4" onClick={save} disabled={saving}>
        {saving ? 'Saving…' : 'Save'}
      </Button>
    </SettingsSectionCard>
  )
}
