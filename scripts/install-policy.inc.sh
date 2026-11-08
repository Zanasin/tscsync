# SPDX-License-Identifier: MIT
# Shared by scripts/install.sh and scripts/test-install-policy.sh.
# Expects: EFIVARS, GV, LOADER, GRUB_DIR, ESP (may be empty), die()
# Optional overrides for tests: TSCSYNC_MOKUTIL, TSCSYNC_ROOT (prefix for key paths)

# Prefix known absolute key paths when testing under a fake root.
_tscsync_keypath() {
	local p=$1
	if [ -n "${TSCSYNC_ROOT:-}" ]; then
		printf '%s' "${TSCSYNC_ROOT}${p}"
	else
		printf '%s' "$p"
	fi
}

_tscsync_mokutil() {
	if [ -n "${TSCSYNC_MOKUTIL:-}" ]; then
		"$TSCSYNC_MOKUTIL" "$@"
	else
		mokutil "$@"
	fi
}

# Evidence first (BootCurrent names rEFInd, LoaderInfo names systemd-boot),
# then grub.cfg, then a rEFInd install on the ESP. Sets LOADER; may set ESP.
# With TSCSYNC_ROOT set (tests), filesystem probes are rooted there.
tscsync_detect_loader() {
	local loader_info cur var d root=${TSCSYNC_ROOT:-}
	loader_info=$EFIVARS/LoaderInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f

	booted_via_refind() {
		[ -r "$EFIVARS/BootCurrent-$GV" ] || return 1
		cur=$(od -An -tx1 -j4 -N2 "$EFIVARS/BootCurrent-$GV" | awk '{printf "%s%s", toupper($2), toupper($1)}')
		var=$EFIVARS/Boot$cur-$GV
		[ -r "$var" ] && tr -d '\000' <"$var" | grep -qi 'refind'
	}

	has_grub_cfg() {
		[ -n "$GRUB_DIR" ] && [ -f "$GRUB_DIR/grub.cfg" ] && return 0
		[ -f "${root}/boot/grub2/grub.cfg" ] || [ -f "${root}/boot/grub/grub.cfg" ]
	}

	find_esp_candidate() {
		local d
		for d in ${ESP:+"$ESP"} "${root}/boot/efi" "${root}/efi" "${root}/boot"; do
			[ -n "$d" ] || continue
			if [ -d "$d/EFI" ]; then
				if [ -n "$root" ] || [ "$(findmnt -no FSTYPE -T "$d" 2>/dev/null)" = vfat ]; then
					ESP=$d
					return 0
				fi
			fi
		done
		return 1
	}

	if [ -n "$LOADER" ]; then
		return 0
	fi
	if booted_via_refind; then
		LOADER=refind
	elif [ -r "$loader_info" ] && tr -d '\000' <"$loader_info" | grep -q 'systemd-boot'; then
		LOADER=systemd-boot
	elif has_grub_cfg; then
		LOADER=grub
	else
		# No evidence and no grub.cfg. systemd-boot is not guessed: it sets
		# LoaderInfo on every boot, so without it systemd-boot did not start
		# this boot and its drivers would never load. rEFInd sets nothing, and
		# its boot entry may not say "refind" (e.g. installed as EFI/BOOT), so
		# a refind.conf on the ESP is the best remaining sign.
		find_esp_candidate || true
		if [ -n "${ESP:-}" ]; then
			if [ -f "$ESP/EFI/refind/refind.conf" ]; then
				LOADER=refind
			else
				for d in "$ESP"/EFI/*/; do
					[ -f "${d}refind.conf" ] && { LOADER=refind; break; }
				done
			fi
		fi
		[ -n "$LOADER" ] &&
			echo "note: guessed rEFInd from refind.conf on $ESP (no boot loader variable says so); pass --loader to be sure"
	fi
	[ -n "$LOADER" ] ||
		die "cannot tell which boot loader is in use; pass --loader grub, systemd-boot or refind"
}

tscsync_cert_fingerprint() {
	local pem=$1
	openssl x509 -in "$pem" -noout -fingerprint -sha1 2>/dev/null | cut -d= -f2
}

# Echo a short trust tag and return 0 if trusted.
# Args: fp pem_path cert_path
tscsync_cert_is_trusted() {
	local fp=$1 pem=$2 cert=$3
	local enrolled dbout

	enrolled=$(_tscsync_mokutil --list-enrolled 2>/dev/null || true)
	if [ -n "$enrolled" ] && grep -qiF "SHA1 Fingerprint: $fp" <<<"$enrolled"; then
		echo "enrolled-MOK"
		return 0
	fi
	dbout=$(_tscsync_mokutil --db 2>/dev/null || true)
	if [ -n "$dbout" ] && grep -qiF "SHA1 Fingerprint: $fp" <<<"$dbout"; then
		echo "firmware-db"
		return 0
	fi
	# Only a fingerprint match proves the firmware trusts the key. Having
	# sbctl or its key files installed does not: the keys may never have
	# been enrolled, or a firmware update may have reset db/MokList.
	return 1
}

# Sets KEY/CERT from auto-discovery. Returns 0 if a key was chosen.
# Caller handles SB-off + missing sbsign soft-fail.
tscsync_pick_signing_key() {
	local candidates pair k c pem fp how skipped
	skipped=

	local moks dbkeys
	moks="$(_tscsync_keypath /etc/pki/akmods/private/private_key.priv):$(_tscsync_keypath /etc/pki/akmods/certs/public_key.der)
		$(_tscsync_keypath /var/lib/dkms/mok.key):$(_tscsync_keypath /var/lib/dkms/mok.pub)
		$(_tscsync_keypath /var/lib/shim-signed/mok/MOK.priv):$(_tscsync_keypath /var/lib/shim-signed/mok/MOK.der)"
	dbkeys="$(_tscsync_keypath /var/lib/sbctl/keys/db/db.key):$(_tscsync_keypath /var/lib/sbctl/keys/db/db.pem)
		$(_tscsync_keypath /usr/share/secureboot/keys/db/db.key):$(_tscsync_keypath /usr/share/secureboot/keys/db/db.pem)"

	# GRUB: MOK first (shim). systemd-boot and rEFInd: db/sbctl first.
	if [ "$LOADER" = grub ]; then
		candidates="$moks $dbkeys"
	else
		candidates="$dbkeys $moks"
	fi

	pem=$(mktemp)
	for pair in $candidates; do
		k=${pair%%:*}
		c=${pair##*:}
		[ -f "$k" ] && [ -f "$c" ] || continue
		if ! openssl x509 -in "$c" -outform PEM -out "$pem" 2>/dev/null &&
			! openssl x509 -inform DER -in "$c" -outform PEM -out "$pem" 2>/dev/null; then
			skipped="$skipped $c(unreadable)"
			continue
		fi
		fp=$(tscsync_cert_fingerprint "$pem")
		[ -n "$fp" ] || { skipped="$skipped $c(no-fp)"; continue; }

		if [ "$SB" = 1 ]; then
			if how=$(tscsync_cert_is_trusted "$fp" "$pem" "$c"); then
				KEY=$k
				CERT=$c
				echo "using $how signing key $fp ($c)"
				rm -f "$pem"
				return 0
			fi
			skipped="$skipped $c(not-enrolled)"
			continue
		fi
		KEY=$k
		CERT=$c
		echo "Secure Boot is off: will sign with $c if sbsign is available"
		rm -f "$pem"
		return 0
	done
	rm -f "$pem"
	if [ -n "$skipped" ]; then
		echo "note: skipped signing keys:$skipped" >&2
	fi
	return 1
}
