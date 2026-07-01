// Decorative neural-glow + grid backdrop shared by the branded full-screen
// surfaces (AuthShell, AuthLayout, SettingsLayout). Render inside a `relative`
// parent; content should sit in a sibling with `relative z-10`.
export default function AuthBackdrop() {
	return (
		<div className="pointer-events-none absolute inset-0 z-0 overflow-hidden" aria-hidden="true">
			<div className="absolute inset-0 grid-overlay opacity-30" />
			<div className="absolute -left-32 -top-32 h-96 w-96 neural-glow-purple opacity-60" />
			<div className="absolute -bottom-32 -right-32 h-96 w-96 neural-glow-cyan opacity-60" />
		</div>
	);
}
