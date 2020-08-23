#!/bin/bash
set -eu

self="$(basename "$BASH_SOURCE")"
cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

source '.architectures-lib'

parentArches() {
	local suite="$1"; shift # "17.06", etc

	local parent="$(awk 'toupper($1) == "FROM" { print $2 }' "$suite/Dockerfile")"
	echo "${parentRepoToArches[$parent]:-}"
}
suiteArches() {
	local suite="$1"; shift

	local parentArches="$(parentArches "$suite")"

	local suiteArches=()
	for arch in $parentArches; do
		if hasBashbrewArch "$arch" && grep -qE "^# $arch\$" "$suite/Dockerfile"; then
			suiteArches+=( "$arch" )
		fi
	done
	echo "${suiteArches[*]}"
}

debian="$(curl -fsSL 'https://raw.githubusercontent.com/docker-library/official-images/master/library/debian')"
ubuntu="$(curl -fsSL 'https://raw.githubusercontent.com/docker-library/official-images/master/library/ubuntu')"
suiteCodename() {
	local suite="$1"; shift

	if echo "$debian" | grep -qE "\b${suite}\b"; then
		codename=$(curl -fsSL "http://deb.debian.org/debian/dists/${suite}/Release" | awk '/^Suite: / {print $2}')
	elif echo "$ubuntu" | grep -qE "\b${suite}\b"; then
		codename=$(curl -fsSL "http://archive.ubuntu.com/ubuntu/dists/${suite}/Release" | awk '/^Suite: / {print $2}')
	else
		echo >&2 "error: cannot determine repo for '$suite'"
		exit 1
	fi

	[ "$suite" = "$codename" ] || echo "$codename"
}

flavors=( */*/ )
flavors=( "${flavors[@]%/}" )

# sort version numbers with highest first
IFS=$'\n'; flavors=( $(echo "${flavors[*]}" | sort -r) ); unset IFS

# get the most recent commit which modified any of "$@"
fileCommit() {
	git log -1 --format='format:%H' HEAD -- "$@"
}

# get the most recent commit which modified "$1/Dockerfile" or any file COPY'd from "$1/Dockerfile"
dirCommit() {
	local dir="$1"; shift
	(
		cd "$dir"
		fileCommit \
			Dockerfile \
			$(git show HEAD:./Dockerfile | awk '
				toupper($1) == "COPY" {
					for (i = 2; i < NF; i++) {
						print $i
					}
				}
			')
	)
}

cat <<-EOH
# this file is generated via https://github.com/docker-library/docker/blob/$(fileCommit "$self")/$self

Maintainers: Tianon Gravi <tianon@dockerproject.org> (@tianon),
             Joseph Ferguson <yosifkit@gmail.com> (@yosifkit)
GitRepo: https://github.com/docker-library/docker.git
EOH

# prints "$2$1$3$1...$N"
join() {
	local sep="$1"; shift
	local out; printf -v out "${sep//%/%%}%s" "$@"
	echo "${out#$sep}"
}

for flavor in "${flavors[@]}"; do
	suite=${flavor%/*}
	arch=${flavor#*/}

	commit="$(dirCommit "$flavor")"

	version="$(git show "$commit":"$flavor/Dockerfile" | awk '$1 == "ENV" && $2 == "DOCKER_VERSION" { print $3; exit }')"

	versionAliases=()
	fullVersion=$version
	while [ "${fullVersion%[.-]*}" != "$fullVersion" ]; do
		versionAliases+=( $fullVersion )
		fullVersion="${fullVersion%[.-]*}"
	done
	versionAliases+=(
		$fullVersion
	)

	suiteAliases=( "${versionAliases[@]/%/-$suite}" )
	codename=$(suiteCodename "${suite}")
	if [ -n "$codename" ]; then
		suiteAliases+=( "${versionAliases[@]/%/-$codename}" )
		if [ "$codename" = "stable" ]; then
			suiteAliases+=( "${versionAliases[@]/%/-latest}" )
		fi
	fi

	suiteArches="$(suiteArches "$suite")"

	echo
	cat <<-EOE
		Tags: $(join ', ' "${suiteAliases[@]}")
		Architectures: $(join ', ' $suiteArches)
		GitCommit: $commit
		Directory: $flavor
	EOE

	for variant in \
		dind dind-rootless git \
	; do
		dir="$flavor/$variant"
		[ -f "$dir/Dockerfile" ] || continue

		commit="$(dirCommit "$dir")"

		variantAliases=( "${suiteAliases[@]/%/-$variant}" )
		variantAliases=( "${variantAliases[@]//latest-/}" )

		case "$variant" in
			# https://github.com/docker/docker-ce/blob/8fb3bb7b2210789a4471c017561c1b0de0b4f145/components/engine/hack/make/binary-daemon#L24
			# "vpnkit is amd64-only" ... for now??
			dind-rootless) variantArches='amd64' ;;

			*)         variantArches="$suiteArches" ;;
		esac

		echo
		echo "Tags: $(join ', ' "${variantAliases[@]}")"
		cat <<-EOE
			Architectures: $(join ', ' $variantArches)
			GitCommit: $commit
			Directory: $dir
		EOE
	done
done
