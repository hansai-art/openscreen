import { randomUUID } from "node:crypto";
import { readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
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
	private autoTranscribe = true;
	private apiKey: string | undefined;
	private credentialLoaded = false;
	private hasStoredApiKey = false;
	private readonly configFile: string;
	private readonly keyFile: string;
	constructor(
		directory: string,
		private readonly cipher: CredentialCipher,
		private readonly environment: Record<string, string | undefined> = process.env,
	) {
		this.configFile = path.join(directory, "stt-settings.json");
		this.keyFile = path.join(directory, "stt-credential.enc");
		let storedKeyMetadata: boolean | undefined;
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
				if ("autoTranscribe" in config && typeof config.autoTranscribe === "boolean")
					this.autoTranscribe = config.autoTranscribe;
				if ("hasStoredApiKey" in config && typeof config.hasStoredApiKey === "boolean")
					storedKeyMetadata = config.hasStoredApiKey;
			}
		} catch {
			/* A missing or invalid config starts with local transcription. */
		}
		try {
			this.hasStoredApiKey = storedKeyMetadata !== false && statSync(this.keyFile).size > 0;
		} catch {
			/* No saved encrypted credential. Do not access the OS keychain here. */
		}
		if (this.autoTranscribe) this.loadCredential();
	}
	private encryptionAvailable(): boolean {
		return (
			this.cipher.isEncryptionAvailable() &&
			(process.platform !== "linux" || this.cipher.getSelectedStorageBackend?.() !== "basic_text")
		);
	}
	private effectiveKey(): string | undefined {
		if (!this.environment.GMI_API_KEY?.trim()) this.loadCredential();
		return this.environment.GMI_API_KEY?.trim() || this.apiKey;
	}
	private loadCredential(): void {
		if (this.credentialLoaded) return;
		this.credentialLoaded = true;
		try {
			if (this.hasStoredApiKey && this.encryptionAvailable())
				this.apiKey = this.cipher.decryptString(readFileSync(this.keyFile)).trim() || undefined;
		} catch {
			/* An unreadable credential is surfaced when transcription explicitly needs it. */
		}
	}
	private hasCredential(): boolean {
		return Boolean(
			this.environment.GMI_API_KEY?.trim() ||
				(this.credentialLoaded ? this.apiKey : this.hasStoredApiKey),
		);
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
			autoTranscribe: this.autoTranscribe,
			hasApiKey: this.hasCredential(),
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
		if (update.autoTranscribe !== undefined && typeof update.autoTranscribe !== "boolean")
			throw new Error("Invalid automatic transcription setting");
		if (update.apiKey !== undefined && typeof update.apiKey !== "string")
			throw new Error("Invalid API key");
		const provider = update.provider ?? this.provider;
		const cloudConsent = update.cloudConsent ?? this.cloudConsent;
		const autoTranscribe = update.autoTranscribe ?? this.autoTranscribe;
		const nextKey = update.apiKey === undefined ? this.apiKey : update.apiKey.trim() || undefined;
		const hasStoredApiKey = update.apiKey === undefined ? this.hasStoredApiKey : Boolean(nextKey);
		if (autoTranscribe && provider === "gmi" && !cloudConsent)
			throw new Error("GMI transcription needs explicit cloud consent");
		if (
			autoTranscribe &&
			provider === "gmi" &&
			!(update.apiKey === undefined
				? this.hasCredential()
				: this.environment.GMI_API_KEY?.trim() || nextKey)
		)
			throw new Error("GMI transcription needs an API key");
		if (update.apiKey !== undefined) {
			if (!this.encryptionAvailable())
				throw new Error(
					"OS credential encryption is unavailable; no plaintext credential was saved",
				);
			this.writeAtomically(this.keyFile, this.cipher.encryptString(nextKey ?? ""));
		}
		this.writeAtomically(
			this.configFile,
			JSON.stringify({ provider, cloudConsent, autoTranscribe, hasStoredApiKey }, null, 2),
		);
		this.provider = provider;
		this.cloudConsent = cloudConsent;
		this.autoTranscribe = autoTranscribe;
		this.hasStoredApiKey = hasStoredApiKey;
		if (update.apiKey !== undefined) {
			this.apiKey = nextKey;
			this.credentialLoaded = true;
		}
		return this.getSnapshot();
	}
}
