#!/bin/sh
# accuracy.sh - ground-truth regression for the judging funnel.
#
# These are hand-verified answer sets, not model output: the point is to catch a
# change that quietly trades recall for a nicer-looking precision number. They
# need the same corpus they were derived from, so set XNU=/path/to/xnu (default
# ~/audit/xnu); the suite skips with exit 0 when the tree is not there.
set -u
BIN=${BIN:-.build/release/fmgrep}
XNU=${XNU:-$HOME/audit/xnu}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fmgrep-accuracy.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

if [ ! -r "$XNU/osfmk/vm/vm_kern.c" ]; then
	echo "accuracy: $XNU/osfmk/vm/vm_kern.c not found - set XNU= to your xnu checkout, skipping"
	exit 0
fi

# ENG holds extra flags for the run being scored, so engines can be compared
# with the same scorer and the same ground truth:
#   ENG="--blocks --block-lines 48" ./Tests/accuracy.sh
# Word-split on purpose; keep it free of shell metacharacters.
ENG=${ENG:-}
LABEL=${LABEL:-"engine: default funnel (32-line sieve + per-line confirm)"}

score() { # name  truth_file  got_file
	awk -v t="$2" -v g="$3" -v n="$1" '
		function load(f, into,   line) { while ((getline line < f) > 0) into[line]=1; close(f) }
		BEGIN { load(t, T); load(g, G); for (l in G) got++; for (l in T) truth++
			for (l in G) if (l in T) tp++
			fp = got - tp; fn = truth - tp
			printf "%-22s hits=%-4d recall=%d/%d  false-positives=%d", n, got, tp, truth, fp
			if (got) printf "  precision=%d%%", int(tp*100/got + 0.5)
			print ""
			miss = ""
			for (l in T) if (!(l in G)) miss = miss " " l
			if (miss != "") print "                       missed (a score-1 wobble, not a plumbing bug):" miss
		}'
}

# A run that died prints nothing and scores a perfect-looking 0 hits; refuse to
# report those. Case 1 must always produce at least one line.
require_hits() { # got_file  label
	if [ ! -s "$1" ]; then
		printf '%-22s RUN PRODUCED NO OUTPUT (%s) - see stderr, not a measurement\n' "$2" "$3"
		return 1
	fi
	return 0
}

# --- case 1: one file, verb-to-identifier gap, every site hand-grepped ---
printf '935\n1162\n1163\n1516\n1795\n2289\n4523\n4562\n4590\n4618\n5054\n' > "$TMP/truth1"
$BIN --no-color $ENG -E 'deallocate' \
	"where are kernel memory objects handed back to the system" \
	"$XNU/osfmk/vm/vm_kern.c" 2>"$TMP/err1" \
	| sed -n 's/.*vm_kern\.c:\([0-9]*\):.*/\1/p' | sort -n > "$TMP/got1"
require_hits "$TMP/got1" "vm_kern dealloc" "case 1" \
	&& score "vm_kern dealloc" "$TMP/truth1" "$TMP/got1"

# --- case 2: topically saturated code (_sleep's own file), strict truth set.
# Lines where the wait is abandoned or its outcome is decided. Neighbours such
# as `if (catch)` are deliberately outside the set: they gate the answer.
head -128 "$XNU/bsd/kern/kern_synch.c" > "$TMP/synch128.c"
printf '79\n80\n92\n94\n95\n99\n101\n104\n105\n109\n112\n' > "$TMP/truth2"
$BIN --no-color $ENG "places where the code gives up waiting because the resource it needs is no longer available" \
	"$TMP/synch128.c" 2>"$TMP/err2" \
	| sed -n 's/.*synch128\.c:\([0-9]*\):.*/\1/p' | sort -n > "$TMP/got2"
require_hits "$TMP/got2" "kern_synch abort paths" "case 2" \
	&& score "kern_synch abort paths" "$TMP/truth2" "$TMP/got2"
echo "-> $LABEL  [flags: ${ENG:-none}]"

# --- case 3: the computed path. No model call should be spent here at all: ---
# --- the answer is arithmetic, and the tool must say so rather than guess.  ---
if [ -r /etc/rpc ]; then
	printf '41\n' > "$TMP/truth3"
	$BIN --no-color $ENG 'what runs on port 100068' /etc/rpc 2>"$TMP/err3" \
		| sed -n 's/.*\/rpc:\([0-9]*\):.*/\1/p' | sort -n > "$TMP/got3"
	require_hits "$TMP/got3" "rpc port lookup" "case 3" \
		&& score "rpc port lookup" "$TMP/truth3" "$TMP/got3"
	if grep -q "no line goes to the model" "$TMP/err3"; then
		echo "                       computed without a judging call: yes"
	else
		echo "                       computed without a judging call: NO - it judged lines instead"
	fi
fi

# --- the levers, restated, because their cost is the interesting part ---
echo "funnel chatter (case 2):"
sed -n 's/^fmgrep: /  /p' "$TMP/err2" | grep -E "cache|guard|note:" || true
