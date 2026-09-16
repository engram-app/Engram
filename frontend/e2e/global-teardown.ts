import fs from "node:fs";
import path from "node:path";
import { cleanupTestUsers } from "./db-cleanup";

const AUTH_STATE_PATH = path.join(__dirname, ".auth-state.json");
const CLERK_API = "https://api.clerk.com/v1";

async function cleanupClerkUser() {
	if (!fs.existsSync(AUTH_STATE_PATH)) {
		return;
	}

	const state = JSON.parse(fs.readFileSync(AUTH_STATE_PATH, "utf-8"));

	if (state.skipped) {
		fs.unlinkSync(AUTH_STATE_PATH);
		return;
	}

	const secretKey = process.env.E2E_CLERK_SECRET_KEY;
	if (!(secretKey && state.clerk_user_id)) {
		fs.unlinkSync(AUTH_STATE_PATH);
		return;
	}

	// Both users, including the deliberately un-onboarded one. Deleted in a loop
	// so a failure on the first does not strand the second — Clerk's dev
	// instance has a 100-user cap and leaked users are what hits it.
	for (const id of [state.clerk_user_id, state.pending_clerk_user_id]) {
		if (!id) {
			continue;
		}

		const resp = await fetch(`${CLERK_API}/users/${id}`, {
			method: "DELETE",
			headers: { Authorization: `Bearer ${secretKey}` },
		});

		if (resp.ok) {
			console.log(`Clerk test user deleted: ${id}`);
		} else {
			console.warn(`Failed to delete Clerk user ${id}: ${resp.status}`);
		}
	}

	fs.unlinkSync(AUTH_STATE_PATH);
}

export default async function globalTeardown() {
	// 1. Clean up e2e test users from backend DB (both local + clerk tests)
	await cleanupTestUsers("teardown");

	// 2. Clean up Clerk test user via API
	await cleanupClerkUser();
}
