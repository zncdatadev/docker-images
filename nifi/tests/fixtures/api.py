"""Exercise the real NiFi REST API, with bounded HTTP requests."""
import json
import sys
import urllib.request


def request(path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        "http://127.0.0.1:8080/nifi-api/" + path,
        data=data,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=5) as response:
        return json.load(response)


mode = sys.argv[1]
if mode == "ready":
    about = request("flow/about")["about"]
    assert about["version"] == "2.4.0", about
    root = request("process-groups/root")["component"]
    print(root["id"])
elif mode == "create":
    root = request("process-groups/root")["component"]
    group = request(
        "process-groups/" + root["id"] + "/process-groups",
        {
            "revision": {"version": 0},
            "component": {
                "name": "lifecycle-persistence",
                "position": {"x": 0, "y": 0},
            },
        },
    )["component"]
    assert group["name"] == "lifecycle-persistence", group
    print(group["id"])
elif mode == "check":
    group = request("process-groups/" + sys.argv[2])["component"]
    assert group["id"] == sys.argv[2], group
    assert group["name"] == "lifecycle-persistence", group
    print(group["id"])
else:
    raise ValueError(mode)
