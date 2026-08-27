import React from "react";
import { createRoot } from "react-dom/client";
import { Excalidraw, CaptureUpdateAction } from "@excalidraw/excalidraw";

let excalidrawAPI = null;
let readyPosted = false;

function postToSwift(message) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.excalidrawBridge) {
    window.webkit.messageHandlers.excalidrawBridge.postMessage(message);
  } else {
    // Not running inside the WKWebView bridge (e.g. plain Safari during the
    // spike) - log instead so the spike is visually verifiable without Swift.
    console.log("[bridge]", JSON.stringify(message));
  }
}

// Excalidraw's onChange fires on every micro-change (each point of a
// drag, etc). Swift only needs to know "something changed, start the
// autosave debounce" - not the payload - so throttle to one ping per
// window rather than posting (and JSON-stringifying a message) on every
// callback.
let changeThrottleTimer = null;
function notifyChanged() {
  if (changeThrottleTimer) return;
  changeThrottleTimer = setTimeout(() => {
    changeThrottleTimer = null;
  }, 800);
  postToSwift({ type: "changed" });
}

function App() {
  return React.createElement(Excalidraw, {
    excalidrawAPI: (api) => {
      excalidrawAPI = api;
      if (!readyPosted) {
        readyPosted = true;
        postToSwift({ type: "ready" });
      }
    },
    onChange: () => {
      if (readyPosted) notifyChanged();
    },
  });
}

const root = createRoot(document.getElementById("app"));
root.render(React.createElement(App));

// --- Bridge API called from Swift via callAsyncJavaScript ---

window.mystnotesLoadScene = function (jsonString) {
  if (!excalidrawAPI) return;
  const scene = JSON.parse(jsonString);
  const elements = scene.elements || [];
  excalidrawAPI.updateScene({
    elements,
    appState: scene.appState || {},
    // This is scene initialization, not a live edit - without this, the
    // load itself becomes undoable, so Cmd/Ctrl+Z right after opening a
    // page would wipe it back to blank instead of undoing an actual stroke.
    captureUpdate: CaptureUpdateAction.NEVER,
  });
  // mystnotesExportScene() intentionally doesn't round-trip scrollX/scrollY/
  // zoom (only viewBackgroundColor), so a freshly-mounted Excalidraw
  // instance's default viewport won't necessarily be looking at wherever
  // the content actually is. Recenter on it explicitly instead of relying
  // on preserved scroll state.
  if (elements.length > 0) {
    excalidrawAPI.scrollToContent(elements, { fitToViewport: true, animate: false });
  }
};

window.mystnotesExportScene = function () {
  if (!excalidrawAPI) return JSON.stringify({ elements: [], appState: {} });
  const elements = excalidrawAPI.getSceneElements();
  const appState = excalidrawAPI.getAppState();
  return JSON.stringify({
    elements,
    appState: { viewBackgroundColor: appState.viewBackgroundColor },
  });
};

window.mystnotesExtractText = function () {
  if (!excalidrawAPI) return "";
  const elements = excalidrawAPI.getSceneElements();
  return elements
    .filter((el) => el.type === "text" && !el.isDeleted)
    .map((el) => el.text)
    .join("\n");
};
