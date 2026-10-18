#!/usr/bin/env bash
# Behaviour tests for the shared check scripts in checks/.
# Run inside the built image (all tools present) or on a host with bash and git:
# cases that need a missing tool are skipped and reported.
# No `set -e`: every case runs and failures are counted at the end.
set -uo pipefail

CHECKS_DIR="$(cd "${CHECKS_DIR:-$(dirname "$0")/../checks}" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
skipped=0

ok() {
  pass=$((pass + 1))
  echo "ok   $1"
}
bad() {
  fail=$((fail + 1))
  echo "FAIL $1"
}
skip() {
  skipped=$((skipped + 1))
  echo "skip $1 (needs $2)"
}

# expect <name> <exit-code> <command...>
expect() {
  local name="$1" want="$2"
  shift 2
  local out got
  out="$("$@" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ]; then
    ok "$name"
  else
    bad "$name (wanted exit $want, got $got)"
    echo "$out" | sed 's/^/     /'
  fi
}

# expect_output <name> <pattern> <command...>: output must match the pattern
expect_output() {
  local name="$1" pattern="$2"
  shift 2
  local out
  out="$("$@" 2>&1)"
  if grep -qE "$pattern" <<<"$out"; then
    ok "$name"
  else
    bad "$name (output lacks /$pattern/)"
    echo "$out" | sed 's/^/     /'
  fi
}

new_repo() {
  local dir="$work/$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name "Test"
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config commit.gpgsign false
  echo "$dir"
}

commit_file() { # <repo> <file> <message>
  echo "$RANDOM" >>"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "$3"
}

# ── commit-messages.sh ────────────────────────────────────────────────────────
cm="$CHECKS_DIR/commit-messages.sh"

repo="$(new_repo cm-good)"
commit_file "$repo" a "base"
base="$(git -C "$repo" rev-parse HEAD)"
commit_file "$repo" b "$(printf 'feat: add b\n\nSigned-off-by: Test <test@example.com>')"
expect "commit-messages: signed commit passes" 0 bash -c "cd '$repo' && '$cm' '$base'"

repo="$(new_repo cm-attr)"
commit_file "$repo" a "base"
base="$(git -C "$repo" rev-parse HEAD)"
commit_file "$repo" b "$(printf 'feat: add b\n\nSigned-off-by: Test <test@example.com>\nCo-Authored-By: Someone <x@example.com>')"
expect "commit-messages: Co-Authored-By trailer fails" 1 bash -c "cd '$repo' && '$cm' '$base'"

repo="$(new_repo cm-gen)"
commit_file "$repo" a "base"
base="$(git -C "$repo" rev-parse HEAD)"
commit_file "$repo" b "$(printf 'feat: add b\n\nSigned-off-by: Test <test@example.com>\n\nGenerated with a tool')"
expect "commit-messages: Generated with line fails" 1 bash -c "cd '$repo' && '$cm' '$base'"

repo="$(new_repo cm-nosign)"
commit_file "$repo" a "base"
base="$(git -C "$repo" rev-parse HEAD)"
commit_file "$repo" b "feat: add b"
expect "commit-messages: missing sign-off fails by default" 1 bash -c "cd '$repo' && '$cm' '$base'"
expect "commit-messages: missing sign-off passes when not required" 0 bash -c "cd '$repo' && REQUIRE_SIGNOFF=0 '$cm' '$base'"

expect_output "commit-messages: empty base skips with a message" "skip" bash -c "cd '$repo' && '$cm' ''"
expect "commit-messages: all-zero base skips" 0 bash -c "cd '$repo' && '$cm' 0000000000000000000000000000000000000000"
expect "commit-messages: a base that is not a commit fails" 1 bash -c "cd '$repo' && '$cm' deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

# ── pipeline-lint.sh ──────────────────────────────────────────────────────────
pl="$CHECKS_DIR/pipeline-lint.sh"

repo="$(new_repo pl-thin)"
mkdir -p "$repo/.github/workflows"
cat >"$repo/.github/workflows/ci.yml" <<'YAML'
jobs:
  commit:
    steps:
      - run: make test-commit BASE_REF=${{ github.event.pull_request.base.sha }}
YAML
cat >"$repo/.gitlab-ci.yml" <<'YAML'
commit:
  script:
    - make test-commit
YAML
expect "pipeline-lint: wrappers that only call make pass" 0 "$pl" "$repo"

repo="$(new_repo pl-check)"
mkdir -p "$repo/.github/workflows"
cat >"$repo/.github/workflows/ci.yml" <<'YAML'
jobs:
  commit:
    steps:
      - run: tofu fmt -check -recursive
