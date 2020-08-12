ARG BASE_IMAGE=vicamo/docker:19.03-focal-amd64

FROM ${BASE_IMAGE}

RUN apt-get update --quiet \
	&& apt-get install --no-install-recommends --yes \
		git \
		openssh-client \
	&& rm -rf /var/lib/apt
