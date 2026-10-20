import { sentryReady } from "../sentry";

// Browser page translation (Google Translate, Chrome's built-in translate)
// replaces the text nodes React owns with its own <font> wrappers. React's
// next commit removes or inserts relative to a node that is no longer where
// React left it, the DOM throws NotFoundError, and the throw lands the user
// on the error page (Sentry ENGRAM-FRONTEND-4/-8/-9; facebook/react#11538).
//
// This is the guard from that issue: when the node is no longer `this`'s
// child, skip the operation instead of throwing. The translated text may go
// stale, which beats a crash. Imported first by main.tsx, before React renders.
//
// ponytail: patches the two methods the reports show. Add replaceChild if a
// translator-shaped NotFoundError ever names it.

function noteSkipped(method: string) {
	const message = `[dom-translation-guard] skipped ${method}: node moved by another script (page translation?)`;
	console.warn(message);
	// Console breadcrumbs are dropped by scrubBreadcrumb, so record our own. No
	// node in it: translated text is user content.
	sentryReady?.then((Sentry) =>
		Sentry?.addBreadcrumb({ category: "dom", level: "warning", message }),
	);
}

const originalRemoveChild = Node.prototype.removeChild;
Node.prototype.removeChild = function removeChild<T extends Node>(this: Node, child: T): T {
	if (child.parentNode !== this) {
		noteSkipped("removeChild");
		return child;
	}
	// Both methods return their node argument, so return it rather than cast
	// the untyped `.call` result back to T.
	originalRemoveChild.call(this, child);
	return child;
};

const originalInsertBefore = Node.prototype.insertBefore;
Node.prototype.insertBefore = function insertBefore<T extends Node>(
	this: Node,
	node: T,
	child: Node | null,
): T {
	if (child && child.parentNode !== this) {
		noteSkipped("insertBefore");
		return node;
	}
	originalInsertBefore.call(this, node, child);
	return node;
};
