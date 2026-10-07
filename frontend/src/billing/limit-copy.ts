import { msg } from "@/i18n/msg";

const TABLE: Record<LimitReason, LimitCopy> = {
	notes_cap_exceeded: {
		title: msg("You've hit your note limit"),
		body: msg("Upgrade to keep adding notes."),
	},
	vaults_cap_exceeded: {
		title: msg("Free includes 1 vault"),
		body: msg("Upgrade for more vaults."),
	},
	attachments_disabled: {
		title: msg("Attachments are a Pro feature"),
		body: msg("Upgrade to sync images, PDFs, and other files."),
	},
	attachments_quota_exceeded: {
		title: msg("Attachment storage full"),
		body: msg("Upgrade for more storage."),
	},
	file_too_large: {
		title: msg("File too large"),
		body: msg("Upgrade to upload larger files."),
	},
	concurrent_devices_exceeded: {
		title: msg("Device sync limit reached"),
		body: msg(
			"Your Free plan syncs files between 1 device at a time. Disconnect the device you're not using to switch, or upgrade to sync more devices.",
		),
	},
	device_swap_cooldown: {
		title: msg("Device swap cooldown active"),
		body: msg("Wait before swapping devices, or upgrade."),
	},
	ai_searches_per_day_exceeded: {
		title: msg("Daily AI search limit reached"),
		body: msg(
			"Your Free plan includes 20 AI searches per day, shared across the web app, the Obsidian plugin, and MCP clients. Upgrade for unlimited.",
		),
	},
	attachment_must_be_text: {
		title: msg("Free plan: text attachments only"),
		body: msg(
			"Your Free plan can attach text files (.md, .txt, .csv, .html, code). Upgrade to attach images, audio, video, PDFs, and office documents.",
		),
	},
	mcp_connections_exceeded: {
		title: msg("External connection limit reached"),
		body: msg(
			"Your Free plan allows 1 active external connection. Disconnect it to use this one instead, or upgrade for unlimited connections.",
		),
	},
	obsidian_connections_exceeded: {
		title: msg("External connection limit reached"),
		body: msg(
			"Your Free plan allows 1 active external connection. Disconnect it to use this one instead, or upgrade for unlimited connections.",
		),
	},
	account_suspended: {
		title: msg("Account suspended"),
		body: msg("Contact support to restore access."),
	},
	no_tier: {
		title: msg("Account setup incomplete"),
		body: msg("Please complete onboarding."),
	},
};

const FALLBACK: LimitCopy = {
	title: msg("Limit reached"),
	body: msg("Upgrade to continue."),
};

type LimitReason =
	| "notes_cap_exceeded"
	| "vaults_cap_exceeded"
	| "attachments_disabled"
	| "attachments_quota_exceeded"
	| "file_too_large"
	| "concurrent_devices_exceeded"
	| "device_swap_cooldown"
	| "ai_searches_per_day_exceeded"
	| "attachment_must_be_text"
	| "mcp_connections_exceeded"
	| "obsidian_connections_exceeded"
	| "account_suspended"
	| "no_tier";

interface LimitCopy {
	title: string;
	body: string;
}

// `reason` arrives off the wire, so it is a plain string; TABLE's own keys are
// the authority on which ones we have copy for.
function isLimitReason(k: string): k is LimitReason {
	return k in TABLE;
}

export function copyFor(reason: string): LimitCopy {
	return isLimitReason(reason) ? TABLE[reason] : FALLBACK;
}

export type { LimitCopy, LimitReason };
