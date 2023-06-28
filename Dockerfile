# syntax=docker/dockerfile:1

ARG UNBOUND_VERSION=1.17.1
ARG LDNS_VERSION=1.8.3
ARG XX_VERSION=1.1.2
ARG ALPINE_VERSION=3.17

FROM --platform=$BUILDPLATFORM tonistiigi/xx:${XX_VERSION} AS xx

FROM --platform=$BUILDPLATFORM alpine:${ALPINE_VERSION} AS base
COPY --from=xx / /
RUN apk --update --no-cache add binutils clang curl file make pkgconf tar tree xz

FROM base AS base-build
ENV XX_CC_PREFER_LINKER=ld
ARG TARGETPLATFORM
RUN xx-apk --no-cache add gcc g++ expat-dev hiredis hiredis-dev libevent-dev libcap libpcap-dev openssl-dev perl
RUN xx-clang --setup-target-triple

FROM base AS unbound-src
WORKDIR /src/unbound
ARG UNBOUND_VERSION
RUN curl -sSL "https://unbound.net/downloads/unbound-${UNBOUND_VERSION}.tar.gz" | tar xz --strip 1

FROM base AS ldns-src
WORKDIR /src/ldns
ARG LDNS_VERSION
RUN curl -sSL "https://nlnetlabs.nl/downloads/ldns/ldns-${LDNS_VERSION}.tar.gz" | tar xz --strip 1

FROM base-build AS unbound-build
WORKDIR /src/unbound
RUN --mount=type=bind,from=unbound-src,source=/src/unbound,target=.,rw <<EOT
  set -ex

  CC=xx-clang CXX=xx-clang++ ./configure \
    --host=$(xx-clang --print-target-triple) \
    --prefix=/usr \
    --sysconfdir=/etc \
    --mandir=/usr/share/man \
    --localstatedir=/var \
    --with-chroot-dir="" \
    --with-pidfile=/var/run/unbound/unbound.pid \
    --with-run-dir=/var/run/unbound \
    --with-username="" \
    --disable-flto \
    --disable-rpath \
    --disable-shared \
    --enable-cachedb \
    --enable-event-api \
    --without-pthreads \
    --without-solaris-threads \
    --with-libhiredis=$(xx-info sysroot)usr \
    --with-libexpat=$(xx-info sysroot)usr \
    --with-libevent=$(xx-info sysroot)usr \
    --with-ssl=$(xx-info sysroot)usr

  make DESTDIR=/out install
  make DESTDIR=/out unbound-event-install
  install -Dm755 contrib/update-anchor.sh /out/usr/share/unbound/update-anchor.sh
  tree /out
  xx-verify /out/usr/sbin/unbound
  xx-verify /out/usr/sbin/unbound-anchor
  xx-verify /out/usr/sbin/unbound-checkconf
  xx-verify /out/usr/sbin/unbound-control
  xx-verify /out/usr/sbin/unbound-host
  file /out/usr/sbin/unbound
  file /out/usr/sbin/unbound-anchor
  file /out/usr/sbin/unbound-checkconf
  file /out/usr/sbin/unbound-control
  file /out/usr/sbin/unbound-host
EOT

FROM base-build AS ldns-build
WORKDIR /src/ldns
RUN --mount=type=bind,from=ldns-src,source=/src/ldns,target=.,rw <<EOT
  set -ex

  CC=xx-clang CXX=xx-clang++ CPPFLAGS=-I/src/ldns/ldns ./configure \
    --host=$(xx-clang --print-target-triple) \
    --prefix=/usr \
    --sysconfdir=/etc \
    --mandir=/usr/share/man \
    --infodir=/usr/share/info \
    --localstatedir=/var \
    --disable-gost \
    --disable-rpath \
    --disable-shared \
    --with-drill \
    --with-ssl=$(xx-info sysroot)usr \
    --with-trust-anchor=/var/run/unbound/root.key

  make DESTDIR=/out install
  tree /out
  xx-verify /out/usr/bin/drill
  file /out/usr/bin/drill
EOT

