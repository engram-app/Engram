import * as decoding from "lib0/decoding";
import * as encoding from "lib0/encoding";
import * as syncProtocol from "y-protocols/sync";
import { type CrdtManager, REMOTE_ORIGIN } from "./manager";

/** Outer y-protocols message-type tag — we only speak `messageSync`. */
const MESSAGE_SYNC = 0;

function toB64(bytes: Uint8Array): string {
	return btoa(Array.from(bytes, (b) => String.fromCharCode(b)).join(""));
}

function fromB64(b64: string): Uint8Array {
	return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

export interface CrdtChannelOptions {
	manager: CrdtManager;
	/** Transport: send a base64-encoded y-protocols frame for `docId`. */
	send: (docId: string, frame: string) => void;
}

export class CrdtChannel {
	private readonly mgr: CrdtManager;
	private readonly transport: (docId: string, frame: string) => void;
	private readonly initiated = new Set<string>();

	constructor(opts: CrdtChannelOptions) {
		this.mgr = opts.manager;
		this.transport = opts.send;
	}

	async startSync(path: string): Promise<void> {
		const id = this.mgr.docId(path);
		if (this.initiated.has(id)) {
			return;
		}
		this.initiated.add(id);
		const doc = await this.mgr.getDoc(path);
		if (!this.mgr.hasDoc(path)) {
			this.initiated.delete(id); // closed mid-await: re-arm for the next open
			return;
		}
		const encoder = encoding.createEncoder();
		encoding.writeVarUint(encoder, MESSAGE_SYNC);
		syncProtocol.writeSyncStep1(encoder, doc);
		this.transport(id, toB64(encoding.toUint8Array(encoder)));
	}

	resetSync(path: string): void {
		this.initiated.delete(this.mgr.docId(path));
	}

	sendUpdateRaw(docId: string, update: Uint8Array): void {
		const encoder = encoding.createEncoder();
		encoding.writeVarUint(encoder, MESSAGE_SYNC);
		syncProtocol.writeUpdate(encoder, update);
		this.transport(docId, toB64(encoding.toUint8Array(encoder)));
	}

	async handleFrame(path: string, b64: string): Promise<void> {
		let bytes: Uint8Array;
		try {
			bytes = fromB64(b64);
		} catch (err) {
			console.warn("CRDT handleFrame: malformed base64 frame (dropped)", err);
			return;
		}
		const doc = await this.mgr.getDoc(path);
		try {
			const decoder = decoding.createDecoder(bytes);
			const messageType = decoding.readVarUint(decoder);
			if (messageType !== MESSAGE_SYNC) {
				return;
			}
			const replyEncoder = encoding.createEncoder();
			encoding.writeVarUint(replyEncoder, MESSAGE_SYNC);
			syncProtocol.readSyncMessage(decoder, replyEncoder, doc, REMOTE_ORIGIN);
			if (encoding.length(replyEncoder) > 1) {
				this.transport(this.mgr.docId(path), toB64(encoding.toUint8Array(replyEncoder)));
			}
		} catch (err) {
			console.warn("CRDT handleFrame: bad frame content (dropped)", err);
		}
	}
}
