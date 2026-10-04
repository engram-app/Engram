import { expect, test } from "vitest";
import { linkTextFor, readDraggedItem, setDraggedItem, VAULT_ITEM_MIME } from "./vault-item-drag";

function transfer() {
	const store = new Map<string, string>();
	return {
		get types() {
			return [...store.keys()];
		},
		setData: (t: string, v: string) => {
			store.set(t, v);
		},
		getData: (t: string) => store.get(t) ?? "",
	} as unknown as DataTransfer;
}

test("round-trips an item through the dataTransfer", () => {
	const dt = transfer();
	setDraggedItem(dt, { kind: "attachment", path: "img/a.png" });
	expect(dt.types).toContain(VAULT_ITEM_MIME);
	expect(readDraggedItem(dt)).toEqual({ kind: "attachment", path: "img/a.png" });
});

test("ignores a drag that is not a vault item or carries junk", () => {
	expect(readDraggedItem(transfer())).toBeNull();
	const dt = transfer();
	dt.setData(VAULT_ITEM_MIME, "{nope");
	expect(readDraggedItem(dt)).toBeNull();
	dt.setData(VAULT_ITEM_MIME, JSON.stringify({ kind: "folder", path: "x" }));
	expect(readDraggedItem(dt)).toBeNull();
});

test("a note becomes a [[wikilink]] by name", () => {
	expect(linkTextFor({ kind: "note", path: "Work/Plan.md" }, [])).toBe("[[Plan]]");
});

test("an attachment becomes an ![[embed]]: bare name when unique, else the full path", () => {
	const list = [{ path: "img/a.png" }, { path: "img/b.png" }, { path: "old/b.png" }];
	expect(linkTextFor({ kind: "attachment", path: "img/a.png" }, list)).toBe("![[a.png]]");
	expect(linkTextFor({ kind: "attachment", path: "img/b.png" }, list)).toBe("![[img/b.png]]");
});