FROM alpine:${ALPINE_VERSION}
COPY --from=unbound-build /out /
COPY --from=ldns-build /out /

RUN apk --update --no-cache add \
    ca-certificates \
    dns-root-hints \
    dnssec-root \
    expat \
    hiredis \
    libevent \
    libpcap \
    openssl \
    shadow \
    libcap \
  && mkdir -p /run/unbound \
  && unbound -V \
  && unbound-anchor -v || true \
  && ldns-config --version \
  && rm -rf /tmp/* /var/www/*

# COPY rootfs /

RUN mkdir -p /config \
  && addgroup -g 1500 unbound \
  && adduser -D -H -u 1500 -G unbound -s /bin/sh unbound \
  && chown -R unbound. /etc/unbound /run/unbound \
  && rm -rf /tmp/*
RUN setcap 'cap_net_bind_service=+ep' /usr/sbin/unbound & rm -f /etc/unbound/unbound.conf
# USER unbound

COPY <<-"EOF" /unbound.conf

server:
  verbosity: 1
  module-config: "validator cachedb iterator"
  statistics-interval: 600
  statistics-cumulative: yes

  # set to 0 to avoid warning message when cachedb module is loaded.
  # warning: cachedb: serve-expired-reply-ttl is set but not working for data originating from the external cache; 0 TLL is used for those.
  serve-expired-reply-ttl: 0

  interface: 0.0.0.0@53
  do-ip4: yes
  do-ip6: no
  do-udp: yes
  do-tcp: yes

  do-daemonize: no

  access-control: 0.0.0.0/0 allow

  directory: "/etc/unbound"
  logfile: ""
  pidfile: "/var/run/unbound/unbound.pid"

  identity: "NodeCloud_DNS_Service"
  # auto-trust-anchor-file: "/var/run/unbound/root.key"
  # tls-cert-bundle: /etc/ssl/certs/ca-certificates.crt
  do-not-query-localhost: no

  num-threads: 4
  msg-cache-slabs: 4
  rrset-cache-slabs: 4
  infra-cache-slabs: 4
  key-cache-slabs: 4
  cache-min-ttl: 300
  cache-max-ttl: 86400
  rrset-cache-size: 256m
  msg-cache-size: 128m
  outgoing-range: 8192
  num-queries-per-thread: 4096
  so-rcvbuf: 16m
  so-sndbuf: 16m
  so-reuseport: yes

  cachedb:
    backend: "redis"
    secret-seed: "default"
    redis-server-host: 127.0.0.1
    redis-server-port: 6379

  forward-zone:
    name: "."
    forward-addr: 127.0.0.1@5353
    # forward-tls-upstream: yes

      # https://dnsprivacy.org/wiki/display/DP/DNS+Privacy+Test+Servers

      ## Cloudflare
      #forward-addr: 1.1.1.1@853#cloudflare-dns.com
      #forward-addr: 1.0.0.1@853#cloudflare-dns.com
      #forward-addr: 2606:4700:4700::1111@853#cloudflare-dns.com
      #forward-addr: 2606:4700:4700::1001@853#cloudflare-dns.com

      ## Cloudflare Malware
      # forward-addr: 1.1.1.2@853#security.cloudflare-dns.com
      # forward-addr: 1.0.0.2@853#security.cloudflare-dns.com
      # forward-addr: 2606:4700:4700::1112@853#security.cloudflare-dns.com
      # forward-addr: 2606:4700:4700::1002@853#security.cloudflare-dns.com

      ## Cloudflare Malware and Adult Content
      # forward-addr: 1.1.1.3@853#family.cloudflare-dns.com
      # forward-addr: 1.0.0.3@853#family.cloudflare-dns.com
      # forward-addr: 2606:4700:4700::1113@853#family.cloudflare-dns.com
      # forward-addr: 2606:4700:4700::1003@853#family.cloudflare-dns.com

      ## CleanBrowsing Security Filter
      # forward-addr: 185.228.168.9@853#security-filter-dns.cleanbrowsing.org
      # forward-addr: 185.228.169.9@853#security-filter-dns.cleanbrowsing.org
      # forward-addr: 2a0d:2a00:1::2@853#security-filter-dns.cleanbrowsing.org
      # forward-addr: 2a0d:2a00:2::2@853#security-filter-dns.cleanbrowsing.org

      ## CleanBrowsing Adult Filter
      # forward-addr: 185.228.168.10@853#adult-filter-dns.cleanbrowsing.org
      # forward-addr: 185.228.169.11@853#adult-filter-dns.cleanbrowsing.org
      # forward-addr: 2a0d:2a00:1::1@853#adult-filter-dns.cleanbrowsing.org
      # forward-addr: 2a0d:2a00:2::1@853#adult-filter-dns.cleanbrowsing.org

      ## CleanBrowsing Family Filter
      # forward-addr: 185.228.168.168@853#family-filter-dns.cleanbrowsing.org
      # forward-addr: 185.228.169.168@853#family-filter-dns.cleanbrowsing.org
      # forward-addr: 2a0d:2a00:1::@853#family-filter-dns.cleanbrowsing.org
      # forward-addr: 2a0d:2a00:2::@853#family-filter-dns.cleanbrowsing.org

      ## Quad9
      # forward-addr: 9.9.9.9@853#dns.quad9.net
      # forward-addr: 149.112.112.112@853#dns.quad9.net
      # forward-addr: 2620:fe::fe@853#dns.quad9.net
      # forward-addr: 2620:fe::9@853#dns.quad9.net

      ## getdnsapi.net
      # forward-addr: 185.49.141.37@853#getdnsapi.net
      # forward-addr: 2a04:b900:0:100::37@853#getdnsapi.net

      ## Surfnet
      # forward-addr: 145.100.185.15@853#dnsovertls.sinodun.com
      # forward-addr: 145.100.185.16@853#dnsovertls1.sinodun.com
      # forward-addr: 2001:610:1:40ba:145:100:185:15@853#dnsovertls.sinodun.com
      # forward-addr: 2001:610:1:40ba:145:100:185:16@853#dnsovertls1.sinodun.com
EOF

COPY <<-"EOF" /entrypoint.sh
	#!/bin/sh
	set -e
  if [ ! -f /etc/unbound/unbound.conf ]; then
    cp /unbound.conf /etc/unbound/unbound.conf
  fi
  if [ -x "$(command -v sysctl)" ]; then
      sysctl -w net.core.rmem_max=16777216 > /dev/null 2>&1
      if [ $? -eq 0 ]; then
          echo "Successfully set net.core.rmem_max to 16777216."
      else
          echo "Failed to set net.core.rmem_max. The container may not have privileged permissions."
          sed -i '/so-rcvbuf: 4m/d' /etc/unbound/unbound.conf && sed -i '/so-sndbuf: 4m/d' /etc/unbound/unbound.conf && sed -i '/so-reuseport: yes/d' /etc/unbound/unbound.conf
      fi
  else
      echo "The sysctl command is not executable."
  fi

  if [ -x "$(command -v sysctl)" ]; then
      # If it is, try to set net.core.wmem_max
      sysctl -w net.core.wmem_max=16777216 > /dev/null 2>&1

      # Check the exit status of the previous command
      if [ $? -eq 0 ]; then
          echo "Successfully set net.core.wmem_max to 16777216."
      else
          echo "Failed to set net.core.wmem_max. The container may not have privileged permissions."
          sed -i '/so-rcvbuf: 4m/d' /etc/unbound/unbound.conf && sed -i '/so-sndbuf: 4m/d' /etc/unbound/unbound.conf && sed -i '/so-reuseport: yes/d' /etc/unbound/unbound.conf
      fi
  else
      echo "The sysctl command is not executable."
  fi
	unbound-checkconf /etc/unbound/unbound.conf
	exec unbound -d -c /etc/unbound/unbound.conf
EOF

EXPOSE 53/tcp
EXPOSE 53/udp
VOLUME [ "/config" ]
CMD sh /entrypoint.sh

HEALTHCHECK --interval=30s --timeout=10s \
  CMD drill -p 5053 unbound.net @127.0.0.1