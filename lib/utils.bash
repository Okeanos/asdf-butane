#!/usr/bin/env bash

set -euo pipefail

GH_REPO="https://github.com/coreos/butane"
TOOL_NAME="butane"
TOOL_TEST="butane --version"
SKIP_VERIFY=${ASDF_BUTANE_SKIP_VERIFY:-"false"}

fail() {
	echo -e "asdf-$TOOL_NAME: $*"
	exit 1
}

curl_opts=(-fsSL)

# NOTE: You might want to remove this if butane is not hosted on GitHub releases.
if [ -n "${GITHUB_API_TOKEN:-}" ]; then
	curl_opts=("${curl_opts[@]}" -H "Authorization: token $GITHUB_API_TOKEN")
fi

sort_versions() {
	sed 'h; s/[+-]/./g; s/.p\([[:digit:]]\)/.z\1/; s/$/.z/; G; s/\n/ /' |
		LC_ALL=C sort -t. -k 1,1 -k 2,2n -k 3,3n -k 4,4n -k 5,5n | awk '{print $2}'
}

list_github_tags() {
	git ls-remote --tags --refs "$GH_REPO" |
		grep -o 'refs/tags/.*' | cut -d/ -f3- |
		sed 's/^v//' # NOTE: You might want to adapt this sed to remove non-version strings from tags
}

list_all_versions() {
	# Change this function if butane has other means of determining installable versions.
	list_github_tags
}

get_platform() {
	local -r kernel="$(uname -s)"
	if [[ ${OSTYPE} == "msys" || ${kernel} == "CYGWIN"* || ${kernel} == "MINGW"* ]]; then
		echo "pc-windows"
	else
		local -r unix="$(uname | tr '[:upper:]' '[:lower:]')"
		if [[ ${unix} == "darwin" ]]; then
			echo "apple-darwin"
		else
			echo "unknown-linux-gnu"
		fi
	fi
}

get_arch() {
	local -r machine="$(uname -m)"

	if [[ ${machine} == "arm64" ]] || [[ ${machine} == "aarch64" ]]; then
		echo "aarch64"
	elif [[ ${machine} == *"arm"* ]] || [[ ${machine} == *"aarch"* ]]; then
		echo "aarch"
	elif [[ ${machine} == *"386"* ]]; then
		echo "x86"
	else
		echo "x86_64"
	fi
}

get_release_file() {
	echo "${ASDF_DOWNLOAD_PATH}/${TOOL_NAME}"
}

download_release() {
	local version filename url
	version="$1"
	local -r filename="$(get_release_file)"
	local -r platform="$(get_platform)"
	local -r arch="$(get_arch)"

	url="$GH_REPO/releases/download/v${version}/${TOOL_NAME}-${arch}-${platform}"
	if [[ ${version} == "latest" ]]; then
		url="$GH_REPO/releases/${version}/download/${TOOL_NAME}-${arch}-${platform}"
	fi
	if [[ ${platform} == "pc-windows" ]]; then
		url+=".exe"
	fi

	echo "* Downloading $TOOL_NAME release $version..."
	curl "${curl_opts[@]}" -o "$filename" -C - "$url" || fail "Could not download $url"
	chmod +x "$filename"
}

install_version() {
	local install_type="$1"
	local version="$2"
	local install_path="${3%/bin}/bin"

	if [ "$install_type" != "version" ]; then
		fail "asdf-$TOOL_NAME supports release installs only"
	fi

	if command -v gpg >/dev/null 2>&1 && [ "$SKIP_VERIFY" == "false" ]; then
		echo "Verifying signatures and checksums"
		verify "$version" "$ASDF_DOWNLOAD_PATH"
	else
		echo "Skipping verifying signatures and checksums either because gpg is not installed or explicitly skipped with ASDF_BUTANE_SKIP_VERIFY"
	fi

	(
		mkdir -p "$install_path"
		cp -r "$ASDF_DOWNLOAD_PATH"/* "$install_path"

		local tool_cmd
		tool_cmd="$(echo "$TOOL_TEST" | cut -d' ' -f1)"
		test -x "$install_path/$tool_cmd" || fail "Expected $install_path/$tool_cmd to be executable."

		echo "$TOOL_NAME $version installation was successful!"
	) || (
		rm -rf "$install_path"
		fail "An error occurred while installing $TOOL_NAME $version."
	)
}

verify() {
	local -r version="$1"
	local -r download_path="$2"
	local -r signing_key_url="https://fedoraproject.org/fedora.gpg"
	local -r platform="$(get_platform)"
	local -r arch="$(get_arch)"
	local signature_file="${TOOL_NAME}-${arch}-${platform}"
	if [[ ${platform} == "pc-windows" ]]; then
		signature_file+=".exe"
	fi
	signature_file+=".asc"

	baseURL="$GH_REPO/releases/download/v${version}"
	echo "* Downloading signing key ..."
	curl "${curl_opts[@]}" -o "${download_path}/fedora.gpg" "${signing_key_url}" || fail "Could not download ${signing_key_url}"
	echo "* Downloading signature file ..."
	curl "${curl_opts[@]}" -o "${download_path}/${signature_file}" "${baseURL}/${signature_file}" || fail "Could not download ${baseURL}/${signature_file}"

	gpg_temp=$(mktemp -d)

	if ! (
		gpg --homedir="${gpg_temp}" --import "${download_path}/fedora.gpg"
		gpg --homedir="${gpg_temp}" --verify "${download_path}/${signature_file}" "$ASDF_DOWNLOAD_PATH/${TOOL_NAME}"
	); then
		echo "signature verification failed" >&2
		return 1
	fi
}
