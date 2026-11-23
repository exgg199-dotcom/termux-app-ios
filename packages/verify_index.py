import hashlib
import json
import sys
import urllib.request


def verify_file(entry):
    if "text" in entry:
        return None
    expected_hash = entry.get("sha256")
    if not expected_hash:
        return "missing sha256 for " + entry["path"]
    last_error = "no download URL for " + entry["path"]
    for url in entry.get("urls", []):
        digest = hashlib.sha256()
        size = 0
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "termux-ios-verify-index"})
            with urllib.request.urlopen(request, timeout=120) as response:
                while True:
                    chunk = response.read(1 << 20)
                    if not chunk:
                        break
                    digest.update(chunk)
                    size += len(chunk)
        except Exception as error:
            last_error = url + ": " + str(error)
            continue
        if "size" in entry and entry["size"] != size:
            return "{}: size {} differs from {}".format(url, size, entry["size"])
        if digest.hexdigest() != expected_hash.lower():
            return "{}: sha256 {} differs from {}".format(url, digest.hexdigest(), expected_hash)
        return None
    return last_error


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "packages/index.json"
    with open(path, encoding="utf-8") as handle:
        index = json.load(handle)
    failures = 0
    for package in index["packages"]:
        problems = [problem for problem in (verify_file(entry) for entry in package["files"]) if problem]
        for command, target in package.get("commands", {}).items():
            if not any(entry["path"] == target for entry in package["files"]):
                problems.append("command {} points to missing file {}".format(command, target))
        if problems:
            failures += 1
            print("FAIL {} {}".format(package["name"], "; ".join(problems)))
        else:
            print("OK {}".format(package["name"]))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
