"""Public HTTP evidence for ordered ingestion, exact retries and S3 readback."""

import concurrent.futures
import json
import os
import urllib.error
import urllib.request
import uuid

BASE = os.environ.get("RETRACE_ENDPOINT", "http://127.0.0.1:4417")


def call(path, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(
        BASE + path, data=data, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)


def batch(session, start, kind="Increment"):
    return {
        "format": 1,
        "session": session,
        "checkpoint": {
            "sequence": start,
            "elapsed_ms": start * 10,
            "model": json.dumps(
                {"points": start, "compact": False, "device": "Not requested"}
            ),
        },
        "entries": [
            {
                "sequence": start + 1,
                "elapsed_ms": (start + 1) * 10,
                "kind": kind,
                "payload": "",
            }
        ],
    }


if __name__ == "__main__":
    session = {
        "id": "check-" + uuid.uuid4().hex,
        "user_ref": "backend-check",
        "build": "membership-v1",
        "contract": "membership-v1",
        "platform": "test",
    }
    first, second = batch(session, 0), batch(session, 1)
    assert call("/batches", second)[0] == 409
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        replies = list(pool.map(lambda _: call("/batches", first), range(4)))
    assert all(status == 200 and data["ack"] == 1 for status, data in replies), replies
    assert call("/batches", batch(session, 0, "Conflicting"))[0] == 409
    assert call("/batches", second) == (200, {"session_id": session["id"], "ack": 2})
    status, sessions = call("/sessions?user=backend-check")
    assert status == 200 and any(
        s["session"]["id"] == session["id"] and s["sequence"] == 2 for s in sessions
    )
    for _ in range(1000):
        status, result = call("/archive", {})
        assert status == 200, result
        if not result["archived"]:
            break
    else:
        raise AssertionError("Archive did not drain")
    status, batches = call(f"/sessions/{session['id']}/batches")
    assert status == 200 and [json.loads(value) for value in batches] == [first, second]
    assert call("/batches", first)[0] == 200, (
        "Duplicate must work after payload archival"
    )
    malformed = batch(session, 2)
    malformed["entries"][0]["sequence"] = 5
    assert call("/batches", malformed)[0] == 400
    print(
        "PASS concurrent exact retries, conflicts, order, indexed search, signed S3 archival/readback and post-archive retry"
    )
    print("Session retained for restart verification:", session["id"])
