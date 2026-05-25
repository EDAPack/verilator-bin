#!/usr/bin/env python3
"""Stage Agent Skills from a source package into a release tree.

Reads a `skill-manifest.yaml`, validates each listed skill (frontmatter,
referenced binaries present in the release), copies the skill directory
into `<dest>/<name>/`, and writes `<dest>/index.json` summarizing what
shipped.

Used by each package's `scripts/build.sh` after the release directory
has been populated and before the tarball is created.

Manifest schema (minimal):

    skills:
      - name: yosys
        path: skills/yosys           # relative to --source-root
        binaries: [yosys]            # must exist in <release>/bin/
      - name: sby
        path: skills/sby
        binaries: [sby]

SKILL.md frontmatter required keys: name, description, version.

Exit codes:
  0  success
  1  manifest / validation / copy failure
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path

# Frontmatter parsing — we accept a tiny YAML subset (key: value, one per
# line) so we don't need a PyYAML dependency in the build container.
# The manifest itself is parsed by the same routine.

_FRONT_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)


def _parse_simple_yaml(text: str) -> dict:
    """Parse the subset of YAML we use: scalars and one-line flow lists.

    Supports:
        key: value
        key: [a, b, c]
        # comments and blank lines
        nested blocks one level deep ("skills:" then "- name: ...")
    """
    root: dict = {}
    stack: list = [(0, root)]  # (indent, container)
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        raw = lines[i]
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            i += 1
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        # pop stack to current indent
        while stack and indent < stack[-1][0]:
            stack.pop()
        container = stack[-1][1]

        if stripped.startswith("- "):
            # list item
            item_body = stripped[2:]
            if isinstance(container, list):
                if ":" in item_body:
                    k, v = item_body.split(":", 1)
                    item: dict = {}
                    item[k.strip()] = _parse_scalar(v.strip())
                    container.append(item)
                    stack.append((indent + 2, item))
                else:
                    container.append(_parse_scalar(item_body))
            else:
                raise ValueError(f"unexpected list item at line {i+1}: {raw!r}")
        elif ":" in stripped:
            k, v = stripped.split(":", 1)
            k = k.strip()
            v = v.strip()
            if v == "":
                # block — could be dict or list; decide by next non-blank line
                j = i + 1
                while j < len(lines) and not lines[j].strip():
                    j += 1
                if j < len(lines) and lines[j].lstrip().startswith("- "):
                    new: list = []
                else:
                    new = {}
                if isinstance(container, dict):
                    container[k] = new
                else:
                    raise ValueError(f"key in non-dict at line {i+1}")
                stack.append((indent + 2, new))
            else:
                if isinstance(container, dict):
                    container[k] = _parse_scalar(v)
                else:
                    raise ValueError(f"key in non-dict at line {i+1}")
        else:
            raise ValueError(f"cannot parse line {i+1}: {raw!r}")
        i += 1
    return root


def _parse_scalar(v: str):
    v = v.strip()
    if v.startswith("[") and v.endswith("]"):
        body = v[1:-1].strip()
        if not body:
            return []
        return [_parse_scalar(p) for p in body.split(",")]
    if (v.startswith('"') and v.endswith('"')) or (
        v.startswith("'") and v.endswith("'")
    ):
        return v[1:-1]
    if v.lower() in {"true", "false"}:
        return v.lower() == "true"
    if v.lower() in {"null", "~", ""}:
        return None
    try:
        return int(v)
    except ValueError:
        pass
    try:
        return float(v)
    except ValueError:
        pass
    return v


def _parse_frontmatter(skill_md: Path) -> dict:
    text = skill_md.read_text(encoding="utf-8")
    m = _FRONT_RE.match(text)
    if not m:
        raise ValueError(f"{skill_md}: missing YAML frontmatter")
    return _parse_simple_yaml(m.group(1))


@dataclass
class SkillEntry:
    name: str
    path: Path
    binaries: list[str]
    description: str
    version: str


def _validate(
    manifest_path: Path, source_root: Path, release_root: Path
) -> list[SkillEntry]:
    manifest = _parse_simple_yaml(manifest_path.read_text(encoding="utf-8"))
    skills_raw = manifest.get("skills") or []
    if not skills_raw:
        return []
    bin_dir = release_root / "bin"
    entries: list[SkillEntry] = []
    for s in skills_raw:
        for required in ("name", "path"):
            if required not in s:
                raise ValueError(f"manifest entry missing '{required}': {s}")
        name = s["name"]
        skill_dir = (source_root / s["path"]).resolve()
        if not skill_dir.is_dir():
            raise ValueError(f"skill '{name}': directory not found: {skill_dir}")
        skill_md = skill_dir / "SKILL.md"
        if not skill_md.is_file():
            raise ValueError(f"skill '{name}': missing SKILL.md")
        fm = _parse_frontmatter(skill_md)
        for required in ("name", "description", "version"):
            if not fm.get(required):
                raise ValueError(
                    f"skill '{name}': SKILL.md frontmatter missing '{required}'"
                )
        if fm["name"] != name:
            raise ValueError(
                f"skill '{name}': SKILL.md frontmatter name='{fm['name']}' "
                f"does not match manifest name"
            )
        binaries = s.get("binaries") or []
        for b in binaries:
            if not (bin_dir / b).exists() and not (bin_dir / f"{b}.exe").exists():
                raise ValueError(
                    f"skill '{name}': declared binary '{b}' not found in "
                    f"{bin_dir}"
                )
        entries.append(
            SkillEntry(
                name=name,
                path=skill_dir,
                binaries=list(binaries),
                description=fm["description"],
                version=str(fm["version"]),
            )
        )
    return entries


def _stage(entries: list[SkillEntry], dest: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    for e in entries:
        target = dest / e.name
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(e.path, target, ignore=shutil.ignore_patterns(".research.md"))
        print(f"  staged skill: {e.name} ({len(e.binaries)} binaries)")
    index = {
        "schema": "edapack.skills/1",
        "skills": [
            {
                "name": e.name,
                "description": e.description,
                "version": e.version,
                "binaries": e.binaries,
                "path": e.name,
            }
            for e in entries
        ],
    }
    (dest / "index.json").write_text(json.dumps(index, indent=2) + "\n")
    print(f"  wrote {dest / 'index.json'}")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--manifest", required=True, type=Path)
    p.add_argument(
        "--source-root",
        required=True,
        type=Path,
        help="Package source root (where skills/ lives).",
    )
    p.add_argument(
        "--release-root",
        required=True,
        type=Path,
        help="Release directory (must contain bin/).",
    )
    p.add_argument(
        "--dest",
        required=True,
        type=Path,
        help="Destination skills directory (usually <release-root>/skills).",
    )
    args = p.parse_args()
    try:
        entries = _validate(args.manifest, args.source_root, args.release_root)
    except ValueError as exc:
        print(f"stage-skills: {exc}", file=sys.stderr)
        return 1
    if not entries:
        print("stage-skills: manifest lists no skills; nothing to do")
        return 0
    _stage(entries, args.dest)
    print(f"stage-skills: staged {len(entries)} skill(s) into {args.dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
