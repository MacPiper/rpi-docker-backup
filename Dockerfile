FROM multiarch/alpine:armhf-edge

RUN apk add --no-cache curl \
	&& while [ "$DOWNLOAD_URL" == "" ] ; do DOWNLOAD_URL=$(curl -s https://api.github.com/repos/restic/restic/releases/latest | grep "browser_download_url" | grep "linux_arm\." | cut -d\" -f4) ; done \
	&& curl --retry 3 -L -o restic.bz2 ${DOWNLOAD_URL} \
	&& bunzip2 restic.bz2 \
	&& chmod +x restic

RUN apk add --no-cache curl jq openssh-client

COPY --from=builder restic /usr/bin
COPY restic /usr/local/bin
COPY docker-backup.sh /usr/bin
CMD ["/usr/bin/docker-backup.sh"]