export interface TranscriptionSettingsSnapshot {
	provider: "whisper" | "gmi";
	cloudConsent: boolean;
	/** Omitted by older clients; the store defaults to automatic transcription. */
	autoTranscribe?: boolean;
	hasApiKey: boolean;
}

export interface TranscriptionSettingsUpdate {
	provider?: "whisper" | "gmi";
	cloudConsent?: boolean;
	autoTranscribe?: boolean;
	/** Empty clears the credential; omitted keeps it. Never returned in a snapshot. */
	apiKey?: string;
}
