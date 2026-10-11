import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { TranscriptionSettingsStore } from "./settingsStore";

const folders: string[] = [];
const cipher = {
	isEncryptionAvailable: () => true,
	encryptString: (value: string) => Buffer.from(value.split("").reverse().join("")),
	decryptString: (value: Buffer) => value.toString().split("").reverse().join(""),
};
function folder() {
	const dir = mkdtempSync(path.join(tmpdir(), "openscreen-stt-config-"));
	folders.push(dir);
	return dir;
}
afterEach(() => {
	vi.restoreAllMocks();
	for (const dir of folders.splice(0)) rmSync(dir, { recursive: true, force: true });
});
describe("TranscriptionSettingsStore", () => {
	it("does not call the Linux-only backend API on macOS", () => {
		vi.spyOn(process, "platform", "get").mockReturnValue("darwin");
		const store = new TranscriptionSettingsStore(
			folder(),
			{
				...cipher,
				getSelectedStorageBackend: () => {
					throw new Error("Linux-only API");
				},
			},
			{},
		);
		expect(() =>
			store.update({ provider: "gmi", cloudConsent: true, apiKey: "private-token" }),
		).not.toThrow();
	});
	it("does not activate uploads before cloud consent and a usable credential", () => {
		const store = new TranscriptionSettingsStore(folder(), cipher, {});
		expect(store.getSnapshot()).toEqual({
			provider: "whisper",
			cloudConsent: false,
			hasApiKey: false,
		});
		expect(() => store.update({ provider: "gmi", apiKey: "private-token" })).toThrow(/consent/i);
		expect(store.getSnapshot().provider).toBe("whisper");
	});
	it("persists encrypted credentials and returns only a boolean to the renderer", () => {
		const dir = folder();
		const store = new TranscriptionSettingsStore(dir, cipher, {});
		store.update({ provider: "gmi", cloudConsent: true, apiKey: "private-token" });
		const restored = new TranscriptionSettingsStore(dir, cipher, {});
		expect(restored.getSnapshot()).toEqual({
			provider: "gmi",
			cloudConsent: true,
			hasApiKey: true,
		});
		expect(JSON.stringify(restored.getSnapshot())).not.toContain("private-token");
		expect(readFileSync(path.join(dir, "stt-settings.json"), "utf8")).not.toContain(
			"private-token",
		);
		expect(readFileSync(path.join(dir, "stt-credential.enc"), "utf8")).not.toContain(
			"private-token",
		);
		expect(restored.getProviderConfig().apiKey).toBe("private-token");
	});
	it("keeps an existing key on settings save and disconnects without retaining it", () => {
		const store = new TranscriptionSettingsStore(folder(), cipher, {});
		store.update({ provider: "gmi", cloudConsent: true, apiKey: "private-token" });
		store.update({ provider: "gmi", cloudConsent: true });
		expect(store.getProviderConfig().apiKey).toBe("private-token");
		store.update({ provider: "whisper", cloudConsent: false, apiKey: "" });
		expect(store.getProviderConfig().apiKey).toBeUndefined();
	});
	it("refuses to save plaintext when OS encryption is unavailable", () => {
		const store = new TranscriptionSettingsStore(
			folder(),
			{ ...cipher, isEncryptionAvailable: () => false },
			{},
		);
		expect(() =>
			store.update({ provider: "gmi", cloudConsent: true, apiKey: "private-token" }),
		).toThrow(/encryption/i);
		expect(store.getSnapshot().hasApiKey).toBe(false);
	});
	it("accepts a process environment key without persisting or exposing it", () => {
		const store = new TranscriptionSettingsStore(folder(), cipher, {
			GMI_API_KEY: "environment-token",
		});
		store.update({ provider: "gmi", cloudConsent: true });
		expect(store.getSnapshot().hasApiKey).toBe(true);
		expect(store.getProviderConfig().apiKey).toBe("environment-token");
	});
	it("rejects malformed IPC values without altering the saved configuration", () => {
		const store = new TranscriptionSettingsStore(folder(), cipher, {});
		expect(() => store.update({ provider: "other" } as never)).toThrow();
		expect(() => store.update({ cloudConsent: "yes" } as never)).toThrow();
		expect(() => store.update({ apiKey: 123 } as never)).toThrow();
		expect(store.getSnapshot()).toEqual({
			provider: "whisper",
			cloudConsent: false,
			hasApiKey: false,
		});
	});
});
