// Build identity rules for the application-owned release recipe (see build.mjs).
// Source revision, build ID, replay contract and artifact location stay separate values.
import { access } from "node:fs/promises";

export const developmentBuild = "membership-screen-v2-dev";
export const contract = "membership-screen-v2";

// A release build ID is supplied by CI or allocated locally. It never equals the
// mutable development ID, because that build cannot preserve historical code.
export function releaseBuildId(supplied, allocate) {
  const id = supplied || allocate();
  if (!/^[a-zA-Z0-9_-]{1,100}$/.test(id) || id === developmentBuild)
    throw Error(
      "Use a unique release build ID (letters, digits, underscore, hyphen)",
    );
  return id;
}

// An existing build ID is refused so a later build cannot overwrite the renderer a
// recording was made with.
export async function refuseExisting(artifactDirectory) {
  try {
    await access(artifactDirectory);
  } catch (error) {
    if (error.code === "ENOENT") return;
    throw error;
  }
  throw Error("Build ID already published locally; choose a new ID");
}

// The manifest maps one build ID to its preserved replay artifact and records source
// provenance. No source file contains its own future commit hash.
export function artifactManifest({ id, revision, dirty }) {
  return {
    api: 1,
    build: id,
    contract,
    source_revision: revision,
    source_dirty: dirty,
    url: `/artifacts/${id}/frame.html`,
  };
}
