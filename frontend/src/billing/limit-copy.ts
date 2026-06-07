export type LimitReason =
  | "notes_cap_exceeded"
  | "vaults_cap_exceeded"
  | "attachments_disabled"
  | "attachments_quota_exceeded"
  | "file_too_large"
  | "concurrent_devices_exceeded"
  | "device_swap_cooldown"
  | "ai_conversations_per_day_exceeded"
  | "ai_queries_per_conversation_exceeded"
  | "ai_queries_per_day_exceeded"
  | "realtime_disabled"
  | "account_suspended"
  | "no_tier"

export type LimitCopy = { title: string; body: string }

const TABLE: Record<LimitReason, LimitCopy> = {
  notes_cap_exceeded: {
    title: "You've hit your note limit",
    body: "Upgrade to keep adding notes.",
  },
  vaults_cap_exceeded: {
    title: "Free includes 1 vault",
    body: "Upgrade for more vaults.",
  },
  attachments_disabled: {
    title: "Attachments are a Pro feature",
    body: "Upgrade to sync images, PDFs, and other files.",
  },
  attachments_quota_exceeded: {
    title: "Attachment storage full",
    body: "Upgrade for more storage.",
  },
  file_too_large: {
    title: "File too large",
    body: "Upgrade to upload larger files.",
  },
  concurrent_devices_exceeded: {
    title: "Already signed in elsewhere",
    body: "Free supports 1 device at a time. Upgrade for multi-device.",
  },
  device_swap_cooldown: {
    title: "Device swap cooldown active",
    body: "Wait before swapping devices, or upgrade.",
  },
  ai_conversations_per_day_exceeded: {
    title: "Daily AI conversation limit reached",
    body: "Upgrade for more.",
  },
  ai_queries_per_conversation_exceeded: {
    title: "Conversation length limit reached",
    body: "Upgrade for longer conversations.",
  },
  ai_queries_per_day_exceeded: {
    title: "Daily AI query limit reached",
    body: "Upgrade for more.",
  },
  realtime_disabled: {
    title: "Realtime sync is a Pro feature",
    body: "Upgrade for live sync.",
  },
  account_suspended: {
    title: "Account suspended",
    body: "Contact support to restore access.",
  },
  no_tier: {
    title: "Account setup incomplete",
    body: "Please complete onboarding.",
  },
}

const FALLBACK: LimitCopy = {
  title: "Limit reached",
  body: "Upgrade to continue.",
}

export function copyFor(reason: string): LimitCopy {
  return TABLE[reason as LimitReason] ?? FALLBACK
}
