import process from "node:process";
import pg from "pg";

const TEST_EMAIL_PATTERNS = [
	"e2e-local-%@test.com",
	"e2e-browser-%@test.com",
	"e2e-theme-%@test.com",
	"e2e-live-%@test.com",
];

// Hosts safe to run DELETE against. Anything else aborts.
// Extend via E2E_DB_CLEANUP_EXTRA_HOSTS (comma-separated) for self-hosted CI.
const SAFE_HOSTS = new Set(["localhost", "127.0.0.1", "::1", "[::1]"]);

// Abort if more than this many rows would be deleted — paranoia against
// a misconfigured pattern hitting real data.
const MAX_ROWS_DELETED = 100;

function isSafeDbUrl(rawUrl: string): { ok: true } | { ok: false; reason: string } {
	let parsed: URL;
	try {
		parsed = new URL(rawUrl);
	} catch {
		return { ok: false, reason: "DATABASE_URL is not a valid URL" };
	}

	const host = parsed.hostname;
	const extra = (process.env.E2E_DB_CLEANUP_EXTRA_HOSTS ?? "")
		.split(",")
		.map((h) => h.trim())
		.filter(Boolean);

	if (SAFE_HOSTS.has(host) || extra.includes(host)) return { ok: true };
	return {
		ok: false,
		reason: `host "${host}" not in allowlist (localhost/127.0.0.1 or E2E_DB_CLEANUP_EXTRA_HOSTS)`,
	};
}

export async function cleanupTestUsers(phase: "setup" | "teardown"): Promise<void> {
	const dbUrl = process.env.DATABASE_URL;
	if (!dbUrl) {
		console.log("DATABASE_URL not set — skipping DB cleanup");
		return;
	}

	const check = isSafeDbUrl(dbUrl);
	if (!check.ok) {
		console.warn(`[${phase}] Refusing DB cleanup: ${check.reason}`);
		return;
	}

	const client = new pg.Client({
		connectionString: dbUrl,
		connectionTimeoutMillis: 5000,
		statement_timeout: 10_000,
	});

	try {
		await client.connect();

		const conditions = TEST_EMAIL_PATTERNS.map((_, i) => `email LIKE $${i + 1}`).join(" OR ");

		// Count first — abort cleanup if match count looks like prod data.
		const countRes = await client.query(
			`SELECT count(*)::int AS n FROM users WHERE ${conditions}`,
			TEST_EMAIL_PATTERNS,
		);
		const matchCount: number = countRes.rows[0]?.n ?? 0;
		if (matchCount > MAX_ROWS_DELETED) {
			console.error(
				`[${phase}] DB cleanup aborted — ${matchCount} users match e2e patterns (cap ${MAX_ROWS_DELETED}). Refusing to proceed.`,
			);
			return;
		}

		const result = await client.query(
			`DELETE FROM users WHERE ${conditions} RETURNING email`,
			TEST_EMAIL_PATTERNS,
		);

		if (result.rowCount && result.rowCount > 0) {
			const emails = result.rows.map((r: { email: string }) => r.email);
			console.log(`[${phase}] Cleaned up ${emails.length} test user(s): ${emails.join(", ")}`);
		} else {
			console.log(`[${phase}] No test users to clean up`);
		}
	} catch (err) {
		const msg = err instanceof Error ? err.message : String(err);
		if (msg.includes("foreign key constraint")) {
			console.error(`[${phase}] DB cleanup failed — FK constraints on test users: ${msg}`);
		} else {
			console.warn(`[${phase}] DB cleanup failed (non-fatal): ${msg}`);
		}
	} finally {
		await client.end().catch(() => {});
	}
}
