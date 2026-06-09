import { useState } from "react"
import { useNavigate } from "react-router"
import { useQueryClient } from "@tanstack/react-query"
import { toast } from "sonner"

import { Button } from "@/components/ui/button"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"

import { api } from "../api/client"
import { useConnections, type Connection } from "../api/queries"
import { copyFor } from "./limit-copy"

export interface UpgradeRequiredDialogProps {
  reason: string
  open: boolean
  onOpenChange: (open: boolean) => void
}

function isConnectionCap(reason: string): "mcp" | "obsidian" | null {
  if (reason === "mcp_connections_exceeded") return "mcp"
  if (reason === "obsidian_connections_exceeded") return "obsidian"
  return null
}

export function UpgradeRequiredDialog({ reason, open, onOpenChange }: UpgradeRequiredDialogProps) {
  const navigate = useNavigate()
  const { title, body } = copyFor(reason)
  const connKind = isConnectionCap(reason)

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
          <DialogDescription>{body}</DialogDescription>
        </DialogHeader>

        {connKind ? <ExistingConnectionsPanel kind={connKind} onChanged={() => onOpenChange(false)} /> : null}

        <DialogFooter>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Dismiss
          </Button>
          {connKind ? (
            <Button
              variant="outline"
              onClick={() => {
                onOpenChange(false)
                navigate("/settings/connections")
              }}
            >
              Manage connections
            </Button>
          ) : null}
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

function ExistingConnectionsPanel({
  kind,
  onChanged,
}: {
  kind: "mcp" | "obsidian"
  onChanged: () => void
}) {
  const { data: connections, isLoading } = useConnections()
  const qc = useQueryClient()
  const [busyId, setBusyId] = useState<string | null>(null)

  if (isLoading) {
    return <p className="text-sm text-muted-foreground">Loading current connection…</p>
  }

  const existing = (connections ?? []).filter((c) => c.kind === kind)
  if (existing.length === 0) return null

  async function disconnect(c: Connection) {
    const id = connectionId(c)
    if (!id) return
    setBusyId(id)
    try {
      const path = c.kind === "obsidian" ? `/connections/device/${id}` : `/connections/oauth/${id}`
      await api.del(path)
      await qc.invalidateQueries({ queryKey: ["connections"] })
      toast.success("Disconnected. Retry the new connection now.")
      onChanged()
    } catch {
      toast.error("Couldn't disconnect. Try Settings → Connections.")
    } finally {
      setBusyId(null)
    }
  }

  return (
    <div className="rounded-md border border-border bg-muted/30 p-3 text-sm">
      <p className="mb-2 font-medium text-foreground">Currently connected:</p>
      <ul className="space-y-2">
        {existing.map((c) => {
          const id = connectionId(c)
          return (
            <li key={id ?? c.name ?? Math.random()} className="flex items-center justify-between gap-3">
              <span className="text-foreground">
                {c.name ?? "(unnamed)"}
                {c.connected_at ? (
                  <span className="ml-2 text-xs text-muted-foreground">
                    since {new Date(c.connected_at).toLocaleDateString()}
                  </span>
                ) : null}
              </span>
              {id ? (
                <Button
                  type="button"
                  size="sm"
                  variant="outline"
                  disabled={busyId === id}
                  onClick={() => disconnect(c)}
                >
                  {busyId === id ? "Disconnecting…" : "Disconnect"}
                </Button>
              ) : null}
            </li>
          )
        })}
      </ul>
    </div>
  )
}

function connectionId(c: Connection): string | null {
  if (c.kind === "obsidian") return c.key_id != null ? String(c.key_id) : null
  return c.client_id
}
