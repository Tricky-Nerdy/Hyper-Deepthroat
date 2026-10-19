#!/usr/bin/env bash
# Regression tests: plays fixed scenarios headless (game/debug/regress.gd) and compares the state dumps with the
# reference dumps in tests/golden/. Runs without mods, in Vanilla mode (no extensions) and with a throwaway save,
# so your own save is never touched.
#
#   tools/regress.sh                 run all scenarios, report differences
#   tools/regress.sh grab cum        run only these scenarios
#   tools/regress.sh --update        accept the current output as the new reference (after checking the diff!)
#   tools/regress.sh --stress        also run the costume stress test and report memory per round
#   tools/regress.sh --mods=<dir>    also load every .swf mod in <dir> (and subfolders) and report failures
#
# Needs GODOT (path to the Godot console executable) or godot on PATH.
set -u
cd "$(dirname "$0")/.."
GODOT=${GODOT:-godot}
ROOT=$(pwd)
GOLDEN=$ROOT/tests/golden
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sdt-regress.XXXXXX")
ALL="menu idle grab costumes characters cum"
update=0
stress=0
mods=""
scenarios=""
for a in "$@"; do
	case $a in
		--update) update=1 ;;
		--stress) stress=1 ;;
		--mods=*) mods=${a#--mods=} ;;
		-*) echo "unknown option $a"; exit 2 ;;
		*) scenarios="$scenarios $a" ;;
	esac
done
scenarios=${scenarios:-$ALL}
mkdir -p "$WORK/mods" "$WORK/out"

run_game() {   # name, extra args...
	local name=$1; shift
	"$GODOT" --headless --fixed-fps 30 --path game -- --deterministic --seed=1 --vanilla \
		--save-dir="$WORK/save_$name" --mods-dir="$WORK/mods" "$@" > "$WORK/$name.log" 2>&1
}

echo "running:$scenarios (work folder $WORK)"
pids=""
for s in $scenarios; do
	run_game "$s" --driver=res://debug/regress.gd --scenario="$s" --out="$WORK/out" &
	pids="$pids $!"
