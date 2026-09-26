#!/usr/bin/env python3
"""Regenerate docs/.well-known/agent-skills/index.json from the SKILL.md files
next to it (Agent Skills Discovery v0.2.0). Run after editing a skill: the
index carries each file's sha256, and a stale digest makes agents reject it."""
import hashlib, json, pathlib, re

root = pathlib.Path(__file__).resolve().parent.parent / "docs/.well-known/agent-skills"
skills = []
for md in sorted(root.glob("*/SKILL.md")):
    text = md.read_text()
    desc = re.search(r"^description:\s*(.+)$", text, re.M).group(1).strip()
    skills.append({
        "name": md.parent.name,
        "type": "skill-md",
        "description": desc,
        "url": f"/.well-known/agent-skills/{md.parent.name}/SKILL.md",
        "digest": "sha256:" + hashlib.sha256(md.read_bytes()).hexdigest(),
    })
index = {"$schema": "https://schemas.agentskills.io/discovery/0.2.0/schema.json", "skills": skills}
(root / "index.json").write_text(json.dumps(index, indent=2, ensure_ascii=False) + "\n")
print(f"{len(skills)} skill(s) indexed")
