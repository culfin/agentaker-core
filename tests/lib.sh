# Minimal assertions. No framework — this must run wherever bash does.
PASS=0
FAIL=0

check() {
  local label=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$label"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$label" "$expected" "$actual"
  fi
}

contains() {
  local label=$1 needle=$2 haystack=$3
  case "$haystack" in
    *"$needle"*) PASS=$((PASS + 1)); printf '  ok   %s\n' "$label" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL %s\n       expected to contain: %s\n       actual: %s\n' "$label" "$needle" "$haystack" ;;
  esac
}

lacks() {
  local label=$1 needle=$2 haystack=$3
  case "$haystack" in
    *"$needle"*) FAIL=$((FAIL + 1)); printf '  FAIL %s\n       should not contain: %s\n' "$label" "$needle" ;;
    *) PASS=$((PASS + 1)); printf '  ok   %s\n' "$label" ;;
  esac
}

summary() {
  printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

# A throwaway projects directory holding one throwaway git repo.
make_sandbox() {
  SANDBOX=$(mktemp -d)
  export WTR_PROJECTS_DIR="$SANDBOX"
  export WTR_DRY_RUN=1
  git init -q -b main "$SANDBOX/demo"
  git -C "$SANDBOX/demo" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
}
