import { useEffect, useState } from "react";
import { useScopedT } from "@/contexts/I18nContext";
import { TRANSCRIPTION_SETTINGS_CHANGED_EVENT } from "@/hooks/useTranscriptionProvider";
import type {
	TranscriptionSettingsSnapshot,
	TranscriptionSettingsUpdate,
} from "../../../electron/stt/settingsContract";
import styles from "./NewEditorShell.module.css";

export function TranscriptionSettings({ open }: { open: boolean }) {
	const te = useScopedT("editor");
	const [snapshot, setSnapshot] = useState<TranscriptionSettingsSnapshot | null>(null);
	const [provider, setProvider] = useState<"whisper" | "gmi">("whisper");
	const [consent, setConsent] = useState(false);
	const [apiKey, setApiKey] = useState("");
	const [busy, setBusy] = useState(false);
	const [error, setError] = useState<string | null>(null);
	const [saved, setSaved] = useState(false);
	const api = window.electronAPI?.stt;
	useEffect(() => {
		setApiKey("");
		setSaved(false);
		if (!open || !api?.getSettings) return;
		let current = true;
		void api.getSettings().then(
			(next) => {
				if (!current) return;
				setSnapshot(next);
				setProvider(next.provider);
				setConsent(next.cloudConsent);
				setError(null);
			},
			() => {
				if (current) setError(te("transcriptionSettings.loadFailed"));
			},
		);
		return () => {
			current = false;
		};
	}, [open, api, te]);
	const update = async (changes: TranscriptionSettingsUpdate) => {
		setBusy(true);
		setError(null);
		setSaved(false);
		try {
			const next = await api.updateSettings(changes);
			setSnapshot(next);
			setProvider(next.provider);
			setConsent(next.cloudConsent);
			setApiKey("");
			setSaved(true);
			// No credential or settings payload is broadcast; readers refresh the public snapshot.
			window.dispatchEvent(new Event(TRANSCRIPTION_SETTINGS_CHANGED_EVENT));
		} catch (reason) {
			setError(reason instanceof Error ? reason.message : te("transcriptionSettings.saveFailed"));
		} finally {
			setBusy(false);
		}
	};
	if (!open || !api?.getSettings) return null;
	return (
		<section
			data-testid="transcription-settings"
			className={styles.providerForm}
			style={{ marginTop: 20, borderTop: "1px solid var(--line)", paddingTop: 16 }}
		>
			<div className={styles.title}>
				<h3>{te("transcriptionSettings.title")}</h3>
			</div>
			<p className={styles.hint}>{te("transcriptionSettings.description")}</p>
			<div className={styles.field}>
				<label htmlFor="stt-provider">{te("transcriptionSettings.provider")}</label>
				<select
					id="stt-provider"
					value={provider}
					disabled={busy || !snapshot}
					onChange={(event) => {
						setProvider(event.target.value as "whisper" | "gmi");
						setSaved(false);
					}}
				>
					<option value="whisper">{te("transcriptionSettings.whisper")}</option>
					<option value="gmi">GMI Cloud Gemini 3 Flash Preview</option>
				</select>
			</div>
			{provider === "gmi" ? (
				<>
					<p className={styles.hint}>{te("transcriptionSettings.traditional")}</p>
					<div className={styles.field}>
						<label htmlFor="stt-api-key">{te("transcriptionSettings.apiKey")}</label>
						<input
							id="stt-api-key"
							type="password"
							autoComplete="off"
							value={apiKey}
							disabled={busy}
							onChange={(event) => {
								setApiKey(event.target.value);
								setSaved(false);
							}}
						/>
						{snapshot?.hasApiKey ? (
							<span className={styles.hint}>{te("transcriptionSettings.keySet")}</span>
						) : null}
					</div>
					<label style={{ display: "flex", alignItems: "flex-start", gap: 8 }}>
						<input
							type="checkbox"
							checked={consent}
							disabled={busy}
							onChange={(event) => {
								setConsent(event.target.checked);
								setSaved(false);
							}}
						/>
						<span>{te("transcriptionSettings.consent")}</span>
					</label>
				</>
			) : null}
			{error ? (
				<p role="alert" className={styles.errorRow}>
					{error}
				</p>
			) : null}
			{saved ? (
				<p role="status" className={styles.hint}>
					{te("transcriptionSettings.saved")}
				</p>
			) : null}
			<div className={styles.actions}>
				<button
					type="button"
					className={`${styles.btn} ${styles.btnPrimary}`}
					disabled={
						busy ||
						!snapshot ||
						(provider === "gmi" && (!consent || (!apiKey.trim() && !snapshot.hasApiKey)))
					}
					onClick={() =>
						void update({
							provider,
							cloudConsent: provider === "gmi" && consent,
							...(apiKey.trim() ? { apiKey: apiKey.trim() } : {}),
						})
					}
				>
					{te("transcriptionSettings.save")}
				</button>
				{snapshot?.hasApiKey ? (
					<button
						type="button"
						className={`${styles.btn} ${styles.btnSecondary}`}
						disabled={busy}
						onClick={() => void update({ provider: "whisper", cloudConsent: false, apiKey: "" })}
					>
						{te("transcriptionSettings.removeKey")}
					</button>
				) : null}
			</div>
		</section>
	);
}
