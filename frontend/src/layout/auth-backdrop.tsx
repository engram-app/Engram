// Decorative neural-glow + grid backdrop shared by the branded full-screen
// surfaces (AuthShell, AuthLayout, SettingsLayout). Render inside a `relative`
// parent; content should sit in a sibling with `relative z-10`.
export default function AuthBackdrop() {
	return (
		<div className="pointer-events-none absolute inset-0 z-0 overflow-hidden" aria-hidden="true">
			<div className="grid-overlay absolute inset-0 opacity-30" />
			<div className="neural-glow-purple absolute -top-32 -left-32 h-96 w-96 opacity-60" />
			<div className="neural-glow-cyan absolute -right-32 -bottom-32 h-96 w-96 opacity-60" />
		</div>
	);
}
