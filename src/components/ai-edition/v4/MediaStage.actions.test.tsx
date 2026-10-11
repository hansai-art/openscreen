// @vitest-environment jsdom
import "@testing-library/jest-dom";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const actions = vi.hoisted(() => ({
	importSrt: vi.fn(async (_assetId: string, _text: string) => undefined),
	request: vi.fn(),
}));

vi.mock("@/lib/ai-edition/store/transcriptionStore", async (importOriginal) => {
	const actual = await importOriginal<typeof import("@/lib/ai-edition/store/transcriptionStore")>();
	return {
		...actual,
		useAssetTranscriptions: () => ({}),
		useTranscriptionStore: Object.assign(
			(select: (state: { request: unknown }) => unknown) => select({ request: actions.request }),
			{ getState: () => ({ importSrt: actions.importSrt }) },
		),
	};
});

vi.mock("@/contexts/I18nContext", () => ({
	useI18n: () => ({ locale: "en", setLocale: vi.fn() }),
	useScopedT: () => (key: string) => key,
}));

vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn(), info: vi.fn() } }));

import { toast } from "sonner";
import { TooltipProvider } from "@/components/ui/tooltip";
import { assetSchema, createEmptyDocument, transcriptSchema } from "@/lib/ai-edition/schema";
import { useProjectStore } from "@/lib/ai-edition/store/projectStore";
import { MediaStage } from "./MediaStage";

const SRT = "\uFEFF1\r\n00:00:00,250 --> 00:00:02,750\r\n繁體字幕\r\n";
const ORIGINAL_PATH = "/recordings/原始影片.mp4";
const reveal = vi.fn(async (_path: string) => ({ success: true }));

class StubResizeObserver {
	observe = vi.fn();
	unobserve = vi.fn();
	disconnect = vi.fn();
}

function withExistingTranscript() {
	const document = useProjectStore.getState().document;
	if (!document) throw new Error("Missing test document");
	useProjectStore.setState({
		document: {
			...document,
			transcripts: [
				transcriptSchema.parse({
					assetId: "asset-1",
					language: "zh",
					segments: [
						{
							id: "existing",
							kind: "speech",
							startSec: 0,
							endSec: 1,
							text: "Existing subtitles",
							wordIds: [],
						},
					],
				}),
			],
		},
	});
}

beforeEach(() => {
	vi.stubGlobal("ResizeObserver", StubResizeObserver);
	vi.stubGlobal("electronAPI", { revealInFolder: reveal });
	vi.spyOn(window, "confirm").mockReturnValue(true);
	actions.importSrt.mockReset();
	actions.importSrt.mockResolvedValue(undefined);
	actions.request.mockReset();
	reveal.mockReset();
	reveal.mockResolvedValue({ success: true });
	vi.mocked(toast.success).mockClear();
	vi.mocked(toast.error).mockClear();
	vi.mocked(toast.info).mockClear();
	const document = createEmptyDocument({ projectId: "p", title: "Test" });
	useProjectStore.setState({
		projectId: "p",
		document: {
			...document,
			assets: [
				assetSchema.parse({ id: "asset-1", label: "Take one", originalPath: ORIGINAL_PATH }),
				assetSchema.parse({ id: "asset-2", label: "Take two", originalPath: "/rec/two.mp4" }),
			],
		},
	});
});

afterEach(() => {
	cleanup();
	vi.restoreAllMocks();
	vi.unstubAllGlobals();
	useProjectStore.setState({ document: null, projectId: null });
});

async function openDetail() {
	const view = render(
		<TooltipProvider>
			<MediaStage onAddToTimeline={vi.fn(async () => undefined)} />
		</TooltipProvider>,
	);
	fireEvent.click(await screen.findByRole("button", { name: /Take one/ }));
	return {
		...view,
		input: screen.getByLabelText("mediaStage.srtFileLabel") as HTMLInputElement,
		importButton: screen.getByRole("button", { name: "mediaStage.importSrt" }),
	};
}

function chooseFile(input: HTMLInputElement, text = Promise.resolve(SRT), name = "captions.srt") {
	const file = new File([SRT], name, { type: "application/x-subrip" });
	const read = vi.fn(() => text);
	Object.defineProperty(file, "text", { value: read });
	fireEvent.change(input, { target: { files: [file] } });
	return { file, read };
}

