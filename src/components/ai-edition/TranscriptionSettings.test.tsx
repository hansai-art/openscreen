// @vitest-environment jsdom
import "@testing-library/jest-dom";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { I18nProvider } from "@/contexts/I18nContext";
import { LOCALE_STORAGE_KEY } from "@/i18n/config";
import { TranscriptionSettings } from "./TranscriptionSettings";

const getSettings = vi.fn();
const updateSettings = vi.fn();
beforeEach(() => {
	localStorage.setItem(LOCALE_STORAGE_KEY, "zh-TW");
	getSettings.mockResolvedValue({ provider: "whisper", cloudConsent: false, hasApiKey: false });
	updateSettings.mockResolvedValue({ provider: "gmi", cloudConsent: true, hasApiKey: true });
	Object.defineProperty(window, "electronAPI", {
		configurable: true,
		value: { stt: { getSettings, updateSettings } },
	});
});
afterEach(() => {
	cleanup();
	vi.clearAllMocks();
	localStorage.clear();
});
describe("TranscriptionSettings", () => {
	it("requires a credential and explicit audio upload consent before saving GMI", async () => {
		render(
			<I18nProvider>
				<TranscriptionSettings open />
			</I18nProvider>,
		);
		await screen.findByRole("combobox", { name: "轉錄引擎" });
		fireEvent.change(screen.getByRole("combobox"), { target: { value: "gmi" } });
		const save = screen.getByRole("button", { name: "儲存轉錄設定" });
		expect(save).toBeDisabled();
		fireEvent.change(screen.getByLabelText("GMI API 金鑰"), { target: { value: "private-token" } });
		expect(save).toBeDisabled();
		fireEvent.click(screen.getByRole("checkbox"));
		fireEvent.click(save);
		await waitFor(() =>
			expect(updateSettings).toHaveBeenCalledWith({
				provider: "gmi",
				cloudConsent: true,
				apiKey: "private-token",
			}),
		);
		await waitFor(() => expect(screen.getByLabelText("GMI API 金鑰")).toHaveValue(""));
	});
	it("never requires the stored key to be returned to the renderer", async () => {
		getSettings.mockResolvedValue({ provider: "gmi", cloudConsent: true, hasApiKey: true });
		render(
			<I18nProvider>
				<TranscriptionSettings open />
			</I18nProvider>,
		);
		await screen.findByText("金鑰已設定");
		expect(screen.getByLabelText("GMI API 金鑰")).toHaveAttribute("type", "password");
		fireEvent.click(screen.getByRole("button", { name: "儲存轉錄設定" }));
		await waitFor(() =>
			expect(updateSettings).toHaveBeenCalledWith({ provider: "gmi", cloudConsent: true }),
		);
	});
	it("disconnects GMI and revokes automatic upload consent together", async () => {
		getSettings.mockResolvedValue({ provider: "gmi", cloudConsent: true, hasApiKey: true });
		render(
			<I18nProvider>
				<TranscriptionSettings open />
			</I18nProvider>,
		);
		await screen.findByRole("button", { name: "移除 GMI 金鑰" });
		fireEvent.click(screen.getByRole("button", { name: "移除 GMI 金鑰" }));
		await waitFor(() =>
			expect(updateSettings).toHaveBeenCalledWith({
				provider: "whisper",
				cloudConsent: false,
				apiKey: "",
			}),
		);
	});
});
