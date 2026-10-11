export interface TranscriptionSettingsSnapshot {
	provider: "whisper" | "gmi";
	cloudConsent: boolean;
	hasApiKey: boolean;
}

export interface TranscriptionSettingsUpdate {
	provider?: "whisper" | "gmi";
	cloudConsent?: boolean;
	/** Empty clears the credential; omitted keeps it. Never returned in a snapshot. */
	apiKey?: string;
}
