import { app, type IpcMain, safeStorage } from "electron";
import type { TranscriptionSettingsUpdate } from "./settingsContract";
import { TranscriptionSettingsStore } from "./settingsStore";

export function registerTranscriptionSettingsIpc(ipcMain: IpcMain): TranscriptionSettingsStore {
	const store = new TranscriptionSettingsStore(app.getPath("userData"), safeStorage);
	ipcMain.handle("stt:settings:get", () => store.getSnapshot());
	ipcMain.handle("stt:settings:update", (_event, update: TranscriptionSettingsUpdate) =>
		store.update(update),
	);
	return store;
}
