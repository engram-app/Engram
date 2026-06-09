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
  | "external_ai_searches_per_day_exceeded"
  | "inapp_searches_per_day_exceeded"
  | "attachment_must_be_text"
  | "mcp_connections_exceeded"
  | "obsidian_connections_exceeded"
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
    title: "Device sync limit reached",
    body: "Your Free plan syncs files between 1 device at a time. Disconnect the device you're not using to switch, or upgrade to sync more devices.",
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
  external_ai_searches_per_day_exceeded: {
    title: "Daily external-tool search limit reached",
    body: "Your Free plan allows 15 searches per day from MCP clients, the Obsidian plugin, and API-key scripts. Upgrade for unlimited.",
  },
  inapp_searches_per_day_exceeded: {
    title: "Daily in-app search limit reached",
    body: "Your Free plan allows 60 searches per day in the web app. Upgrade for unlimited.",
  },
  attachment_must_be_text: {
    title: "Free plan: text attachments only",
    body: "Your Free plan can attach text files (.md, .txt, .csv, .html, code). Upgrade to attach images, audio, video, PDFs, and office documents.",
  },
  mcp_connections_exceeded: {
    title: "External connection limit reached",
    body: "Your Free plan allows 1 active external connection. Disconnect it to use this one instead, or upgrade for unlimited connections.",
  },
  obsidian_connections_exceeded: {
    title: "External connection limit reached",
    body: "Your Free plan allows 1 active external connection. Disconnect it to use this one instead, or upgrade for unlimited connections.",
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
