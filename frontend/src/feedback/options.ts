import { msg } from "@/i18n/msg";

// Slugs must match Engram.Feedback (lib/engram/feedback.ex); the backend 422s
// anything else.

export interface FeedbackOption {
	slug: string;
	label: string;
}

export const HEARD_FROM: FeedbackOption[] = [
	{ slug: "search", label: msg("Search engine") },
	{ slug: "reddit", label: msg("Reddit") },
	{ slug: "youtube", label: msg("YouTube") },
	{ slug: "obsidian_community", label: msg("Obsidian forum or Discord") },
	{ slug: "friend", label: msg("Friend or colleague") },
	{ slug: "ai_assistant", label: msg("An AI assistant suggested it") },
	{ slug: "social", label: msg("X, Bluesky, or other social media") },
	{ slug: "other", label: msg("Somewhere else") },
];

export const USE_CASES: FeedbackOption[] = [
	{ slug: "ai_memory", label: msg("Give my AI tools memory of my notes") },
	{ slug: "obsidian_sync", label: msg("Sync Obsidian across devices") },
	{ slug: "web_access", label: msg("Read and edit notes in a browser") },
	{ slug: "search", label: msg("Search my notes by meaning") },
	{ slug: "backup", label: msg("Back up my vault") },
	{ slug: "sharing", label: msg("Share notes with others") },
	{ slug: "other", label: msg("Something else") },
];

export const CANCEL_REASONS: FeedbackOption[] = [
	{ slug: "too_expensive", label: msg("Too expensive") },
	{ slug: "missing_feature", label: msg("Missing a feature I need") },
	{ slug: "sync_issues", label: msg("Sync problems or bugs") },
	{ slug: "switched_tool", label: msg("Switched to another tool") },
	{ slug: "not_using", label: msg("Not using it enough") },
	{ slug: "other", label: msg("Something else") },
];
