import { EventEmitter } from "node:events";
import { access, writeFile } from "node:fs/promises";
import { PassThrough } from "node:stream";
import { beforeEach, describe, expect, it, vi } from "vitest";

const spawnMock = vi.fn();
vi.mock("node:child_process", () => ({ spawn: (...args: unknown[]) => spawnMock(...args) }));
vi.mock("../media/audioPeaks", () => ({ resolveFfmpeg: () => "/test/ffmpeg" }));

import { copyOriginalAudioForGmi } from "./gmiSourceAudio";

function child() {
	const process = new EventEmitter() as EventEmitter & {
		stderr: PassThrough;
		kill: ReturnType<typeof vi.fn>;
	};
	process.stderr = new PassThrough();
	process.kill = vi.fn();
	return process;
}

beforeEach(() => spawnMock.mockReset());

describe("GMI source audio preservation", () => {
	it.each([
		["aac", ".m4a", "ipod"],
		["pcm_s16le", ".mka", "matroska"],
	])("stream-copies %s beside the source without resampling/compressing the original", async (codec, extension, muxer) => {
		const probe = child();
		const copy = child();
		spawnMock.mockReturnValueOnce(probe).mockReturnValueOnce(copy);
		const pending = copyOriginalAudioForGmi("/tmp/source.mp4");
		probe.stderr.end(`Stream #0:1: Audio: ${codec}, 48000 Hz, stereo`);
		probe.emit("close", 1);
		await vi.waitFor(() => expect(spawnMock).toHaveBeenCalledTimes(2));
		copy.emit("close", 0);
		const result = await pending;
		expect(result.audioPath).toMatch(
			new RegExp(`^/tmp/source\\.openscreen-gmi-[a-f0-9-]+\\${extension}$`),
		);
		const args = spawnMock.mock.calls[1][1] as string[];
		expect(args).toContain("-n");
		expect(args.join(" ")).toContain("-c:a copy");
		expect(args.join(" ")).toContain(`-f ${muxer}`);
		expect(args).not.toContain("-ar");
		expect(args).not.toContain("-ac");
		await writeFile(result.audioPath, "owned copied audio fixture");
		await result.cleanup();
		await expect(access(result.audioPath)).rejects.toThrow();
	});

	it("cancel kills an active stream copy and removes its partial sidecar", async () => {
		const probe = child();
		const copy = child();
		spawnMock.mockReturnValueOnce(probe).mockReturnValueOnce(copy);
		const controller = new AbortController();
		const pending = copyOriginalAudioForGmi("/tmp/source.mp4", controller.signal);
		probe.stderr.end("Stream #0:1: Audio: aac, 48000 Hz, stereo");
		probe.emit("close", 1);
		await vi.waitFor(() => expect(spawnMock).toHaveBeenCalledTimes(2));
		const args = spawnMock.mock.calls[1][1] as string[];
		const output = args[args.length - 1];
		await writeFile(output, "partial audio");
		controller.abort();
		await expect(pending).rejects.toMatchObject({ name: "AbortError" });
		expect(copy.kill).toHaveBeenCalledWith("SIGKILL");
		await expect(access(output)).rejects.toThrow();
	});

	it("fails a source with no audio instead of decoding its video into a false empty transcript", async () => {
		const probe = child();
		spawnMock.mockReturnValue(probe);
		const pending = copyOriginalAudioForGmi("/tmp/silent.mp4");
		probe.stderr.end("Stream #0:0: Video: h264");
		probe.emit("close", 1);
		await expect(pending).rejects.toThrow(/No decodable audio/);
		expect(spawnMock).toHaveBeenCalledOnce();
	});
});
