#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT/build/ci-logs"
mkdir -p "$LOG_DIR" "$ROOT/dist"

declare -A pids
declare -A statuses

start_build() {
	local target="$1"
	shift

	echo "starting ${target}"
	(
		cd "$ROOT"
		"$@"
	) >"$LOG_DIR/${target}.log" 2>&1 &
	pids["$target"]=$!
}

start_build linux "$ROOT/scripts/ci-build-linux.sh"
start_build windows "$ROOT/scripts/ci-build-windows.sh"
start_build macos "$ROOT/scripts/ci-build-macos.sh"

while ((${#pids[@]})); do
	for target in "${!pids[@]}"; do
		pid="${pids[$target]}"
		if kill -0 "$pid" 2>/dev/null; then
			continue
		fi

		if wait "$pid"; then
			statuses["$target"]=0
			echo "${target}: OK"
		else
			statuses["$target"]=1
			echo "::error title=${target} build failed::see build/ci-logs/${target}.log"
		fi

		echo "::group::${target} log"
		cat "$LOG_DIR/${target}.log"
		echo "::endgroup::"
		unset "pids[$target]"
	done

	if ((${#pids[@]})); then
		echo "still running: ${!pids[*]}"
		for target in "${!pids[@]}"; do
			echo "::group::${target} recent log"
			tail -n 20 "$LOG_DIR/${target}.log" 2>/dev/null || true
			echo "::endgroup::"
		done
		sleep 30
	fi
done

for target in "${!statuses[@]}"; do
	if ((${statuses[$target]} != 0)); then
		exit 1
	fi
done

find "$ROOT/dist" -maxdepth 2 -type f -print | sort
