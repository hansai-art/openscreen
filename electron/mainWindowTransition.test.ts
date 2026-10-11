import { describe, expect, it } from "vitest";
import { isOnlyLingeringOverlay } from "./lingeringOverlay";
import { replaceMainWindow } from "./mainWindowTransition";

function windowRegistry(withOverlay: boolean) {
	const open = new Set<TestWindow>();
	let quitRequests = 0;
	class TestWindow {
		private destroyed = false;
		constructor() {
			open.add(this);
		}
		isDestroyed() {
			return this.destroyed;
		}
		close() {
			this.destroyed = true;
			open.delete(this);
			// The application's existing last-window rules: close a lone countdown overlay,
			// then quit when there are no BrowserWindows. Closing during handover hits both.
			if (isOnlyLingeringOverlay([...open], overlay)) overlay?.close();
			if (open.size === 0) quitRequests++;
		}
	}
	const overlay = withOverlay ? new TestWindow() : null;
	return {
		create: () => new TestWindow(),
		getQuitRequests: () => quitRequests,
		getOpen: () => [...open],
	};
}

describe("main window handover", () => {
	it.each([
		false,
		true,
	])("keeps the app open while replacing its last window (countdown overlay: %s)", (withOverlay) => {
		const windows = windowRegistry(withOverlay);
		const previous = windows.create();
		const next = replaceMainWindow(previous, windows.create, (window) => window.close());

		expect(windows.getQuitRequests()).toBe(0);
		expect(previous.isDestroyed()).toBe(true);
		expect(next.isDestroyed()).toBe(false);
		expect(windows.getOpen()).toContain(next);
	});

	it("keeps the existing window usable if its replacement cannot be created", () => {
		const windows = windowRegistry(false);
		const previous = windows.create();
		expect(() =>
			replaceMainWindow(
				previous,
				() => {
					throw new Error("Could not create the HUD");
				},
				(window) => window.close(),
			),
		).toThrow("Could not create the HUD");
		expect(previous.isDestroyed()).toBe(false);
		expect(windows.getQuitRequests()).toBe(0);
	});

	it("still quits when the user closes the replacement window", () => {
		const windows = windowRegistry(false);
		const previous = windows.create();
		const next = replaceMainWindow(previous, windows.create, (window) => window.close());
		next.close();
		expect(windows.getOpen()).toHaveLength(0);
		expect(windows.getQuitRequests()).toBe(1);
	});
});
