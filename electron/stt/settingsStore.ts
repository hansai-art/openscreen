import { randomUUID } from "node:crypto";
import { readFileSync, renameSync, writeFileSync } from "node:fs";
import path from "node:path";
import type {
	TranscriptionSettingsSnapshot,
	TranscriptionSettingsUpdate,
} from "./settingsContract";

export interface CredentialCipher {
	isEncryptionAvailable(): boolean;
	encryptString(value: string): Buffer;
	decryptString(value: Buffer): string;
	getSelectedStorageBackend?(): string;
}

export class TranscriptionSettingsStore {
	private provider: "whisper" | "gmi" = "whisper";
	private cloudConsent = false;
	private apiKey: string | undefined;
	private readonly configFile: string;
	private readonly keyFile: string;
	constructor(
		directory: string,
		private readonly cipher: CredentialCipher,
		private readonly environment: Record<string, string | undefined> = process.env,
	) {
		this.configFile = path.join(directory, "stt-settings.json");
		this.keyFile = path.join(directory, "stt-credential.enc");
		try {
			const config: unknown = JSON.parse(readFileSync(this.configFile, "utf8"));
			if (
				typeof config === "object" &&
				config !== null &&
				"provider" in config &&
				"cloudConsent" in config
			) {
				if (config.provider === "gmi" || config.provider === "whisper")
					this.provider = config.provider;
				this.cloudConsent = config.cloudConsent === true;
			}
		} catch {
			/* A missing or invalid config starts with local transcription. */
		}
		try {
			if (this.encryptionAvailable())
				this.apiKey = this.cipher.decryptString(readFileSync(this.keyFile)).trim() || undefined;
		} catch {
			/* A missing/unreadable credential is surfaced as hasApiKey: false. */
		}
	}
	private encryptionAvailable(): boolean {
		return (
			this.cipher.isEncryptionAvailable() &&
			(process.platform !== "linux" || this.cipher.getSelectedStorageBackend?.() !== "basic_text")
		);
	}
	private effectiveKey(): string | undefined {
		return this.environment.GMI_API_KEY?.trim() || this.apiKey;
	}
	private writeAtomically(file: string, contents: string | Buffer): void {
		const temporary = `${file}.${randomUUID()}.tmp`;
		writeFileSync(temporary, contents, { mode: 0o600 });
		renameSync(temporary, file);
	}
	getSnapshot(): TranscriptionSettingsSnapshot {
		return {
			provider: this.provider,
			cloudConsent: this.cloudConsent,
			hasApiKey: Boolean(this.effectiveKey()),
		};
	}
	getProviderConfig(): { provider: "whisper" | "gmi"; cloudConsent: boolean; apiKey?: string } {
		return {
			provider: this.provider,
			cloudConsent: this.cloudConsent,
			apiKey: this.effectiveKey(),
		};
	}
	update(update: TranscriptionSettingsUpdate): TranscriptionSettingsSnapshot {
		if (typeof update !== "object" || update === null)
			throw new Error("Invalid transcription settings");
		if (update.provider !== undefined && update.provider !== "whisper" && update.provider !== "gmi")
			throw new Error("Invalid transcription provider");
		if (update.cloudConsent !== undefined && typeof update.cloudConsent !== "boolean")
			throw new Error("Invalid cloud consent");
		if (update.apiKey !== undefined && typeof update.apiKey !== "string")
			throw new Error("Invalid API key");
		const provider = update.provider ?? this.provider;
		const cloudConsent = update.cloudConsent ?? this.cloudConsent;
		const nextKey = update.apiKey === undefined ? this.apiKey : update.apiKey.trim() || undefined;
		if (provider === "gmi" && !cloudConsent)
			throw new Error("GMI transcription needs explicit cloud consent");
		if (provider === "gmi" && !(this.environment.GMI_API_KEY?.trim() || nextKey))
			throw new Error("GMI transcription needs an API key");
		if (update.apiKey !== undefined) {
			if (!this.encryptionAvailable())
				throw new Error(
					"OS credential encryption is unavailable; no plaintext credential was saved",
				);
			this.writeAtomically(this.keyFile, this.cipher.encryptString(nextKey ?? ""));
		}
		this.writeAtomically(this.configFile, JSON.stringify({ provider, cloudConsent }, null, 2));
		this.provider = provider;
		this.cloudConsent = cloudConsent;
		this.apiKey = nextKey;
		return this.getSnapshot();
	}
}
