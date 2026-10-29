// The backend answers 403 `account_conflict` when a signed-in Clerk identity
// cannot be bound to an Engram account: its email (or an alias of it) already
// belongs to another account. The app signs out, and this flag tells the
// sign-in page why, so the user sees a message instead of a silent bounce.

const KEY = "engram:account-conflict";

export function markAccountConflict(): void {
	try {
		sessionStorage.setItem(KEY, "1");
	} catch {
		// sessionStorage unavailable (private mode / SSR): non-fatal.
	}
}

export function hasAccountConflict(): boolean {
	try {
		return sessionStorage.getItem(KEY) !== null;
	} catch {
		return false;
	}
}

export function clearAccountConflict(): void {
	try {
		sessionStorage.removeItem(KEY);
	} catch {
		// See markAccountConflict.
	}
}
