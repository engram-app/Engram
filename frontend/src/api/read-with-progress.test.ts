import { expect, test } from "vitest";
import { readWithProgress } from "./client";

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
