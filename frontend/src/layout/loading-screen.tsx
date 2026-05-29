export default function LoadingScreen() {
  return (
    <main
      role="status"
      aria-label="Loading"
      className="flex h-screen flex-col items-center justify-center gap-3 bg-background text-foreground"
    >
      <span
        aria-hidden="true"
        className="size-6 animate-spin rounded-full border-2 border-border border-t-primary"
      />
      <p className="text-sm text-muted-foreground">Loading…</p>
    </main>
  )
}