YAML
expect_output "pipeline-lint: a check in a GitHub workflow fails and names the file" "ci.yml" "$pl" "$repo"
expect "pipeline-lint: a check in a GitHub workflow fails" 1 "$pl" "$repo"

repo="$(new_repo pl-gitlab)"
cat >"$repo/.gitlab-ci.yml" <<'YAML'
lint:
  script:
    - shellcheck scripts/*.sh
YAML
expect "pipeline-lint: a check in a GitLab file fails" 1 "$pl" "$repo"

repo="$(new_repo pl-comment)"
cat >"$repo/.gitlab-ci.yml" <<'YAML'
commit:
  script:
    # shellcheck now lives in the Makefile
    - make test-commit
YAML
expect "pipeline-lint: a comment naming a tool passes" 0 "$pl" "$repo"

repo="$(new_repo pl-ignore)"
mkdir -p "$repo/.github/workflows"
cat >"$repo/.github/workflows/build.yml" <<'YAML'
jobs:
  scan:
    steps:
      - run: trivy image example
YAML
echo ".github/workflows/build.yml" >"$repo/.pipelinelintignore"
expect "pipeline-lint: a file listed in .pipelinelintignore is skipped" 0 "$pl" "$repo"

# ── smoke.sh ──────────────────────────────────────────────────────────────────
sm="$CHECKS_DIR/smoke.sh"

printf '%s\n' 'shell|bash --version' 'git|git --version' >"$work/tools-good.txt"
expect "smoke: every tool runs" 0 env TOOLS_FILE="$work/tools-good.txt" "$sm"

printf '%s\n' 'shell|bash --version' 'ghost|no-such-tool-xyz --version' >"$work/tools-bad.txt"
expect "smoke: a missing tool fails" 1 env TOOLS_FILE="$work/tools-bad.txt" "$sm"
expect_output "smoke: the failure names the tool" "ghost" env TOOLS_FILE="$work/tools-bad.txt" "$sm"

expect "smoke: shipped tool list is non-empty" 0 test -s "$CHECKS_DIR/tools.txt"

# ── secrets.sh ────────────────────────────────────────────────────────────────
se="$CHECKS_DIR/secrets.sh"
if command -v gitleaks >/dev/null; then
  repo="$(new_repo se-clean)"
  echo "hello" >"$repo/README.md"
  git -C "$repo" add . && git -C "$repo" commit -q -m "init"
  expect "secrets: clean repo passes" 0 "$se" "$repo"

  repo="$(new_repo se-arn)"
  echo 'role = "arn:aws:iam::123456789012:role/deploy"' >"$repo/main.tf"
  git -C "$repo" add . && git -C "$repo" commit -q -m "init"
  expect "secrets: AWS account ID in an ARN fails" 1 "$se" "$repo"

  repo="$(new_repo se-json)"
  echo '{"Account": "123456789012"}' >"$repo/policy.json"
  git -C "$repo" add . && git -C "$repo" commit -q -m "init"
  expect "secrets: account ID in a JSON field fails" 1 "$se" "$repo"

  repo="$(new_repo se-url)"
  echo 'endpoint = "https://git.corp.internal/api"' >"$repo/main.tf"
  git -C "$repo" add . && git -C "$repo" commit -q -m "init"
  expect "secrets: internal URL shape fails" 1 "$se" "$repo"

  repo="$(new_repo se-allow)"
  echo 'role = "arn:aws:iam::123456789012:role/deploy"' >"$repo/docs.md"
  cat >"$repo/.gitleaks.toml" <<TOML
[extend]
path = "$CHECKS_DIR/gitleaks.toml"

[[allowlists]]
paths = ['''docs\.md''']
TOML
  git -C "$repo" add . && git -C "$repo" commit -q -m "init"
  expect "secrets: a spoke allowlist that extends the shared config passes" 0 "$se" "$repo"
else
  skip "secrets: rules" gitleaks
fi

# ── helm-kubeconform.sh ───────────────────────────────────────────────────────
hk="$CHECKS_DIR/helm-kubeconform.sh"
if command -v helm >/dev/null && command -v kubeconform >/dev/null; then
  make_chart() { # <dir> <replicas>
    mkdir -p "$1/templates"
    printf 'apiVersion: v2\nname: demo\nversion: 0.1.0\n' >"$1/Chart.yaml"
    cat >"$1/templates/deploy.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo
spec:
  replicas: $2
  selector:
    matchLabels: {app: demo}
  template:
    metadata:
      labels: {app: demo}
    spec:
      containers:
        - name: demo
          image: example.invalid/demo:1
YAML
  }

  repo="$(new_repo hk-good)"
  make_chart "$repo/charts/demo" 1
  expect "helm-kubeconform: a valid chart passes" 0 "$hk" "$repo"

  repo="$(new_repo hk-bad)"
  make_chart "$repo/charts/demo" '"many"'
  expect "helm-kubeconform: a chart rendering an invalid object fails" 1 "$hk" "$repo"

  repo="$(new_repo hk-none)"
  expect "helm-kubeconform: a repo with no chart passes" 0 "$hk" "$repo"
else
  skip "helm-kubeconform: rendering" "helm and kubeconform"
fi

# ── check-trivyignore.sh ──────────────────────────────────────────────────────
ti="$CHECKS_DIR/check-trivyignore.sh"

printf '%s\n' '# comment' '' 'CVE-2026-0001 exp:2099-01-01 reason:waiting on upstream' >"$work/ignore-good"
expect "check-trivyignore: a dated entry passes" 0 "$ti" "$work/ignore-good"

printf '%s\n' '# only a comment' >"$work/ignore-empty"
expect "check-trivyignore: a file with no entries passes" 0 "$ti" "$work/ignore-empty"

printf '%s\n' 'CVE-2026-0002 reason:no date' >"$work/ignore-nodate"
expect_output "check-trivyignore: an entry without a date fails and names it" "CVE-2026-0002" "$ti" "$work/ignore-nodate"
expect "check-trivyignore: an entry without a date fails" 1 "$ti" "$work/ignore-nodate"

printf '%s\n' 'CVE-2026-0003 exp:2020-01-01 reason:old' >"$work/ignore-expired"
expect "check-trivyignore: an expired entry fails" 1 "$ti" "$work/ignore-expired"
expect "check-trivyignore: the same entry passes before its date" 0 env TODAY=2019-12-31 "$ti" "$work/ignore-expired"

# ── scan-image.sh ─────────────────────────────────────────────────────────────
si="$(cd "$CHECKS_DIR/../.github/scripts" && pwd)/scan-image.sh"
if command -v jq >/dev/null; then
  stubs="$work/stubs"
  mkdir -p "$stubs"
  cat >"$stubs/trivy" <<'STUB'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  [ "$1" = "--output" ] && out="$2"
  shift
done
cp "$FAKE_REPORT" "$out"
STUB
  cat >"$stubs/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
for arg in "$@"; do
  [ -n "${prev:-}" ] && [ "$prev" = "--body-file" ] && cat "$arg" >>"$GH_LOG"
  prev="$arg"
done
if [ "$1 $2" = "issue list" ]; then
  echo "$FAKE_OPEN_ISSUE"
fi
STUB
  chmod +x "$stubs/trivy" "$stubs/gh"

  echo '{"Results":[]}' >"$work/report-clean.json"
  cat >"$work/report-found.json" <<'JSON'
{"Results":[{"Vulnerabilities":[
 {"VulnerabilityID":"CVE-2026-1111","PkgName":"libfoo","InstalledVersion":"1.0","FixedVersion":"1.1","Severity":"HIGH"},
 {"VulnerabilityID":"CVE-2026-1111","PkgName":"libfoo","InstalledVersion":"1.0","FixedVersion":"1.1","Severity":"HIGH"}]}]}
JSON

  scan() { # <report> <open-issue> -> prints the gh log
    : >"$work/gh.log"
    PATH="$stubs:$PATH" GH_LOG="$work/gh.log" FAKE_REPORT="$1" FAKE_OPEN_ISSUE="$2" \
      TRIVY_IGNORE_FILE="$work/ignore-empty" "$si" example.invalid/img:latest >/dev/null 2>&1
    cat "$work/gh.log"
  }

  expect_output "scan-image: findings with no open issue create one" "gh issue create" scan "$work/report-found.json" ""
  expect_output "scan-image: findings with an open issue update it" "gh issue edit 7" scan "$work/report-found.json" 7
  expect_output "scan-image: a repeated finding is listed once" "found 1 fixable" scan "$work/report-found.json" ""
  expect_output "scan-image: a clean scan closes the open issue" "gh issue close 7" scan "$work/report-clean.json" 7
  out="$(scan "$work/report-clean.json" "")"
  if grep -qE "issue (create|edit|close)" <<<"$out"; then
    bad "scan-image: a clean scan with no open issue does nothing"
  else
    ok "scan-image: a clean scan with no open issue does nothing"
  fi
else
  skip "scan-image: issue handling" jq
fi

echo
echo "passed $pass, failed $fail, skipped $skipped"
[ "$fail" -eq 0 ]
