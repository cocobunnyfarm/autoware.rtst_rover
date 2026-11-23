#!/usr/bin/env python3
"""models.py — 인지 모델(.onnx) 점검·받기.  rover models check|fetch 가 부른다 (호스트에서, 표준 라이브러리만).

모델 목록과 판(revision)은 이 repo 의 ansible/roles/artifacts/tasks/main.yaml 을 그대로 읽는다
(Autoware 릴리스가 고정한 것 — 릴리스를 올리면 같이 바뀐다). 받는 곳은 Hugging Face AutowareFoundation/<이름>.

  models.py check            목록 전체: 받았는지, 받은 판이 고정된 판과 같은지
  models.py fetch <이름>...  고정된 판을 받아 대조 (큰 파일 sha256, 작은 파일 git blob sha1). 이미 맞는 파일은 건너뛴다
받은 폴더에 .rover_revision (받은 판) 을 남긴다. 엔진(.engine)은 여기서 다루지 않는다 — rover models build.
"""
import hashlib
import json
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
PINS = os.path.join(ROOT, "ansible/roles/artifacts/tasks/main.yaml")
DATA = os.environ.get("ROVER_MODELS_DIR", os.path.expanduser("~/autoware_data/ml_models"))
HF = "https://huggingface.co"
ORG = "AutowareFoundation"
STAMP = ".rover_revision"


def pins():
    """[(repo, revision, dest)] — main.yaml 의 '- { repo: X, revision: Y, dest: Z }' 줄."""
    out = []
    for line in open(PINS, encoding="utf-8"):
        m = re.match(r"\s*-\s*\{\s*repo:\s*([\w.-]+),\s*revision:\s*([\w.-]+)(?:,\s*dest:\s*([\w./-]+))?\s*\}", line)
        if m:
            out.append((m.group(1), m.group(2), m.group(3) or m.group(1)))
    if not out:
        sys.exit(f"모델 목록을 못 읽었다: {PINS}")
    return out


def local_revision(dest):
    """받은 판. 우리 표시 파일 → 없으면 모델 묶음의 deploy_metadata.yaml (손으로 받은 옛 폴더)."""
    d = os.path.join(DATA, dest)
    if not os.path.isdir(d):
        return None, ""
    p = os.path.join(d, STAMP)
    if os.path.isfile(p):
        return open(p).read().strip(), ""
    p = os.path.join(d, "deploy_metadata.yaml")
    if os.path.isfile(p):
        m = re.search(r"version:\s*([\w.]+)", open(p).read())
        if m:
            return m.group(1), "대조 안 함"
    return "?", "판을 모름"


def cmd_check():
    bad = 0
    print(f"모델 폴더: {DATA}")
    print(f"  {'이름':<38}{'고정된 판':<10}{'받은 판':<10}상태")
    for repo, rev, dest in pins():
        have, note = local_revision(dest)
        if have is None:
            state = "없음"
        elif have == rev:
            state = "맞음" + (f" ({note} — fetch 하면 파일까지 대조)" if note else "")
        else:
            state = f"다름 → rover models fetch {dest}"
            bad += 1
        print(f"  {dest:<38}{rev:<10}{have or '-':<10}{state}")
    print("  '없음'은 그 모델을 쓸 때 받으면 된다:  rover models fetch <이름>")
    return 1 if bad else 0


def git_blob_sha1(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def file_ok(path, entry):
    if not os.path.isfile(path) or os.path.getsize(path) != entry["size"]:
        return False
    data = open(path, "rb").read()
    lfs = entry.get("lfs")
    return hashlib.sha256(data).hexdigest() == lfs["oid"] if lfs else git_blob_sha1(data) == entry["oid"]


def fetch_one(repo, rev, dest):
    d = os.path.join(DATA, dest)
    url = f"{HF}/api/models/{ORG}/{repo}/tree/{rev}?recursive=true"
    tree = [e for e in json.load(urllib.request.urlopen(url)) if e["type"] == "file"]
    total = sum(e["size"] for e in tree)
    print(f"{dest}  ({ORG}/{repo} {rev}, 파일 {len(tree)}개, {total / 1e6:.0f} MB)")
    got = 0
    for e in tree:
        path = os.path.join(d, e["path"])
        if file_ok(path, e):
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with urllib.request.urlopen(f"{HF}/{ORG}/{repo}/resolve/{rev}/{e['path']}") as r, open(path + ".part", "wb") as f:
            while chunk := r.read(1 << 20):
                f.write(chunk)
        if not file_ok(path + ".part", e):
            os.remove(path + ".part")
            sys.exit(f"  받은 파일이 대조와 다르다: {e['path']}")
        os.replace(path + ".part", path)
        got += 1
        print(f"  받음  {e['path']}  ({e['size'] / 1e6:.1f} MB)")
    open(os.path.join(d, STAMP), "w").write(rev + "\n")
    print(f"  맞음: 파일 {len(tree)}개 대조 끝 (새로 받은 것 {got}개)")


def cmd_fetch(names):
    table = {dest: (repo, rev, dest) for repo, rev, dest in pins()}
    if not names:
        sys.exit("받을 모델 이름을 준다 (rover models check 의 이름).  전부: rover models fetch all")
    if names == ["all"]:
        names = list(table)
    for n in names:
        if n not in table:
            sys.exit(f"목록에 없는 모델: {n}  (rover models check 로 이름 확인)")
    for n in names:
        fetch_one(*table[n])
    return 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["check"]:
        sys.exit(cmd_check())
    if a[:1] == ["fetch"]:
        sys.exit(cmd_fetch(a[1:]))
    sys.exit(__doc__)
