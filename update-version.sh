#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#gh nixpkgs#jq nixpkgs#gnused nixpkgs#nix-prefetch-github --command bash

# Pins pin.nix to a specific (or the latest) release of Casvt/Kapowarr, re-validates the source hash, and pins the bencoding sub-flake input in flake.nix to the right aggregate branch (e.g., v0.2) based on upstream's bencoding constraint in requirements.txt. Run from the flake root:
#
#   nix run .#update-version              # latest GitHub release
#   nix run .#update-version -- 1.3.1     # specific version (no V prefix)
#
# Always recomputes hashes and rewrites pin.nix/flake.nix if anything changed; that means it doubles as a "re-validate this exact pin" pass.

set -euo pipefail

FLAKE_ROOT="${FLAKE_ROOT:-${PWD}}"
pin="${FLAKE_ROOT}/pin.nix"
flake="${FLAKE_ROOT}/flake.nix"
repo_owner=Casvt
repo_name=Kapowarr

if [[ ! -f "${pin}" ]]; then
  echo "error: no pin.nix in ${FLAKE_ROOT}" >&2
  exit 1
fi

if [[ $# -ge 1 && -n "${1}" ]]; then
  new_version="${1#[Vv]}"
  echo "Using requested version: ${new_version}"
else
  echo "Querying GitHub for latest release of ${repo_owner}/${repo_name}..."
  release=$(gh api "/repos/${repo_owner}/${repo_name}/releases/latest")
  new_version=$(jq -r '.tag_name' <<<"${release}")
  new_version="${new_version#[Vv]}"
fi

# Upstream tags are V<version> (capital V); also try v<version> and bare for older tags.
new_rev=""
new_tag=""
for candidate in "V${new_version}" "v${new_version}" "${new_version}"; do
  if sha=$(gh api "/repos/${repo_owner}/${repo_name}/commits/${candidate}" --jq '.sha' 2>/dev/null); then
    new_rev="${sha}"; new_tag="${candidate}"; break
  fi
done
if [[ -z "${new_rev}" ]]; then
  echo "error: could not resolve any of V${new_version} / v${new_version} / ${new_version} on ${repo_owner}/${repo_name}" >&2
  exit 1
fi

cur_version=$(nix eval --raw --file "${pin}" version 2>/dev/null || echo "")
cur_rev=$(nix eval --raw --file "${pin}" sourceRev 2>/dev/null || echo "")
cur_hash=$(nix eval --raw --file "${pin}" sourceHash 2>/dev/null || echo "")

echo "  current: ${cur_version} (${cur_rev:-<empty>})"
echo "  target:  ${new_version} (${new_rev}) [tag ${new_tag}]"

echo "Computing source hash..."
new_source_hash=$(nix-prefetch-github --rev "${new_rev}" "${repo_owner}" "${repo_name}" --json | jq -r '.hash // .sha256')

pin_changed=0
if [[ "${cur_version}" != "${new_version}" || "${cur_rev}" != "${new_rev}" || "${cur_hash}" != "${new_source_hash}" ]]; then
  pin_changed=1
  echo "Writing pin.nix..."
  cat > "${pin}" <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${new_version}";
  sourceRev = "${new_rev}";
  sourceHash = "${new_source_hash}";
}
EOF
fi

# --- Resolve upstream bencoding constraint and pin bencoding-flake to the right aggregate branch ---
echo "Fetching upstream requirements.txt at ${new_rev}..."
req_text=$(gh api "/repos/${repo_owner}/${repo_name}/contents/requirements.txt?ref=${new_rev}" --jq '.content' | base64 -d || true)

if [[ -z "${req_text}" ]]; then
  echo "warning: could not fetch requirements.txt; bencoding URL in flake.nix left unchanged." >&2
else
  bencoding_spec=$(printf '%s\n' "${req_text}" | sed -nE 's/^bencoding(\[[^]]*\])?[[:space:]]*([~<>=!].*)$/\2/p' | head -1)
  if [[ -z "${bencoding_spec}" ]]; then
    echo "warning: no bencoding line in requirements.txt; bencoding URL left unchanged." >&2
  else
    echo "  upstream constraint: bencoding ${bencoding_spec}"
    bencoding_ref=$(python3 - "${bencoding_spec}" <<'PY'
import json, sys, urllib.request
from packaging.specifiers import SpecifierSet
from packaging.version import InvalidVersion, Version

spec = SpecifierSet(sys.argv[1])
data = json.loads(urllib.request.urlopen("https://pypi.org/pypi/bencoding/json").read())
candidates = []
for raw in data["releases"]:
    try:
        v = Version(raw)
    except InvalidVersion:
        continue
    if v.is_prerelease or v.is_devrelease:
        continue
    if v in spec:
        candidates.append(v)
if not candidates:
    sys.exit(0)
top = max(candidates)
# If the specifier set contains a literal == X.Y.Z, pin to that exact aggregate branch.
exacts = [s for s in spec if s.operator == "=="]
if exacts:
    print(f"v{top.public}")
else:
    print(f"v{top.major}.{top.minor}")
PY
)
    if [[ -z "${bencoding_ref}" ]]; then
      echo "warning: could not resolve bencoding constraint '${bencoding_spec}' against PyPI; bencoding URL left unchanged." >&2
    else
      echo "  resolved to: github:jgus/bencoding-flake/${bencoding_ref}"
      # Rewrite the bencoding url line in flake.nix. Match `url = "github:jgus/bencoding-flake[/<old-ref>]"` and replace with the chosen ref.
      sed -i -E "s|(url = \"github:jgus/bencoding-flake)(/[^\"]*)?(\")|\\1/${bencoding_ref}\\3|" "${flake}"
    fi
  fi
fi

echo "Verifying kapowarr build..."
nix build --option post-build-hook "" "${FLAKE_ROOT}#kapowarr" --no-link

echo
if (( pin_changed )); then
  echo "Updated to ${new_version} (${new_rev})"
else
  echo "pin.nix unchanged (${new_version} / ${new_source_hash:0:20}...)"
fi
echo "  Commit pin.nix / flake.nix / flake.lock to capture."
