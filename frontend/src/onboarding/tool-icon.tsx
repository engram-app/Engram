// Brand marks, color variant where the brand publishes one (Claude, Mistral,
// Claude Code), otherwise the currentColor mono mark. Wordmark SVGs always
// ship in currentColor, so they inherit row state (muted default / foreground
// on selected) the same way plain text would.
import antigravityColor from "@lobehub/icons-static-svg/icons/antigravity-color.svg?raw";
import antigravityText from "@lobehub/icons-static-svg/icons/antigravity-text.svg?raw";
import claudeColor from "@lobehub/icons-static-svg/icons/claude-color.svg?raw";
import claudeText from "@lobehub/icons-static-svg/icons/claude-text.svg?raw";
import claudeCodeColor from "@lobehub/icons-static-svg/icons/claudecode-color.svg?raw";
import clineMark from "@lobehub/icons-static-svg/icons/cline.svg?raw";
import clineText from "@lobehub/icons-static-svg/icons/cline-text.svg?raw";
import cursorMark from "@lobehub/icons-static-svg/icons/cursor.svg?raw";
import cursorText from "@lobehub/icons-static-svg/icons/cursor-text.svg?raw";
import geminiMark from "@lobehub/icons-static-svg/icons/gemini.svg?raw";
import geminiText from "@lobehub/icons-static-svg/icons/gemini-text.svg?raw";
import githubCopilotMark from "@lobehub/icons-static-svg/icons/githubcopilot.svg?raw";
import githubCopilotText from "@lobehub/icons-static-svg/icons/githubcopilot-text.svg?raw";
import grokMark from "@lobehub/icons-static-svg/icons/grok.svg?raw";
import grokText from "@lobehub/icons-static-svg/icons/grok-text.svg?raw";
import lobeChatColor from "@lobehub/icons-static-svg/icons/lobehub-color.svg?raw";
import lobeChatText from "@lobehub/icons-static-svg/icons/lobehub-text.svg?raw";
import mcpMark from "@lobehub/icons-static-svg/icons/mcp.svg?raw";
import mistralColor from "@lobehub/icons-static-svg/icons/mistral-color.svg?raw";
import mistralText from "@lobehub/icons-static-svg/icons/mistral-text.svg?raw";
import openaiMark from "@lobehub/icons-static-svg/icons/openai.svg?raw";
import openaiText from "@lobehub/icons-static-svg/icons/openai-text.svg?raw";
import openCodeMark from "@lobehub/icons-static-svg/icons/opencode.svg?raw";
import openCodeText from "@lobehub/icons-static-svg/icons/opencode-text.svg?raw";
import openWebUIMark from "@lobehub/icons-static-svg/icons/openwebui.svg?raw";
import openWebUIText from "@lobehub/icons-static-svg/icons/openwebui-text.svg?raw";
import windsurfMark from "@lobehub/icons-static-svg/icons/windsurf.svg?raw";
import windsurfText from "@lobehub/icons-static-svg/icons/windsurf-text.svg?raw";
import { Box, Globe, Workflow } from "lucide-react";
import type { ReactNode } from "react";

interface Brand {
	mark: string;
	wordmark?: string;
}

// Skipping the MCP wordmark deliberately: ships as "ModelContextProtocol"
// (335px viewBox) which dominates the row and isn't the label we want here
// anyway. We fall through to the plain `fallbackLabel`.
// `chatgpt` and `lobechat` intentionally wear their VENDOR's mark (OpenAI,
// LobeHub) rather than the product's. Checked 2026-07-31 (#1157): the
// package ships no `chatgpt-*` or `lobechat-*` asset at all, only
// `openai*.svg` and `lobehub*.svg`, so the vendor mark is the whole of what
// is available. Not drift, and not worth re-investigating — it changes only
// if @lobehub/icons-static-svg adds product-specific assets.
const BRANDS: Record<string, Brand> = {
	claude: { mark: claudeColor, wordmark: claudeText },
	chatgpt: { mark: openaiMark, wordmark: openaiText },
	grok: { mark: grokMark, wordmark: grokText },
	mistral: { mark: mistralColor, wordmark: mistralText },
	open_webui: { mark: openWebUIMark, wordmark: openWebUIText },
	lobechat: { mark: lobeChatColor, wordmark: lobeChatText },
	// Skipping claudecode-text deliberately: the lobehub wordmark is a pixel-
	// block stylized "CODE" that visually clashes with the row's other clean
	// wordmarks. Fall through to plain "Claude Code" in our typography.
	claude_code: { mark: claudeCodeColor },
	cursor: { mark: cursorMark, wordmark: cursorText },
	windsurf: { mark: windsurfMark, wordmark: windsurfText },
	cline: { mark: clineMark, wordmark: clineText },
	opencode: { mark: openCodeMark, wordmark: openCodeText },
	github_copilot: { mark: githubCopilotMark, wordmark: githubCopilotText },
	antigravity: { mark: antigravityColor, wordmark: antigravityText },
	// Rendered only by the disabled "Gemini" row in the FTUX picker (mono mark,
	// so it greys with the row). `gemini` is not a selectable catalog slug.
	gemini: { mark: geminiMark, wordmark: geminiText },
	other_mcp: { mark: mcpMark },
};

const FALLBACK_ICONS: Record<string, typeof Globe> = {
	web_only: Globe,
	continue: Workflow,
};

/**
 * Mark-only variant for dense rows (the connections list) where the product
 * name is already the row's own text, so a wordmark would just repeat it.
 *
 * Keyed on the same slug the backend resolves in `Connections.LogoAllowlist`,
 * which is why this covers every catalog connector without per-vendor assets:
 * `@lobehub/icons-static-svg` already ships all of them. Renders `fallback`
 * when the slug is absent or has no brand mark.
 */
export function ToolMark({
	slug,
	className,
	fallback = null,
}: {
	slug: string | null;
	className?: string;
	fallback?: ReactNode;
}) {
	const brand = slug ? BRANDS[slug] : undefined;
	if (!brand) {
		return <>{fallback}</>;
	}
	return (
		<span
			aria-hidden
			data-testid={`tool-mark-${slug}`}
			className={className}
			dangerouslySetInnerHTML={{ __html: brand.mark }}
		/>
	);
}

export function ToolBadge({ slug, fallbackLabel }: { slug: string; fallbackLabel: string }) {
	const brand = BRANDS[slug];
	if (brand) {
		return (
			<span className="inline-flex items-center gap-2">
				<span
					aria-hidden
					className="inline-flex h-5 w-5 shrink-0 items-center justify-center [&_svg]:h-full [&_svg]:w-full"
					dangerouslySetInnerHTML={{ __html: brand.mark }}
				/>
				{brand.wordmark ? (
					<>
						<span
							aria-hidden
							className="inline-flex h-4 shrink-0 items-center text-foreground [&_svg]:h-full [&_svg]:w-auto"
							dangerouslySetInnerHTML={{ __html: brand.wordmark }}
						/>
						<span className="sr-only">{fallbackLabel}</span>
					</>
				) : (
					<span className="font-medium text-foreground text-sm">{fallbackLabel}</span>
				)}
			</span>
		);
	}
	const Icon = FALLBACK_ICONS[slug] ?? Box;
	return (
		<span className="inline-flex items-center gap-2">
			<Icon size={16} aria-hidden className="shrink-0" />
			<span className="font-medium text-foreground text-sm">{fallbackLabel}</span>
		</span>
	);
}
