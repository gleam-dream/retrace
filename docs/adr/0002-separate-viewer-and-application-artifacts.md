# Separate the viewer from the application artifact

<a id="adr-0002"></a>

On 2026-10-10 the user approved a separate viewer endpoint, complete application
viewport and timestamp-based playback. A replay module owns codecs, reduction and
the shared root view. Its compiled artifact travels with the application build.
The viewer owns session navigation, playback time and artifact selection.

The example keeps this boundary outside the portable core. A trusted local iframe
isolates the historical document and CSS, but is not a sandbox for hostile code.
The host validates origin, frame source, protocol and build before sending a log.
Missing historical artifacts fail visibly rather than using today's frontend.

The application stores presentation observations in its existing opaque payloads.
This avoids requiring every Retrace consumer to adopt browser concepts. The
example captures viewport, safe area and route; it cannot reconstruct OS sheets.

The first player retains a bounded set of validated snapshots. This is sufficient
for the local experiment, with explicit refusal beyond its limit. A future optional
viewer package can own a controller and default view after a second consumer
proves the API. Storage, authentication and artifact hosting stay caller-owned.
