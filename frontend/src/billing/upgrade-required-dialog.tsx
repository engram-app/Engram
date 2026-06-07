import { useNavigate } from "react-router"

import { Button } from "@/components/ui/button"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"

import { copyFor } from "./limit-copy"

export interface UpgradeRequiredDialogProps {
  reason: string
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function UpgradeRequiredDialog({ reason, open, onOpenChange }: UpgradeRequiredDialogProps) {
  const navigate = useNavigate()
  const { title, body } = copyFor(reason)

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
          <DialogDescription>{body}</DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Dismiss
          </Button>
          <Button
            onClick={() => {
              onOpenChange(false)
              navigate("/settings/billing")
            }}
          >
            Upgrade
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
