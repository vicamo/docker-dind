FROM vicamo/docker:19.03-bullseye-amd64

RUN apt-get update --quiet \
	&& apt-get install --no-install-recommends --yes \
		git \
		openssh-client \
	&& rm -rf /var/lib/apt
