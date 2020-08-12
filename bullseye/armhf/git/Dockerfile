FROM vicamo/docker:19.03-bullseye-armhf

RUN apt-get update --quiet \
	&& apt-get install --no-install-recommends --yes \
		git \
	&& rm -rf /var/lib/apt
