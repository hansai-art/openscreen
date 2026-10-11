import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { rm } from "node:fs/promises";
import path from "node:path";
import { resolveFfmpeg } from "../media/audioPeaks";
import { FfmpegUnavailableError, MediaUnreadableError, NoAudioTrackError } from "./extractAudio";

/** Read/copy only: no original-media re-encoding or permanent extra WAV files. */
function ffmpegCommand(
	ffmpeg: string,
	args: string[],
	signal?: AbortSignal,
): Promise<{
	code: number | null;
	stderr: string;
}> {
	if (signal?.aborted)
		return Promise.reject(new DOMException("Transcription cancelled", "AbortError"));
	return new Promise((resolve, reject) => {
		const child = spawn(ffmpeg, args, { stdio: ["ignore", "ignore", "pipe"] });
		let stderr = "";
		let settled = false;
		const finish = (action: () => void) => {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			signal?.removeEventListener("abort", abort);
			action();
		};
		const abort = () => {
			child.kill("SIGKILL");
			finish(() => reject(new DOMException("Transcription cancelled", "AbortError")));
		};
		const timer = setTimeout(() => {
			child.kill("SIGKILL");
			finish(() => reject(new Error("GMI audio stream copy/probe timed out")));
		}, 60_000);
		child.stderr?.on("data", (data: Buffer) => {
			stderr = (stderr + data.toString()).slice(-8192);
		});
		child.on("error", (error) => finish(() => reject(error)));
		child.on("close", (code) => finish(() => resolve({ code, stderr })));
		signal?.addEventListener("abort", abort, { once: true });
		if (signal?.aborted) abort();
	});
}

/**
 * A unique temporary sidecar beside the source preserves the original codec.
 * AAC is remuxed to M4A; other codecs use lossless Matroska audio. The caller
 * decodes this copy for recognition, then removes only this owned sidecar.
 */
export async function copyOriginalAudioForGmi(
	sourcePath: string,
	signal?: AbortSignal,
): Promise<{
	audioPath: string;
	cleanup: () => Promise<void>;
}> {
	const ffmpeg = resolveFfmpeg();
	if (!ffmpeg) throw new FfmpegUnavailableError();
	const probe = await ffmpegCommand(ffmpeg, ["-hide_banner", "-i", sourcePath], signal);
	if (/operation not permitted|permission denied/i.test(probe.stderr)) {
		throw new MediaUnreadableError(sourcePath, "audio stream copy could not read the source");
	}
	const codec = /Audio:\s*([^,\s]+)/.exec(probe.stderr)?.[1];
	if (!codec)
		throw new NoAudioTrackError(sourcePath, "no source audio stream for lossless copying");
	const aac = codec === "aac";
	const name = path.parse(sourcePath).name;
	const audioPath = path.join(
		path.dirname(sourcePath),
		`${name}.openscreen-gmi-${randomUUID()}${aac ? ".m4a" : ".mka"}`,
	);
	const cleanup = () => rm(audioPath, { force: true });
	try {
		const copied = await ffmpegCommand(
			ffmpeg,
			[
				"-hide_banner",
				"-loglevel",
				"error",
				"-n",
				"-i",
				sourcePath,
				"-map",
				"0:a:0",
				"-vn",
				"-c:a",
				"copy",
				"-f",
				aac ? "ipod" : "matroska",
				audioPath,
			],
			signal,
		);
		if (copied.code !== 0) {
			throw new MediaUnreadableError(
				sourcePath,
				"lossless audio stream copy failed; source is unchanged",
			);
		}
		return { audioPath, cleanup };
	} catch (error) {
		await cleanup().catch(() => undefined);
		throw error;
	}
}
