# Builder image
#FROM napnap75/rpi-alpine-base:latest as builder
FROM alpine:latest as builder

# Download the required software
RUN apk add --no-cache curl \
	&& while [ "$DOWNLOAD_URL" == "" ] ; do DOWNLOAD_URL=$(curl -s https://api.github.com/repos/restic/restic/releases/latest | grep "browser_download_url" | grep "linux_arm\." | cut -d\" -f4) ; done \
	&& curl --retry 3 -L -o restic.bz2 ${DOWNLOAD_URL} \
	&& bunzip2 restic.bz2 \
	&& chmod +x restic

# Final image
#FROM napnap75/rpi-alpine-base:latest
FROM alpine:latest

# Download the required software
RUN apk add --no-cache curl jq openssh-client bash

# COPY restic bin
COPY --from=builder restic /bin
# COPY restic wrapper script
COPY restic /usr/local/bin
COPY docker-backup.sh /bin
CMD ["/bin/docker-backup.sh"]
# Uncomment in place of above CMD for test run
#CMD ["/bin/docker-backup.sh", "run-once"]

# Uncomment in place of above CMD for debugging
#COPY dummy.sh /bin
#CMD [ "/bin/dummy.sh" ]