done
# Extension system checks (game/debug/ext_checks.gd); not in Vanilla mode, they switch extensions on and off.
# They load the test plugins from tests/plugins; "crashy" is marked as having crashed the previous start.
mkdir -p "$WORK/mods_ext/Plugins" "$WORK/save_ext/extensions" "$WORK/mods_da"
cp -r tests/plugins/*/ "$WORK/mods_ext/Plugins/"
printf crashy > "$WORK/save_ext/extensions/loading_plugin.txt"
"$GODOT" --headless --fixed-fps 30 --path game -- --save-dir="$WORK/save_ext" --mods-dir="$WORK/mods_ext" \
	--driver=res://debug/ext_checks.gd > "$WORK/ext_checks.log" 2>&1 &
ext_pid=$!
# Built-in DialogueActions checks (game/debug/da_checks.gd)
"$GODOT" --headless --fixed-fps 30 --path game -- --save-dir="$WORK/save_da" --mods-dir="$WORK/mods_da" \
	--driver=res://debug/da_checks.gd > "$WORK/da_checks.log" 2>&1 &
da_pid=$!
# New in-game menu checks (game/debug/menu_checks.gd)
mkdir -p "$WORK/mods_menu"
"$GODOT" --headless --fixed-fps 30 --path game -- --save-dir="$WORK/save_menu" --mods-dir="$WORK/mods_menu" 	--driver=res://debug/menu_checks.gd > "$WORK/menu_checks.log" 2>&1 &
menu_pid=$!
scenario_status=0
for p in $pids; do wait "$p" || scenario_status=1; done
wait "$ext_pid"; ext_status=$?
wait "$da_pid"; da_status=$?
wait "$menu_pid"; menu_status=$?

fail=$scenario_status
[ "$scenario_status" = 0 ] || echo "FAIL: a scenario process exited unsuccessfully"
for s in $scenarios; do
	# Errors during the run count as failures (Godot's leak reports at exit do not).
	if grep "ERROR" "$WORK/$s.log" | grep -v "at exit" > /dev/null; then
		echo "FAIL $s: errors during the run (see $WORK/$s.log):"
		grep -A3 "ERROR" "$WORK/$s.log" | grep -v "at exit" | head -12
		fail=1
	fi
	got=$(ls "$WORK/out" | grep "^${s}_" || true)
	if [ -z "$got" ]; then
		echo "FAIL $s: no dumps written (see $WORK/$s.log)"
		fail=1
		continue
	fi
	# A partial output set is a failure even if every file that did appear matches.
	if [ "$update" = 0 ]; then
		for expected in "$GOLDEN/${s}_"*; do
			[ -f "$expected" ] || continue
			if [ ! -f "$WORK/out/$(basename "$expected")" ]; then
				echo "FAIL $s: expected dump missing: $(basename "$expected")"
				fail=1
			fi
		done
	fi
	for f in $got; do
		if [ $update = 1 ]; then
			mkdir -p "$GOLDEN"
			cp "$WORK/out/$f" "$GOLDEN/$f"
		elif [ ! -f "$GOLDEN/$f" ]; then
			echo "NEW  $f (no reference yet: run with --update to add it)"
			fail=1
		elif ! diff -q "$GOLDEN/$f" "$WORK/out/$f" > /dev/null; then
			n=$(diff "$GOLDEN/$f" "$WORK/out/$f" | grep -c '^[<>]')
			echo "DIFF $f ($n lines differ):"
			diff "$GOLDEN/$f" "$WORK/out/$f" | head -20
			fail=1
		else
			echo "ok   $f"
		fi
	done
done
# Script errors fail the checks too, except the deliberate ones (the broken test plugins, a duplicate id).
script_errors() {   # each error line with the "at:" line after it
	awk '/SCRIPT ERROR|^ERROR/ { e = $0; getline n; print e " | " n }' "$1" \
		| grep -v -E "at exit|gdscript://|mods_ext/Plugins|missing or duplicate id|already used|contains ';'|has errors|uses class_name" | head -5
}
if [ -n "$(script_errors "$WORK/ext_checks.log")" ] || [ -n "$(script_errors "$WORK/da_checks.log")" ] 		|| [ -n "$(script_errors "$WORK/menu_checks.log")" ]; then
	echo "FAIL script errors in the checks:"
	script_errors "$WORK/ext_checks.log"
	script_errors "$WORK/da_checks.log"
	script_errors "$WORK/menu_checks.log"
	fail=1
fi
if [ "$ext_status" = 0 ] && grep -q "^EXT CHECKS: .* 0 failed" "$WORK/ext_checks.log"; then
	echo "ok   extension checks ($(grep -c '^CHECK ok' "$WORK/ext_checks.log") passed)"
else
	echo "FAIL extension checks, exit code $ext_status (see $WORK/ext_checks.log):"
	grep -E "^CHECK FAIL|SCRIPT ERROR" "$WORK/ext_checks.log" | head -12
	fail=1
fi
if [ "$da_status" = 0 ] && grep -q "^DA CHECKS: .* 0 failed" "$WORK/da_checks.log"; then
	echo "ok   DialogueActions checks ($(grep -c '^CHECK ok' "$WORK/da_checks.log") passed)"
else
	echo "FAIL DialogueActions checks, exit code $da_status (see $WORK/da_checks.log):"
	grep -E "^CHECK FAIL|SCRIPT ERROR" -A1 "$WORK/da_checks.log" | head -16
	fail=1
fi
if [ "$menu_status" = 0 ] && grep -q "^MENU CHECKS: .* 0 failed" "$WORK/menu_checks.log"; then
	echo "ok   menu checks ($(grep -c '^CHECK ok' "$WORK/menu_checks.log") passed)"
else
	echo "FAIL menu checks, exit code $menu_status (see $WORK/menu_checks.log):"
	grep -E "^CHECK FAIL|SCRIPT ERROR" -A1 "$WORK/menu_checks.log" | head -16
	fail=1
fi
[ $update = 1 ] && echo "references updated in tests/golden/ (review with git diff before committing)"

if [ $stress = 1 ]; then
	echo "stress test (4 rounds of every picker and character)..."
	run_game stress --driver=res://debug/stress_costumes.gd || fail=1
	if [ -n "$(script_errors "$WORK/stress.log")" ]; then
		fail=1
	fi
	grep "^STRESS" "$WORK/stress.log"
fi

if [ -n "$mods" ]; then
	# Godot needs native paths (Git Bash on Windows passes /c/... style ones).
	command -v cygpath > /dev/null && mods=$(cygpath -m "$mods")
	find "$mods" -iname '*.swf' > "$WORK/modlist.txt"
	echo "loading $(wc -l < "$WORK/modlist.txt") mods from $mods..."
	"$GODOT" --headless --path game res://debug/mod_load_test.tscn -- --list="$WORK/modlist.txt" > "$WORK/mods.log" 2>&1
	grep -E "^FAIL|^done" "$WORK/mods.log"
	grep -q "^done: .* 0 failed" "$WORK/mods.log" || fail=1
fi

if [ $fail = 0 ]; then
	echo "PASS"
	rm -rf "$WORK"
else
	echo "FAILED (logs and output kept in $WORK)"
fi
exit $fail
