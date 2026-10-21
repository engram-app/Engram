import { expect, test } from "vitest";
import { readHead, readWithProgress } from "./client";

test("reads the body as a typed Blob and reports bytes as they arrive", async () => {
	const parts = [new Uint8Array([1, 2, 3]), new Uint8Array([4, 5])];
	const body = new ReadableStream<Uint8Array>({
		start(c) {
			for (const p of parts) {
				c.enqueue(p);
			}
			c.close();
		},
	});
	const res = new Response(body, { headers: { "content-type": "image/png" } });
	const seen: number[] = [];
	const blob = await readWithProgress(res, (n) => seen.push(n));
	expect(seen).toEqual([3, 5]);
	expect(blob.size).toBe(5);
	expect(blob.type).toBe("image/png");
});

test("a response with no body still yields an empty Blob", async () => {
	const blob = await readWithProgress(new Response(null), () => undefined);
	expect(blob.size).toBe(0);
});

test("readHead stops reading and cancels the body once maxBytes arrived", async () => {
	let pulls = 0;
	let cancelled = false;
	const body = new ReadableStream<Uint8Array>({
		pull(c) {
			pulls++;
			c.enqueue(new Uint8Array(4).fill(pulls));
		},
		cancel() {
			cancelled = true;
		},
	});
	const res = new Response(body, { headers: { "content-type": "text/plain" } });
	const seen: number[] = [];
	const blob = await readHead(res, 6, (n) => seen.push(n));
	expect(blob.size).toBe(6);
	expect(blob.type).toBe("text/plain");
	expect(seen).toEqual([4, 8]);
	expect(cancelled).toBe(true);
});

test("readHead returns a body shorter than maxBytes whole", async () => {
	const blob = await readHead(new Response("abc"), 10);
	expect(await blob.text()).toBe("abc");
});
