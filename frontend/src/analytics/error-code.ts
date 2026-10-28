import { ApiError } from "../api/client";
import type { ERROR_CODES } from "./events";

type ErrorCode = (typeof ERROR_CODES)[number];

const STATUS_CODES: Record<number, ErrorCode> = {
	401: "auth",
	403: "auth",
	404: "not_found",
	429: "rate_limited",
};

/** Buckets a thrown error into an ERROR_CODES member, so a failure event never
 *  carries the message (error detail is where free text hides). */
export function errorCodeOf(err: unknown): ErrorCode {
	if (err instanceof Error && err.name === "LimitExceededError") {
		return "limit_exceeded";
	}
	if (err instanceof ApiError) {
		return STATUS_CODES[err.status] ?? "unknown";
	}
	// fetch() rejects with a TypeError when the request never got a response.
	return err instanceof TypeError ? "network" : "unknown";
}
