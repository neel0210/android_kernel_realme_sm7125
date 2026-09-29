#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Validate host tools and print flags compatible with this kernel's BTF kinds.
set -eu
: "${PAHOLE:=pahole}"
: "${RESOLVE_BTFIDS:=resolve_btfids}"
for tool in "$PAHOLE" "$RESOLVE_BTFIDS"; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "BTF: missing host tool $tool; see tools/testing/selftests/bpf/README.btf" >&2
		exit 1
	fi
done
version=$("$PAHOLE" --version | sed -n 's/^v\([0-9]*\)\.\([0-9]*\).*$/\1 \2/p')
set -- $version
if [ "$#" != 2 ] || [ "$1" -lt 1 ] || { [ "$1" -eq 1 ] && [ "$2" -lt 21 ]; }; then
	echo "BTF: pahole v1.21 or newer is required" >&2
	exit 1
fi
help=$("$PAHOLE" --help)
for flag in --skip_encoding_btf_enum64 --skip_encoding_btf_decl_tag --skip_encoding_btf_type_tag; do
	case "$help" in *"$flag"*) printf '%s ' "$flag";; esac
done
printf '\n'