describe("MediaStage original video and SRT actions", () => {
	it("reveals the selected original file through the existing bridge", async () => {
		await openDetail();
		fireEvent.click(screen.getByRole("button", { name: "mediaStage.revealOriginal" }));
		await waitFor(() => expect(reveal).toHaveBeenCalledWith(ORIGINAL_PATH));
		expect(actions.request).not.toHaveBeenCalled();
	});

	it("reports a failed reveal", async () => {
		reveal.mockRejectedValueOnce(new Error("File was moved"));
		await openDetail();
		fireEvent.click(screen.getByRole("button", { name: "mediaStage.revealOriginal" }));
		await waitFor(() =>
			expect(toast.error).toHaveBeenCalledWith("mediaStage.revealFailed", {
				description: "File was moved",
			}),
		);
	});

	it("imports the chosen local SRT into the selected asset without calling a transcription service", async () => {
		const { input, importButton } = await openDetail();
		expect(input).toHaveAttribute("accept", ".srt");
		fireEvent.click(importButton);
		chooseFile(input);
		await waitFor(() => expect(actions.importSrt).toHaveBeenCalledWith("asset-1", SRT));
		expect(actions.request).not.toHaveBeenCalled();
		expect(window.confirm).not.toHaveBeenCalled();
		expect(toast.success).toHaveBeenCalledWith("mediaStage.importSrtSuccess");
	});

	it("cancelling the file picker makes no changes and allows another pick", async () => {
		const { input, importButton } = await openDetail();
		fireEvent.click(importButton);
		fireEvent(input, new Event("cancel"));
		expect(actions.importSrt).not.toHaveBeenCalled();
		expect(screen.getByRole("button", { name: "mediaStage.importSrt" })).toBeEnabled();
		fireEvent.click(screen.getByRole("button", { name: "mediaStage.importSrt" }));
		chooseFile(input);
		await waitFor(() => expect(actions.importSrt).toHaveBeenCalledTimes(1));
	});

	it("does not open a picker when replacement is declined", async () => {
		withExistingTranscript();
		vi.mocked(window.confirm).mockReturnValue(false);
		const { input, importButton } = await openDetail();
		const click = vi.spyOn(input, "click");
		fireEvent.click(importButton);
		expect(window.confirm).toHaveBeenCalledWith("mediaStage.srtReplaceConfirm");
		expect(click).not.toHaveBeenCalled();
		expect(actions.importSrt).not.toHaveBeenCalled();
		expect(importButton).toBeEnabled();
	});

	it("imports over existing subtitles only after confirming replacement", async () => {
		withExistingTranscript();
		const { input, importButton } = await openDetail();
		fireEvent.click(importButton);
		chooseFile(input);
		await waitFor(() => expect(actions.importSrt).toHaveBeenCalledTimes(1));
		expect(window.confirm).toHaveBeenCalledTimes(1);
	});

	it("rejects a file-dialog result after selecting another asset", async () => {
		const { input, importButton } = await openDetail();
		fireEvent.click(importButton);
		fireEvent.click(screen.getByRole("button", { name: /Take two/ }));
		chooseFile(input);
		await waitFor(() => expect(toast.info).toHaveBeenCalledWith("mediaStage.srtSelectionChanged"));
		expect(actions.importSrt).not.toHaveBeenCalled();
	});

	it("rejects a pending read after switching projects", async () => {
		let finishRead!: (text: string) => void;
		const pendingRead = new Promise<string>((resolve) => {
			finishRead = resolve;
		});
		const { input, importButton } = await openDetail();
		fireEvent.click(importButton);
		chooseFile(input, pendingRead);
		act(() => {
			useProjectStore.setState({
				projectId: "other",
				document: createEmptyDocument({ projectId: "other", title: "Other" }),
			});
		});
		await act(async () => finishRead(SRT));
		expect(actions.importSrt).not.toHaveBeenCalled();
		expect(toast.info).toHaveBeenCalledWith("mediaStage.srtSelectionChanged");
	});

	it("does not write a pending file after the pane unmounts", async () => {
		let finishRead!: (text: string) => void;
		const pendingRead = new Promise<string>((resolve) => {
			finishRead = resolve;
		});
		const { input, importButton, unmount } = await openDetail();
		fireEvent.click(importButton);
		chooseFile(input, pendingRead);
		unmount();
		await act(async () => finishRead(SRT));
		expect(actions.importSrt).not.toHaveBeenCalled();
		expect(toast.success).not.toHaveBeenCalled();
	});

	it("asks again if a background transcription completed while the picker was open", async () => {
		const { input, importButton } = await openDetail();
		fireEvent.click(importButton);
		act(() => withExistingTranscript());
		vi.mocked(window.confirm).mockReturnValue(false);
		chooseFile(input);
		await waitFor(() => expect(window.confirm).toHaveBeenCalledTimes(1));
		expect(actions.importSrt).not.toHaveBeenCalled();
	});

	it("rejects files above the size limit before reading them", async () => {
		const { input, importButton } = await openDetail();
		fireEvent.click(importButton);
		const file = new File(["x"], "large.srt");
		Object.defineProperty(file, "size", { value: 5 * 1024 * 1024 + 1 });
		const read = vi.fn();
		Object.defineProperty(file, "text", { value: read });
		fireEvent.change(input, { target: { files: [file] } });
		await waitFor(() =>
			expect(toast.error).toHaveBeenCalledWith("mediaStage.importSrtFailed", {
				description: "mediaStage.srtTooLarge",
			}),
		);
		expect(read).not.toHaveBeenCalled();
		expect(actions.importSrt).not.toHaveBeenCalled();
	});

	it("blocks duplicate picks and regeneration while a file is being read", async () => {
		let finishRead!: (text: string) => void;
		const pendingRead = new Promise<string>((resolve) => {
			finishRead = resolve;
		});
		const { input, importButton } = await openDetail();
		const click = vi.spyOn(input, "click");
		fireEvent.click(importButton);
		fireEvent.click(importButton);
		expect(click).toHaveBeenCalledTimes(1);
		chooseFile(input, pendingRead);
		fireEvent.click(screen.getByRole("button", { name: "mediaStage.regenerate" }));
		expect(actions.request).not.toHaveBeenCalled();
		await act(async () => finishRead(SRT));
		expect(actions.importSrt).toHaveBeenCalledTimes(1);
	});

	it("reports an invalid SRT and permits trying another file", async () => {
		actions.importSrt.mockRejectedValueOnce(new Error("Invalid SRT timestamp"));
		const { input, importButton } = await openDetail();
		fireEvent.click(importButton);
		chooseFile(input);
		await waitFor(() =>
			expect(toast.error).toHaveBeenCalledWith("mediaStage.importSrtFailed", {
				description: "Invalid SRT timestamp",
			}),
		);
		expect(screen.getByRole("button", { name: "mediaStage.importSrt" })).toBeEnabled();
		expect(toast.success).not.toHaveBeenCalled();
	});
});
