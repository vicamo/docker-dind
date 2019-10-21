#!/bin/bash
set -eo pipefail

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

source '.architectures-lib'

flavors=( "$@" )
if [ ${#flavors[@]} -eq 0 ]; then
	flavors=( */*/ )
fi
flavors=( "${flavors[@]%/}" )

# see http://stackoverflow.com/a/2705678/433558
sed_escape_lhs() {
	echo "$@" | sed -e 's/[]\/$*.^|[]/\\&/g'
}
sed_escape_rhs() {
	echo "$@" | sed -e 's/[\/&]/\\&/g' | sed -e ':a;N;$!ba;s/\n/\\n/g'
}

# "tac|tac" for http://stackoverflow.com/a/28879552/433558
dindLatest="$(curl -fsSL 'https://github.com/docker/docker/commits/master/hack/dind.atom' | tac|tac | awk -F '[[:space:]]*[<>/]+' '$2 == "id" && $3 ~ /Commit/ { print $4; exit }')"

dockerVersions="$(
	git ls-remote --tags https://github.com/docker/docker-ce.git \
		| cut -d$'\t' -f2 \
		| grep '^refs/tags/v[0-9].*$' \
		| sed 's!^refs/tags/v!!; s!\^{}$!!' \
		| sort -u \
		| gawk '
			{ data[lines++] = $0 }

			# "beta" sorts lower than "tp" even though "beta" is a more preferred release, so we need to explicitly adjust the sorting order for RCs
			# also, "18.09.0-ce-beta1" vs "18.09.0-beta3"
			function docker_version_compare(i1, v1, i2, v2, l, r) {
				l = v1; gsub(/-ce/, "", l); gsub(/-tp/, "-alpha", l)
				r = v2; gsub(/-ce/, "", r); gsub(/-tp/, "-alpha", r)
				patsplit(l, ltemp, /[^.-]+/)
				patsplit(r, rtemp, /[^.-]+/)
				for (i = 0; i < length(ltemp) && i < length(rtemp); ++i) {
					if (ltemp[i] < rtemp[i]) {
						return -1
					}
					if (ltemp[i] > rtemp[i]) {
						return 1
					}
				}
				return 0
			}

			END {
				asort(data, result, "docker_version_compare")
				for (i in result) {
					print result[i]
				}
			}
		'
)"

fullVersion="$(grep -v -E -- '-(rc|tp|beta)' <<<"$dockerVersions" | tail -1)"
version=${fullVersion%.*}
channel="$(versionChannel "$version")"
echo "version: $version ($channel)"

debian="$(curl -fsSL 'https://raw.githubusercontent.com/docker-library/official-images/master/library/debian')"
ubuntu="$(curl -fsSL 'https://raw.githubusercontent.com/docker-library/official-images/master/library/ubuntu')"

travisEnv=
appveyorEnv=
for flavor in "${flavors[@]}"; do
	suite=${flavor%/*}
	arch=${flavor#*/}
	if echo "$debian" | grep -qE "\b${suite}\b"; then
		distro='debian'
	elif echo "$ubuntu" | grep -qE "\b${suite}\b"; then
		distro='ubuntu'
	else
		echo >&2 "error: cannot determine repo for '$version'"
		exit 1
	fi

	archCase='dpkgArch="$(dpkg --print-architecture)"; '$'\\\n'
	archCase+=$'\t''case "$dpkgArch" in '$'\\\n'
	for dpkgArch in $(dpkgArches); do
		dockerArch="$(dpkgToDockerArch "$dpkgArch")"
		# check whether the given architecture is supported for this release
		if wget --quiet --spider "https://download.docker.com/linux/static/$channel/$dockerArch/docker-$fullVersion.tgz" &> /dev/null; then
			bashbrewArch="$(dpkgToBashbrewArch "$dpkgArch")"
			archCase+="# $bashbrewArch"$'\n'
			archCase+=$'\t\t'"$dpkgArch) dockerArch='$dockerArch' ;; "$'\\\n'
		fi
	done
	archCase+=$'\t\t''*) echo >&2 "error: unsupported architecture ($dpkgArch)"; exit 1 ;;'$'\\\n'
	archCase+=$'\t''esac'

	majorVersion="${version%%.*}"
	minorVersion="${version#$majorVersion.}"
	minorVersion="${minorVersion%%.*}"
	minorVersion="${minorVersion#0}"

	for variant in \
		'' git dind dind-rootless \
	; do
		dir="$flavor${variant:+/$variant}"
		[ -d "$dir" ] || mkdir -p "$dir"
		df="$dir/Dockerfile"
		slash='/'
		template="Dockerfile${variant:+-${variant//$slash/-}}.template"
		sed -r \
			-e 's!%%VERSION%%!'"$version"'!g' \
			-e 's!%%DISTRO%%!'"$distro"'!g' \
			-e 's!%%SUITE%%!'"$suite"'!g' \
			-e 's!%%ARCH%%!'"$arch"'!g' \
			-e 's!%%DOCKER-CHANNEL%%!'"$channel"'!g' \
			-e 's!%%DOCKER-VERSION%%!'"$fullVersion"'!g' \
			-e 's!%%DIND-COMMIT%%!'"$dindLatest"'!g' \
			-e 's!%%ARCH-CASE%%!'"$(sed_escape_rhs "$archCase")"'!g' \
			"$template" > "$df"

		# DOCKER_TLS_CERTDIR is only enabled-by-default in 19.03+
		if [ "$majorVersion" -lt 19 ]; then
			sed -ri -e 's!^(ENV DOCKER_TLS_CERTDIR=).*$!\1!' "$df"
		fi

		# pigz (https://github.com/moby/moby/pull/35697) is only 18.02+
		if [ "$majorVersion" -lt 18 ] || { [ "$majorVersion" -eq 18 ] && [ "$minorVersion" -lt 2 ]; }; then
			sed -ri '/pigz/d' "$df"
		fi
	done

	cp -a docker-entrypoint.sh modprobe.sh "$flavor/"
	cp -a dockerd-entrypoint.sh "$flavor/dind/"

	travisEnv='\n  - VERSION='"$version SUITE=$suite ARCH=$arch$travisEnv"
done

travis="$(awk -v 'RS=\n\n' '$1 == "env:" { $0 = "env:'"$travisEnv"'" } { printf "%s%s", $0, RS }' .travis.yml)"
echo "$travis" > .travis.yml
