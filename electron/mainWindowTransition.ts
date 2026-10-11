/** The window operations needed for a HUD/editor handover, without importing Electron. */
export type MainWindow = { isDestroyed(): boolean };

/** Creates the replacement before closing the last window, which would quit the app. */
export function replaceMainWindow<T extends MainWindow>(
	previous: T | null,
	createNext: () => T,
	closePrevious: (window: T) => void,
): T {
	const next = createNext();
	if (previous && !previous.isDestroyed()) {
		closePrevious(previous);
	}
	return next;
}
