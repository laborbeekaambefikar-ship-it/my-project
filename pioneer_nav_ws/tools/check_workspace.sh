#!/usr/bin/env bash
# =============================================================================
# tools/check_workspace.sh
# Static-analysis pre-flight: verifies every file in the workspace parses
# cleanly *without* requiring ROS2 to be installed. Catches the bulk of the
# typos and copy-paste mistakes before you ever invoke colcon.
#
# Exit code: 0 = all green, non-zero = something is wrong.
# =============================================================================
set -euo pipefail

WS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${WS_ROOT}/src"

echo "==> Workspace root: ${WS_ROOT}"
echo "==> Scanning ${SRC_DIR}"

failed=0

# ---- 1. Python files -- AST parse only (no imports) -------------------------
echo
echo "---- [1] Python AST parse ----------------------------------------------"
mapfile -t pyfiles < <(find "${SRC_DIR}" -name '*.py' -not -path '*/build/*' -not -path '*/install/*')
for f in "${pyfiles[@]}"; do
  if python3 -c "import ast; ast.parse(open('$f').read())" 2>/dev/null; then
    printf '  OK  %s\n' "${f#${WS_ROOT}/}"
  else
    printf '  FAIL %s\n' "${f#${WS_ROOT}/}"
    python3 -c "import ast; ast.parse(open('$f').read())" || true
    failed=1
  fi
done

# ---- 2. XML / xacro / world / package.xml -- well-formedness ----------------
echo
echo "---- [2] XML well-formedness -------------------------------------------"
mapfile -t xmlfiles < <(find "${SRC_DIR}" \
  \( -name '*.xacro' -o -name '*.world' -o -name 'package.xml' -o -name '*.urdf' \) \
  -not -path '*/build/*' -not -path '*/install/*')
for f in "${xmlfiles[@]}"; do
  if python3 -c "import xml.etree.ElementTree as ET; ET.parse('$f')" 2>/dev/null; then
    printf '  OK  %s\n' "${f#${WS_ROOT}/}"
  else
    printf '  FAIL %s\n' "${f#${WS_ROOT}/}"
    python3 -c "import xml.etree.ElementTree as ET; ET.parse('$f')" || true
    failed=1
  fi
done

# ---- 3. YAML files ----------------------------------------------------------
echo
echo "---- [3] YAML safe_load ------------------------------------------------"
mapfile -t yamlfiles < <(find "${SRC_DIR}" -name '*.yaml' -not -path '*/build/*' -not -path '*/install/*')
for f in "${yamlfiles[@]}"; do
  if python3 -c "import yaml; yaml.safe_load(open('$f'))" 2>/dev/null; then
    printf '  OK  %s\n' "${f#${WS_ROOT}/}"
  else
    printf '  FAIL %s\n' "${f#${WS_ROOT}/}"
    python3 -c "import yaml; yaml.safe_load(open('$f'))" || true
    failed=1
  fi
done

# ---- 4. Unique package names ------------------------------------------------
echo
echo "---- [4] Package-name uniqueness ---------------------------------------"
mapfile -t pkgnames < <(grep -h '<name>' "${SRC_DIR}"/*/package.xml \
  | sed -E 's|.*<name>(.*)</name>.*|\1|' | sort)
dup=$(printf '%s\n' "${pkgnames[@]}" | uniq -d)
if [[ -z "${dup}" ]]; then
  printf '  OK  %d packages, no duplicates: %s\n' "${#pkgnames[@]}" "${pkgnames[*]}"
else
  printf '  FAIL duplicate package names found: %s\n' "${dup}"
  failed=1
fi

# ---- 5. Unique node entry-points (scoutbot_navigator only -- ament_python) -
echo
echo "---- [5] Entry-point uniqueness ----------------------------------------"
ep_file="${SRC_DIR}/scoutbot_navigator/setup.py"
if [[ -f "${ep_file}" ]]; then
  mapfile -t entries < <(grep -E "^\s+'[a-zA-Z_]+\s*=" "${ep_file}" \
                        | sed -E "s/^\s+'([a-zA-Z_]+).*$/\1/")
  dup=$(printf '%s\n' "${entries[@]}" | sort | uniq -d)
  if [[ -z "${dup}" ]]; then
    printf '  OK  %d entry-points, no duplicates: %s\n' "${#entries[@]}" "${entries[*]}"
  else
    printf '  FAIL duplicate entry-points: %s\n' "${dup}"
    failed=1
  fi
fi

# ---- 6. Unit tests for the navigator (no ROS deps) -------------------------
echo
echo "---- [6] Navigator unit tests ------------------------------------------"
pushd "${SRC_DIR}/scoutbot_navigator" >/dev/null
if python3 -m pytest test/ -q 2>&1 | tee /tmp/scout_pytest.log | tail -1 | grep -q 'passed'; then
  passed=$(tail -1 /tmp/scout_pytest.log)
  printf '  OK  %s\n' "${passed}"
else
  printf '  FAIL pytest:\n'
  cat /tmp/scout_pytest.log
  failed=1
fi
popd >/dev/null

# ---- summary ---------------------------------------------------------------
echo
if [[ ${failed} -eq 0 ]]; then
  echo "==> ALL CHECKS PASSED"
  exit 0
else
  echo "==> SOME CHECKS FAILED"
  exit 1
fi
